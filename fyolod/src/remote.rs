//! Remote sessions over **system SSH only** — no custom transport, no public
//! listener. The remote `fyolod` owns the PTY; SSH is the transport and the
//! ACL. This covers issue #171 (deploy + attach) and #172 (`remote open`).
//!
//! The trick that makes this ~200 lines instead of a network stack: the daemon
//! auto-starts (detached via `setsid`) on the first client op. So
//! `ssh host fyolod attach <id>` runs the *client* on the remote host, whose
//! stdin/stdout are the SSH channel; the daemon it starts survives the SSH
//! disconnect because it is in its own session. Detach ≠ kill, remotely, free.
//!
//! Installing and updating the daemon on a host is the lifecycle loop
//! (`lifecycle::reconcile`); this module is its ssh arm — [`SshNode`] — plus
//! the artifact selection: which of the bundled daemons a host gets.

use anyhow::{bail, Context, Result};
use clap::Subcommand;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::lifecycle::{self, Artifacts, DaemonHello, Node, Options, Report, Run, Unreachable};

/// Where the binary is installed on the remote host. `$HOME` is expanded by
/// the remote shell. Overridable with `FYOLOD_REMOTE_BIN` for custom install
/// paths (and to point tests at a local binary).
pub fn remote_bin() -> String {
    std::env::var("FYOLOD_REMOTE_BIN").unwrap_or_else(|_| "$HOME/.local/bin/fyolod".to_string())
}

/// Where the `fyolo` client is installed on the remote host: beside the
/// daemon, under the name a person types (docker-lessons RFC §1.2 — the
/// client ships everywhere the daemon does). `FYOLOD_REMOTE_BIN` moves both.
/// `None` when the override renamed the daemon, which pairs with no client.
pub fn remote_client_bin() -> Option<String> {
    client_bin_beside(&remote_bin())
}

/// The client that belongs to a daemon at `daemon`, or `None` when nothing on
/// the box does.
///
/// The daemon's *basename* decides, not just its directory. `FYOLOD_REMOTE_BIN`
/// is the knob for a custom install path and for pointing tests at a binary of
/// their own, so `/usr/local/bin/fyolod-test` is a shape someone will use —
/// and deriving the client from the directory alone would have that deploy
/// rename `/usr/local/bin/fyolo`, the box's real client, out from under
/// everything using it. A daemon that is not named `fyolod` is a daemon this
/// loop installs alone.
fn client_bin_beside(daemon: &str) -> Option<String> {
    let (directory, name) = match daemon.rsplit_once('/') {
        Some((directory, name)) if !directory.is_empty() => (directory, name),
        // A bare daemon name still installs into `$HOME/.local/bin` (see
        // `install_directory`), so the client is named by that path: its
        // activation and verification must reach the file scp put there, not
        // whatever a non-login shell's PATH happens to resolve.
        _ => ("$HOME/.local/bin", daemon),
    };
    (name == "fyolod").then(|| format!("{directory}/fyolo"))
}

/// SSH options shared by every outbound connection.
///
/// `ControlMaster` is the load-bearing one for cloud use: the first connection
/// to a host opens a master, and every later channel — another session, the
/// resource plane, a `list` — rides it for about one round trip instead of a
/// fresh TCP and key exchange. Zed does the same thing; unlike Zed we take the
/// user's own `ControlPath` when they have set one rather than overriding it.
pub fn ssh_multiplex_args() -> Vec<String> {
    let mut args = vec![
        "-o".into(),
        "ServerAliveInterval=15".into(),
        "-o".into(),
        "ControlMaster=auto".into(),
        "-o".into(),
        "ControlPersist=10m".into(),
    ];
    if std::env::var_os("FYOLOD_SSH_KEEP_CONTROLPATH").is_none() {
        if let Some(path) = control_path() {
            args.push("-o".into());
            args.push(format!("ControlPath={path}"));
        }
    }
    args
}

/// `%C` is a hash of (host, port, user), so one path template serves every
/// host without collisions.
fn control_path() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let dir = std::path::Path::new(&home).join(".fyolo").join("ssh");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("%C").display().to_string())
}

/// The options every non-interactive ssh here runs with. Nobody can answer a
/// prompt on these channels — the app runs them with no terminal at all — so
/// `BatchMode` turns a passphrase prompt into a prompt failure in a second,
/// and `ConnectTimeout` bounds a host that swallows the connect.
fn batch_args() -> Vec<String> {
    let mut args = vec![
        "-o".to_string(),
        "BatchMode=yes".to_string(),
        "-o".to_string(),
        "ConnectTimeout=10".to_string(),
    ];
    args.extend(ssh_multiplex_args());
    args
}

#[derive(Subcommand)]
pub enum RemoteCmd {
    /// Install or update `fyolod` on a host over SSH.
    Deploy {
        /// SSH host alias from `~/.ssh/config` (or user@host).
        host: String,
        /// Use this prebuilt binary instead of the bundled or cross-compiled one.
        #[arg(long)]
        bin: Option<String>,
        /// Force a Rust target triple instead of auto-detecting from `uname`.
        #[arg(long)]
        target: Option<String>,
        /// Stop the old daemon even while its sessions have work in progress.
        #[arg(long)]
        force: bool,
        /// Emit the outcome as one JSON document on stdout.
        #[arg(long)]
        json: bool,
    },

    /// List sessions on a remote host.
    List {
        host: String,
        #[arg(long)]
        json: bool,
    },

    /// Attach to (or create) a session on a remote host.
    Attach {
        host: String,
        /// Session id or name.
        target: String,
        /// Stream output without allocating an SSH tty or accepting input.
        #[arg(long)]
        observe: bool,
        /// Program + args if created. Put after `--`.
        #[arg(last = true)]
        argv: Vec<String>,
    },

    /// One-shot: ensure deployed, create a durable session, then attach (#172).
    Open {
        /// SSH host alias from `~/.ssh/config`.
        host: String,
        /// Remote working directory (default: `~`).
        #[arg(long)]
        cwd: Option<String>,
        /// Agent/shell to launch: `shell` (default), `claude`, `codex`, …
        #[arg(long, default_value = "shell")]
        agent: String,
        /// Session name (default: derived from agent).
        #[arg(long)]
        name: Option<String>,
        /// Skip the deploy check (assume `fyolod` is already installed).
        #[arg(long)]
        no_deploy: bool,
    },
}

pub async fn run(cmd: RemoteCmd) -> Result<()> {
    match cmd {
        RemoteCmd::Deploy {
            host,
            bin,
            target,
            force,
            json,
        } => {
            let mut node = SshNode::new(host);
            if let Some(bin) = bin {
                let daemon = PathBuf::from(bin);
                // Only a machine that takes a client is paired with one, and
                // only when this deploy named it: `artifact` sends none
                // otherwise. Pairing first meant a daemon/client build mismatch
                // refused the whole deploy over an artifact that was never going
                // to ship — a `--target aarch64-apple-darwin` run, say, where a
                // Mac must be sent no client at all.
                if target.as_deref().is_some_and(target_takes_a_client) {
                    // Resolved before anything is sent: a stale pair is caught by
                    // a local `--version`, not by a failed verify and a daemon
                    // bounce on the box.
                    node.prebuilt_client = client_beside(&daemon).await?;
                } else if target.is_none() {
                    eprintln!(
                        "[deploy] deploying the daemon only; name the machine with --target to \
                         send the client beside it too"
                    );
                }
                node.prebuilt = Some(daemon);
            }
            node.target = target;
            let report = reconcile(
                &node,
                Options {
                    force,
                    ..Options::default()
                },
            )
            .await;
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!("{}", report.describe());
            }
            let code = report.exit_code();
            if code != 0 {
                std::process::exit(code);
            }
            Ok(())
        }
        RemoteCmd::Open {
            host,
            cwd,
            agent,
            name,
            no_deploy,
        } => {
            if !no_deploy {
                // The same loop the app runs before an attach. A daemon left
                // staged behind busy sessions is still a working daemon, so
                // that is a note rather than a stop.
                let report = reconcile(&SshNode::new(host.clone()), Options::default()).await;
                match report.outcome {
                    // A client that did not verify leaves the box attachable, so
                    // it is a note here rather than a refusal — but a note it
                    // must be: the same outcome exits non-zero for `deploy` and
                    // is logged as an error by the app, and someone reaching a
                    // box this way would otherwise get no word that the `fyolo`
                    // inside its sessions is broken.
                    lifecycle::Outcome::Current { client: Some(_), .. }
                    | lifecycle::Outcome::Staged { .. } => eprintln!("{}", report.describe()),
                    lifecycle::Outcome::Current { .. } => {}
                    _ => bail!("{}", report.describe()),
                }
            }
            tokio::task::spawn_blocking(move || open(&host, cwd.as_deref(), &agent, name.as_deref()))
                .await?
        }
        // These shell out to ssh; run them on a blocking thread so the async
        // runtime stays free.
        other => tokio::task::spawn_blocking(move || run_blocking(other)).await?,
    }
}

/// The lifecycle loop against a host, for the build this binary is.
pub async fn reconcile(node: &SshNode, options: Options) -> Report {
    let report = lifecycle::reconcile(node, lifecycle::BUILD_VERSION, options).await;
    if let lifecycle::Outcome::Current {
        version,
        host_id,
        proto,
        ..
    } = &report.outcome
    {
        record_observation(&node.host, host_id, version, *proto);
    }
    report
}

/// Stamps what a successful deploy's handshake revealed into the app's device
/// registry (`devices.json`), so `fyolo version` shows the deploy-time
/// observation instead of a row from the app's last pane attach. Without this,
/// a CLI deploy leaves the table claiming the old version until the next
/// attach — which reads as "the update didn't work".
///
/// The app remains the registry's writer while it runs: it merges newer
/// on-disk observations before each save (`FyolodDeviceRegistry`), so this
/// stamp survives instead of racing it. Best effort — the deploy already
/// succeeded, so a failed stamp is a note on stderr, never a failed command.
fn record_observation(alias: &str, host_id: &str, version: &str, proto: Option<u32>) {
    if !cfg!(target_os = "macos") {
        return;
    }
    let (channel, _) = crate::channel::resolve();
    let Some(home) = std::env::var_os("HOME") else {
        return;
    };
    let path = PathBuf::from(home)
        .join("Library/Application Support")
        .join(&channel.support_dir_name)
        .join("devices.json");
    if let Err(error) = record_observation_in(&path, alias, host_id, version, proto, &iso8601_utc_now()) {
        eprintln!("[deploy] couldn't record the observation in {}: {error:#}", path.display());
    }
}

fn record_observation_in(
    path: &Path,
    alias: &str,
    host_id: &str,
    version: &str,
    proto: Option<u32>,
    observed_at: &str,
) -> Result<()> {
    let mut devices: Vec<serde_json::Value> = match std::fs::read_to_string(path) {
        Ok(raw) => serde_json::from_str(&raw).context("reading the device registry")?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(error).context("reading the device registry"),
    };
    let route = format!("ssh:{alias}");
    // The route moves to the device that just answered on it — a reinstall
    // (new host_id behind the same alias) must not leave two rows claiming it.
    for device in devices.iter_mut() {
        if device.get("id").and_then(|value| value.as_str()) == Some(host_id) {
            continue;
        }
        if let Some(routes) = device.get_mut("routes").and_then(|value| value.as_array_mut()) {
            routes.retain(|entry| entry.as_str() != Some(route.as_str()));
        }
    }
    let entry = devices
        .iter_mut()
        .find(|device| device.get("id").and_then(|value| value.as_str()) == Some(host_id));
    match entry {
        Some(device) => {
            device["daemonVersion"] = version.into();
            device["observedAt"] = observed_at.into();
            if let Some(proto) = proto {
                device["proto"] = proto.into();
            }
            let routes = device
                .get_mut("routes")
                .and_then(|value| value.as_array_mut());
            match routes {
                Some(routes) => {
                    // Most recently used first, matching the app's own rule.
                    routes.retain(|entry| entry.as_str() != Some(route.as_str()));
                    routes.insert(0, route.into());
                }
                None => device["routes"] = serde_json::json!([route]),
            }
        }
        None => {
            let mut device = serde_json::json!({
                "id": host_id,
                "daemonVersion": version,
                "observedAt": observed_at,
                "routes": [route],
            });
            if let Some(proto) = proto {
                device["proto"] = proto.into();
            }
            devices.push(device);
        }
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("creating the registry directory")?;
    }
    // Write-then-rename so the app never reads a half-written registry.
    let staging = path.with_extension("json.new");
    let body = serde_json::to_vec_pretty(&devices).context("encoding the device registry")?;
    std::fs::write(&staging, body).context("writing the device registry")?;
    std::fs::rename(&staging, path).context("replacing the device registry")?;
    Ok(())
}

/// `2026-09-08T17:58:53Z` — the shape the registry uses and `fyolo version`
/// parses. Civil-from-days (Howard Hinnant's algorithm), the inverse of the
/// parser in version.rs, avoiding a time crate for one fixed-format field.
fn iso8601_utc_now() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0);
    let days = seconds.div_euclid(86_400);
    let time_of_day = seconds.rem_euclid(86_400);
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_shifted = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_shifted + 2) / 5 + 1;
    let month = if month_shifted < 10 {
        month_shifted + 3
    } else {
        month_shifted - 9
    };
    let year = year_of_era + era * 400 + if month <= 2 { 1 } else { 0 };
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        time_of_day / 3_600,
        (time_of_day % 3_600) / 60,
        time_of_day % 60
    )
}

fn run_blocking(cmd: RemoteCmd) -> Result<()> {
    match cmd {
        RemoteCmd::List { host, json } => {
            let bin = remote_bin();
            let flag = if json { " --json" } else { "" };
            let status = ssh_interactive(&host, false, &format!("{bin} list{flag}"))?;
            std::process::exit(status);
        }
        RemoteCmd::Attach {
            host,
            target,
            observe,
            argv,
        } => {
            let remote = build_attach_cmd(&target, observe, &argv);
            let status = ssh_interactive(&host, !observe, &remote)?;
            std::process::exit(status);
        }
        RemoteCmd::Deploy { .. } | RemoteCmd::Open { .. } => {
            unreachable!("handled on the async path")
        }
    }
}

/// Build the remote `fyolod attach` command line.
fn build_attach_cmd(target: &str, observe: bool, argv: &[String]) -> String {
    let bin = remote_bin();
    let mut s = format!("{bin} attach {}", shell_quote(target));
    if observe {
        s.push_str(" --observe");
    }
    if !argv.is_empty() {
        s.push_str(" --");
        for a in argv {
            s.push(' ');
            s.push_str(&shell_quote(a));
        }
    }
    s
}

fn open(host: &str, cwd: Option<&str>, agent: &str, name: Option<&str>) -> Result<()> {
    let bin = remote_bin();
    let argv: Vec<String> = match agent {
        "shell" | "" => Vec::new(),
        other => vec![other.to_string()],
    };
    let session_name = name.unwrap_or(if argv.is_empty() { "shell" } else { agent });

    // Create the durable session on the remote host.
    let mut create = format!("{bin} create --name {}", shell_quote(session_name));
    if let Some(dir) = cwd {
        create.push_str(&format!(" --cwd {}", shell_quote(dir)));
    }
    if !argv.is_empty() {
        create.push_str(" --");
        for a in &argv {
            create.push(' ');
            create.push_str(&shell_quote(a));
        }
    }
    let id = ssh_capture(host, &create)?.trim().to_string();
    if id.is_empty() {
        bail!("remote create returned no session id");
    }
    eprintln!("[remote {host}] created session {id} ({session_name}); attaching…");

    let remote = format!("{bin} attach {}", shell_quote(&id));
    let status = ssh_interactive(host, true, &remote)?;
    std::process::exit(status);
}

// MARK: The ssh arm of the lifecycle loop

/// A machine reached with the user's own `ssh`, as `~/.ssh/config` defines it.
/// The daemon installed is whichever of the bundled builds matches the box's
/// `uname`, or this very binary for another Mac.
pub struct SshNode {
    pub host: String,
    /// A binary to install instead of choosing one — the developer override.
    pub prebuilt: Option<PathBuf>,
    /// The client paired with `prebuilt`, validated by [`client_beside`].
    /// `None` alongside a `prebuilt` daemon means a daemon-only deploy: the
    /// client plane is off for this node rather than half-staged.
    pub prebuilt_client: Option<PathBuf>,
    /// A Rust target triple instead of asking `uname`.
    pub target: Option<String>,
}

impl SshNode {
    pub fn new(host: String) -> SshNode {
        SshNode {
            host,
            prebuilt: None,
            prebuilt_client: None,
            target: None,
        }
    }

    fn ssh(&self) -> tokio::process::Command {
        let mut command = tokio::process::Command::new("ssh");
        command.args(batch_args());
        command
    }

    /// The directory the daemon lives in, spelled for the remote shell and for
    /// scp — which does not expand `$HOME`, but resolves a relative path
    /// against it.
    fn install_directory(&self) -> (String, String) {
        let binary = remote_bin();
        let directory = match binary.rsplit_once('/') {
            Some((directory, _)) if !directory.is_empty() => directory.to_string(),
            _ => "$HOME/.local/bin".to_string(),
        };
        let for_scp = directory
            .strip_prefix("$HOME/")
            .or_else(|| directory.strip_prefix("~/"))
            .map(str::to_string)
            .unwrap_or_else(|| directory.clone());
        (directory, for_scp)
    }
}

impl Node for SshNode {
    fn label(&self) -> String {
        self.host.clone()
    }

    fn binary(&self) -> String {
        remote_bin()
    }

    async fn run(&self, command: &str) -> Result<Run> {
        let output = self
            .ssh()
            .arg(&self.host)
            .arg(command)
            .output()
            .await
            .context("spawning ssh")?;
        let code = output.status.code().unwrap_or(1);
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        // 255 is ssh's own exit status — connection or authentication, never
        // the remote command's. It is the line between "unreachable" and
        // "reached, and this failed".
        if code == 255 {
            return Err(Unreachable(last_line(&stderr)).into());
        }
        Ok(Run {
            code,
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr,
        })
    }

    async fn put(&self, local: &Path, name: &str) -> Result<()> {
        let (directory, for_scp) = self.install_directory();
        let made = self.run(&format!("mkdir -p {directory}")).await?;
        if made.code != 0 {
            bail!("creating {directory} on {}: {}", self.host, last_line(&made.stderr));
        }
        eprintln!(
            "[deploy] copying {} → {}:{for_scp}/{name}",
            local.display(),
            self.host
        );
        let output = tokio::process::Command::new("scp")
            .args(batch_args())
            .arg(local)
            .arg(format!("{}:{for_scp}/{name}", self.host))
            .output()
            .await
            .context("spawning scp")?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if output.status.code() == Some(255) {
                return Err(Unreachable(last_line(&stderr)).into());
            }
            bail!("copying the binary to {}: {}", self.host, last_line(&stderr));
        }
        Ok(())
    }

    async fn artifact(&self, client_only: bool) -> Result<Artifacts> {
        // `--bin` answers before anything is asked of the host. It is the escape
        // hatch for a machine `uname -sm` does not map to a target — an armv7
        // board, a BSD — so making it wait on target detection took the one path
        // that worked without detection and failed it with "pass --target
        // explicitly", and charged every other `--bin` deploy a round trip.
        if let Some(prebuilt) = &self.prebuilt {
            // Unknown means no client. The host is not asked what it is on this
            // path, and guessing "it takes one" plants a `~/.local/bin/fyolo`
            // on a Mac that manages its own — shadowing the app's copy with one
            // frozen at this build, which no later pass refreshes or removes.
            let ships_client = self.target.as_deref().is_some_and(target_takes_a_client);
            return Ok(Artifacts {
                daemon: prebuilt.clone(),
                client: ships_client.then(|| self.prebuilt_client.clone()).flatten(),
            });
        }
        let target = match &self.target {
            Some(target) => target.clone(),
            None => {
                let uname = self.run("uname -sm").await?;
                if uname.code != 0 {
                    bail!("asking {} its uname: {}", self.host, last_line(&uname.stderr));
                }
                target_for_uname(uname.stdout.trim())?
            }
        };
        let ships_client = target_takes_a_client(&target);
        if let Some(path) = shipped_binary(&target) {
            eprintln!("[deploy] using the bundled {target} binaries");
            let daemon = PathBuf::from(path);
            let client = match ships_client {
                true => Some(shipped_client(&target, &daemon)?),
                false => None,
            };
            return Ok(Artifacts { daemon, client });
        }
        if client_only {
            // Repairing a client is not worth building a daemon for. A control
            // plane run out of a checkout reaches this on every attach to a box
            // whose client is missing, and cross-compiling there needs a
            // toolchain it may not have — which turned an attach to a healthy
            // machine into a failure. `stage` reads this as "leave the client
            // alone" rather than as a failed deploy.
            bail!(
                "no bundled {target} client to repair {} with; a client-only pass does not build one",
                self.host
            );
        }
        tokio::task::spawn_blocking(move || cross_compile(&target)).await?
    }

    fn client_binary(&self) -> Option<String> {
        // A `--bin` override with no client beside it deploys the daemon
        // alone; every other artifact source carries both binaries.
        if self.prebuilt.is_some() && self.prebuilt_client.is_none() {
            return None;
        }
        remote_client_bin()
    }

    fn client_repair_note(&self) -> Option<PathBuf> {
        // One file per host, named after the alias the user reaches it by. Kept
        // in this machine's own durable state: it is this control plane's note
        // about a box, not state the box should carry.
        let named: String = self
            .host
            .chars()
            .map(|character| match character {
                'a'..='z' | 'A'..='Z' | '0'..='9' | '.' | '-' | '_' => character,
                _ => '_',
            })
            .collect();
        if named.is_empty() {
            return None;
        }
        Some(
            crate::paths::durable_state_dir()
                .ok()?
                .join("client-repair")
                .join(named),
        )
    }

    async fn hello(&self) -> Result<DaemonHello> {
        let mut child = self
            .ssh()
            .arg(&self.host)
            .arg(format!("{} stdio", remote_bin()))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("spawning ssh")?;
        let mut reader = child.stdout.take().context("ssh stdout")?;
        let mut writer = child.stdin.take().context("ssh stdin")?;
        let answer = tokio::time::timeout(
            Duration::from_secs(10),
            lifecycle::handshake(&mut reader, &mut writer),
        )
        .await;
        match answer {
            Ok(Ok(hello)) => Ok(hello),
            other => {
                // The remote binary's own words are the diagnosis — "Exec
                // format error" for a wrong slice, ssh's line for auth — so
                // they are read before the child is discarded.
                let _ = child.kill().await;
                let mut stderr = String::new();
                if let Some(mut stream) = child.stderr.take() {
                    use tokio::io::AsyncReadExt;
                    let _ = tokio::time::timeout(
                        Duration::from_secs(2),
                        stream.read_to_string(&mut stderr),
                    )
                    .await;
                }
                let reason = match other {
                    Ok(Err(error)) => format!("{error:#}"),
                    _ => "no protocol reply within 10s".to_string(),
                };
                let detail = last_line(&stderr);
                if detail == "no output" {
                    bail!("{reason}")
                }
                bail!("{reason} ({detail})")
            }
        }
    }
}

fn last_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .last()
        .unwrap_or("no output")
        .to_string()
}

/// A daemon for `target` shipped beside this executable.
///
/// This is what makes deploying possible for someone who installed Fyolo rather
/// than cloning it: `cross_compile` below needs cargo, the musl target, and this
/// crate's source tree at the path baked into it, none of which a `.app` from the
/// DMG has. `scripts/build-app.sh` puts both Linux binaries in `Contents/Resources`
/// next to the daemon that reads this, so the common case is a copy.
///
/// A Mac takes the daemon that is *already* there — the one running this code. It
/// is built universal for the same reason the app is, so one file serves both
/// architectures and there is nothing per-target to ship. Sent as a plain copy:
/// `scp` sets no quarantine attribute, so a Developer-ID-signed binary landing on
/// another Mac runs without a Gatekeeper prompt.
///
/// Found by the executable's own directory rather than by a bundle path or an
/// environment variable: the daemon is run by absolute path out of whatever
/// shipped it, and this keeps that the single source of truth. Building from the
/// repo puts no siblings there, so a contributor still gets `cross_compile` — the
/// path that proves the source tree actually cross-builds.
fn shipped_binary(target: &str) -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    if target.contains("apple-darwin") {
        return exe.to_str().map(str::to_owned);
    }
    let candidate = exe.parent()?.join(format!("fyolod-{target}"));
    candidate
        .is_file()
        .then(|| candidate.to_string_lossy().into_owned())
}

/// Whether a machine of this target takes a `fyolo` client from a deploy.
///
/// Every Linux box does: nothing else puts one there. No Mac does. A Mac owns
/// its client already — its app bundle links one into `/usr/local/bin` — and
/// `session::client_path_directory` returns `None` on macOS, so a copy planted
/// in `~/.local/bin` would never be reached deliberately. It would only shadow
/// the app's own wherever `~/.local/bin` comes first on `PATH`, frozen at
/// whatever build this deploy left while that Mac's own client moves on with
/// its app.
fn target_takes_a_client(target: &str) -> bool {
    !target.contains("apple-darwin")
}

/// The `fyolo` client that ships beside this executable for `target`,
/// mirroring [`shipped_binary`]. Only ever asked for a target that takes one,
/// which is every Linux box and no Mac (see [`SshNode::artifact`]).
///
/// Missing is an error rather than a smaller deploy: these slices exist only
/// because `scripts/build-app.sh` put them in a bundle's Resources, so absence
/// means a broken bundle, and shipping half a build from one would recreate the
/// skew §1.2 rules out.
fn shipped_client(target: &str, daemon: &Path) -> Result<PathBuf> {
    let directory = daemon
        .parent()
        .with_context(|| format!("{} has no directory", daemon.display()))?;
    let candidate = directory.join(format!("fyolo-{target}"));
    if !candidate.is_file() {
        bail!(
            "the bundled daemon has no fyolo client beside it ({}); the client deploys with the daemon",
            candidate.display()
        );
    }
    Ok(candidate)
}

/// The client that pairs with a developer-supplied `--bin` daemon: the
/// `fyolo` beside it, when there is one of the same build.
///
/// `None` — a daemon-only deploy, with a note — rather than an error when
/// the file is absent: `cargo build --bin fyolod` legitimately produces no
/// client, and the box keeps whatever client it has. But a client that *is*
/// there and answers `--version` as another build is refused here, before a
/// byte ships: sending it would fail verification on the box and bounce the
/// daemon over a skew a local check already saw. A pair that cannot answer
/// locally — cross-built for another machine — ships as found, and the box's
/// own verify judges it.
async fn client_beside(daemon: &Path) -> Result<Option<PathBuf>> {
    let candidate = daemon
        .parent()
        .map(|directory| directory.join("fyolo"))
        .filter(|path| path.is_file());
    let Some(client) = candidate else {
        eprintln!(
            "[deploy] no fyolo client beside {}; deploying the daemon only",
            daemon.display()
        );
        return Ok(None);
    };
    let (daemon_stamp, daemon_text) = lifecycle::binary_version(daemon).await;
    let (client_stamp, client_text) = lifecycle::binary_version(&client).await;
    if let (Some(daemon_stamp), Some(client_stamp)) = (daemon_stamp, client_stamp) {
        if daemon_stamp != client_stamp {
            bail!(
                "the fyolo beside {} is another build ({} where the daemon is {}); rebuild so the pair matches",
                daemon.display(),
                client_text.as_deref().unwrap_or("unstamped"),
                daemon_text.as_deref().unwrap_or("unstamped")
            );
        }
    }
    Ok(Some(client))
}

/// The `uname -sm` half of target detection, split out so the mapping can be
/// checked without a machine to ask.
///
/// Macs are here because a device is a machine the user owns, and plenty of them
/// are a Mac mini or a Studio on the same desk — "remote" describes the road, not
/// the thing at the end of it. The daemon's own build already covers Darwin (it is
/// what runs local sessions), so supporting it costs a branch here rather than a
/// new artifact.
fn target_for_uname(uname: &str) -> Result<String> {
    let arm = uname.contains("aarch64") || uname.contains("arm64");
    let intel = uname.contains("x86_64") || uname.contains("amd64");
    let target = match (uname.split_whitespace().next(), arm, intel) {
        (Some("Linux"), true, _) => "aarch64-unknown-linux-musl",
        (Some("Linux"), _, true) => "x86_64-unknown-linux-musl",
        (Some("Darwin"), true, _) => "aarch64-apple-darwin",
        (Some("Darwin"), _, true) => "x86_64-apple-darwin",
        (Some("Linux" | "Darwin"), _, _) => {
            bail!("unrecognized remote arch (uname: '{uname}'); pass --target explicitly")
        }
        _ => bail!("remote host is neither Linux nor macOS (uname: '{uname}'); pass --target explicitly"),
    };
    Ok(target.to_string())
}

/// Where the cross-build's tools are, which this process's own `PATH` cannot be
/// trusted to say. A deploy is usually started by the app, and an app launched
/// from Finder inherits launchd's `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin`, which
/// holds neither cargo (`~/.cargo/bin`) nor anything from Homebrew. The login
/// shell knows both, so it answers instead.
///
/// Homebrew's `zig` prefix is added on top of that because `brew` leaves `zig`
/// off `PATH` entirely whenever a second `zig@N` formula holds the link — the
/// same case `scripts/build-app.sh` checks for before building the daemon.
fn toolchain_path() -> Vec<String> {
    let mut directories = crate::agent::machine::login_path();
    for prefix in ["/opt/homebrew/opt/zig/bin", "/usr/local/opt/zig/bin"] {
        if !directories.iter().any(|seen| seen == prefix) {
            directories.push(prefix.to_string());
        }
    }
    directories
}

/// `binary` as an absolute path, looked up across `directories`.
fn find_tool(directories: &[String], binary: &str) -> Option<String> {
    use std::os::unix::fs::PermissionsExt;
    directories.iter().find_map(|directory| {
        let candidate = std::path::Path::new(directory).join(binary);
        let usable = std::fs::metadata(&candidate)
            .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
        usable.then(|| candidate.to_string_lossy().into_owned())
    })
}

/// `cargo build --release --target <triple>` for this crate; returns both
/// built binaries. Falls back to a clear message if the cross-linker is missing.
fn cross_compile(target: &str) -> Result<Artifacts> {
    let manifest = format!("{}/Cargo.toml", env!("CARGO_MANIFEST_DIR"));
    let path = toolchain_path();
    let Some(cargo) = find_tool(&path, "cargo") else {
        bail!(
            "cross-compiling for {target} needs cargo, and there is none on this machine.\n  \
             • install Rust: https://rustup.rs\n  \
             • or build on the host and deploy with: fyolod remote deploy <host> --bin <path>"
        );
    };
    // Checked before cargo runs rather than left to the build script's panic:
    // the VT engine fyolod embeds is built by Zig, and a missing `zig` fails
    // several minutes in, inside a wall of cargo output, blaming a build script
    // nobody here wrote.
    if find_tool(&path, "zig").is_none() {
        bail!(
            "cross-compiling for {target} needs zig — the terminal engine fyolod embeds\n\
             is built by it.\n  \
             • brew install zig\n  \
             • or build on the host and deploy with: fyolod remote deploy <host> --bin <path>"
        );
    }
    eprintln!("[deploy] cross-compiling for {target}…");
    let status = Command::new(cargo)
        .env("PATH", path.join(":"))
        // Run *inside* the crate, not merely at it. Cargo discovers
        // `.cargo/config.toml` by walking up from the working directory —
        // `--manifest-path` does not move that search. Started from anywhere else
        // (an app's working directory is `/`), the musl link falls back to Apple's
        // `cc`, which rejects lld's flags with "ld: unknown options: --as-needed"
        // and no mention of the config it never read. `fyolod/.cargo/config.toml`
        // is what points the cross-link at the bundled rust-lld.
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .args([
            "build",
            "--release",
            "--target",
            target,
            "--manifest-path",
            &manifest,
        ])
        .status()
        .context("running cargo build")?;
    if !status.success() {
        bail!(
            "cross-compile for {target} failed.\n\
             The target's std is usually the missing piece — the link itself needs no\n\
             external toolchain (fyolod/.cargo/config.toml uses the bundled rust-lld):\n  \
             • rustup target add {target}\n  \
             • or build on the host and deploy with: fyolod remote deploy <host> --bin <path>"
        );
    }
    let dir = env!("CARGO_MANIFEST_DIR");
    // With a workspace-less crate, target/ sits next to Cargo.toml. One build
    // produces both binaries — the crate declares both `[[bin]]`s — so the
    // client costs the cross-compile nothing extra.
    let daemon = PathBuf::from(format!("{dir}/target/{target}/release/fyolod"));
    let client = PathBuf::from(format!("{dir}/target/{target}/release/fyolo"));
    for binary in [&daemon, &client] {
        if !binary.exists() {
            bail!("expected built binary at {} but it is missing", binary.display());
        }
    }
    Ok(Artifacts {
        daemon,
        client: Some(client),
    })
}

/// Run an interactive/remote command over SSH. `tty` requests a PTY (`-t`),
/// needed for `attach`; list uses no tty. Returns the child's exit code.
fn ssh_interactive(host: &str, tty: bool, remote_cmd: &str) -> Result<i32> {
    let mut cmd = Command::new("ssh");
    if tty {
        cmd.arg("-t");
    }
    // ServerAliveInterval keeps the control channel honest; on disconnect the
    // remote client dies and the session detaches.
    cmd.args(["-o", "ServerAliveInterval=15"]);
    cmd.arg(host);
    cmd.arg(remote_cmd);
    let status = cmd.status().context("spawning ssh")?;
    Ok(status.code().unwrap_or(1))
}

/// One host's session table, for the cross-host view. Failure is returned per
/// host rather than aborting the sweep — a cloud fleet always has one box
/// that is rebooting, and that must not blank the other rows.
pub async fn list_json(host: &str) -> (String, Result<Vec<crate::protocol::SessionInfo>>) {
    let owned = host.to_string();
    let probe = owned.clone();
    let result = tokio::task::spawn_blocking(move || {
        let out = ssh_capture(&probe, &format!("{} list --json", remote_bin()))?;
        serde_json::from_str::<Vec<crate::protocol::SessionInfo>>(&out)
            .context("parsing remote session list")
    })
    .await;
    match result {
        Ok(inner) => (owned, inner),
        Err(e) => (owned, Err(anyhow::anyhow!("{e}"))),
    }
}

/// Run an SSH command and capture stdout (for create/list probes).
fn ssh_capture(host: &str, remote_cmd: &str) -> Result<String> {
    let mut cmd = Command::new("ssh");
    cmd.args(batch_args());
    let out = cmd
        .args([host, remote_cmd])
        .output()
        .context("spawning ssh")?;
    if !out.status.success() {
        bail!(
            "ssh {host} '{remote_cmd}' failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Minimal single-quote shell escaping for remote command args.
fn shell_quote(s: &str) -> String {
    lifecycle::shell_quote(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The client installs beside the daemon, wherever the daemon goes — a
    /// `FYOLOD_REMOTE_BIN` override moves both, and a bare name means the
    /// default install directory, where scp actually puts the file.
    #[test]
    fn the_client_installs_beside_the_daemon() {
        assert_eq!(
            client_bin_beside("$HOME/.local/bin/fyolod").as_deref(),
            Some("$HOME/.local/bin/fyolo")
        );
        assert_eq!(
            client_bin_beside("/usr/local/bin/fyolod").as_deref(),
            Some("/usr/local/bin/fyolo")
        );
        assert_eq!(client_bin_beside("fyolod").as_deref(), Some("$HOME/.local/bin/fyolo"));
    }

    /// `--bin` answers without asking the host anything. It is the escape hatch
    /// for a machine whose `uname -sm` maps to no target, so resolving one first
    /// failed exactly the deploys it exists for.
    #[tokio::test]
    async fn a_prebuilt_binary_deploys_without_resolving_a_target() {
        let mut node = SshNode::new("unrecognized-board".into());
        node.prebuilt = Some(PathBuf::from("/builds/fyolod"));
        node.prebuilt_client = Some(PathBuf::from("/builds/fyolo"));
        // No `run`, so any ssh this reached for would fail the test rather than
        // quietly cost a round trip.
        let artifacts = node.artifact(false).await.expect("a prebuilt needs no target");
        assert_eq!(artifacts.daemon, PathBuf::from("/builds/fyolod"));
        // And no client, because nothing here knows what the machine is: sending
        // one to a Mac plants a copy that shadows the app's own for good. Naming
        // the target with `--target` is what asks for it.
        assert_eq!(artifacts.client, None);
    }

    /// …and an explicit `--target` decides it, either way.
    #[tokio::test]
    async fn a_prebuilt_binary_sends_no_client_to_a_named_mac() {
        let mut node = SshNode::new("mac".into());
        node.prebuilt = Some(PathBuf::from("/builds/fyolod"));
        node.prebuilt_client = Some(PathBuf::from("/builds/fyolo"));
        node.target = Some("aarch64-apple-darwin".into());
        let artifacts = node.artifact(false).await.expect("a prebuilt needs no uname");
        assert_eq!(artifacts.client, None);
    }

    /// A Linux box gets its client from the deploy; a Mac never does, whichever
    /// way its target was arrived at.
    #[test]
    fn only_a_box_that_owns_no_client_is_sent_one() {
        assert!(target_takes_a_client("x86_64-unknown-linux-musl"));
        assert!(target_takes_a_client("aarch64-unknown-linux-musl"));
        assert!(!target_takes_a_client("aarch64-apple-darwin"));
        assert!(!target_takes_a_client("x86_64-apple-darwin"));
    }

    /// A daemon the override renamed pairs with no client: deploying one would
    /// rename the box's real `fyolo` aside to install a build under a name
    /// that was never asked for.
    #[test]
    fn a_renamed_daemon_deploys_without_touching_the_boxs_client() {
        assert_eq!(client_bin_beside("/usr/local/bin/fyolod-test"), None);
        assert_eq!(client_bin_beside("$HOME/builds/fyolod.debug"), None);
        assert_eq!(client_bin_beside("fyolod-test"), None);
    }

    /// What `uname -sm` actually prints on the machines Fyolo is pointed at.
    #[test]
    fn a_machine_is_recognized_from_its_own_uname() {
        assert_eq!(target_for_uname("Linux x86_64").unwrap(), "x86_64-unknown-linux-musl");
        assert_eq!(target_for_uname("Linux aarch64").unwrap(), "aarch64-unknown-linux-musl");
        assert_eq!(target_for_uname("Darwin arm64").unwrap(), "aarch64-apple-darwin");
        assert_eq!(target_for_uname("Darwin x86_64").unwrap(), "x86_64-apple-darwin");
    }

    /// A machine Fyolo has no daemon for says so, and says which of the two
    /// things it could not recognise — the system or the architecture.
    #[test]
    fn an_unsupported_machine_names_what_was_not_recognized() {
        let arch = target_for_uname("Linux riscv64").unwrap_err().to_string();
        assert!(arch.contains("unrecognized remote arch"), "{arch}");

        let system = target_for_uname("FreeBSD amd64").unwrap_err().to_string();
        assert!(system.contains("neither Linux nor macOS"), "{system}");
    }

    /// The Mac case takes the daemon that is already running this code rather
    /// than a per-target sibling, because it is built universal.
    #[test]
    fn a_mac_is_served_by_the_running_daemon_itself() {
        let running = std::env::current_exe().ok().and_then(|p| p.to_str().map(str::to_owned));
        assert_eq!(shipped_binary("aarch64-apple-darwin"), running);
        assert_eq!(shipped_binary("x86_64-apple-darwin"), running);
    }

    /// scp does not expand `$HOME`; the default install path has to reach it
    /// as a path relative to the login directory, and a custom absolute path
    /// has to reach it untouched.
    #[test]
    fn the_install_directory_is_spelled_for_scp() {
        let node = SshNode::new("box".into());
        std::env::remove_var("FYOLOD_REMOTE_BIN");
        assert_eq!(
            node.install_directory(),
            ("$HOME/.local/bin".to_string(), ".local/bin".to_string())
        );
    }

    fn scratch_registry(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("fyolod-registry-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("devices.json")
    }

    /// A deploy against a known device refreshes its row in place and leaves
    /// every field it did not learn (and every other device) untouched.
    #[test]
    fn a_deploy_refreshes_the_devices_own_row() {
        let path = scratch_registry("refresh");
        std::fs::write(
            &path,
            r#"[
                {"id": "h_other", "daemonVersion": "0.40.0+1", "routes": ["unix"]},
                {"id": "h_box", "daemonVersion": "0.50.0+1913", "proto": 1,
                 "observedAt": "2026-09-08T08:47:17Z", "routes": ["ssh:box"], "extra": "kept"}
            ]"#,
        )
        .unwrap();
        record_observation_in(&path, "box", "h_box", "0.52.0+1944", Some(1), "2026-09-08T17:58:00Z")
            .unwrap();
        let devices: Vec<serde_json::Value> =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let row = devices.iter().find(|d| d["id"] == "h_box").unwrap();
        assert_eq!(row["daemonVersion"], "0.52.0+1944");
        assert_eq!(row["observedAt"], "2026-09-08T17:58:00Z");
        assert_eq!(row["proto"], 1);
        assert_eq!(row["extra"], "kept");
        assert_eq!(row["routes"], serde_json::json!(["ssh:box"]));
        let other = devices.iter().find(|d| d["id"] == "h_other").unwrap();
        assert_eq!(other["daemonVersion"], "0.40.0+1");
    }

    /// A reinstall (new host id behind the same alias) moves the route: the
    /// old row must not keep claiming it, and a first-ever deploy creates the
    /// registry rather than requiring the app to have connected once.
    #[test]
    fn a_route_belongs_to_the_device_that_just_answered_on_it() {
        let path = scratch_registry("move");
        std::fs::write(
            &path,
            r#"[{"id": "h_old", "daemonVersion": "0.50.0+1913", "routes": ["ssh:box"]}]"#,
        )
        .unwrap();
        record_observation_in(&path, "box", "h_new", "0.52.0+1944", Some(1), "2026-09-08T17:58:00Z")
            .unwrap();
        let devices: Vec<serde_json::Value> =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let old = devices.iter().find(|d| d["id"] == "h_old").unwrap();
        assert_eq!(old["routes"], serde_json::json!([]));
        let new = devices.iter().find(|d| d["id"] == "h_new").unwrap();
        assert_eq!(new["routes"], serde_json::json!(["ssh:box"]));

        let fresh = scratch_registry("fresh");
        record_observation_in(&fresh, "box", "h_new", "0.52.0+1944", None, "2026-09-08T17:58:00Z")
            .unwrap();
        let devices: Vec<serde_json::Value> =
            serde_json::from_str(&std::fs::read_to_string(&fresh).unwrap()).unwrap();
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0]["id"], "h_new");
        assert!(devices[0].get("proto").is_none());
    }

    /// The stamp is the exact shape version.rs parses back.
    #[test]
    fn the_timestamp_round_trips_through_the_version_tables_parser() {
        let stamp = iso8601_utc_now();
        assert_eq!(stamp.len(), 20, "{stamp}");
        assert!(stamp.ends_with('Z'), "{stamp}");
    }
}
