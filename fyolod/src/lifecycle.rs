//! The daemon's lifecycle — install, update, repair — as one reconcile loop
//! (`docs/design/20260827-fyolod-lifecycle-reconcile.md`).
//!
//! Two halves. The **node** half runs on the box, by whatever binary is on
//! disk: `status` reports what is there and `stop` asks the daemon to leave.
//! The **control-plane** half, `reconcile`, runs wherever the desired build
//! lives — the Mac, usually — against a [`Node`], and is the same function for
//! this machine and for a box over ssh; only the transport behind the trait
//! differs. Install is the loop from an empty box, update is the loop from a
//! stale one, and recovery from any failure is running it again.
//!
//! Nothing here needs a daemon that already knows about this module. The
//! daemon is found by the credential the kernel attaches to its socket, asked
//! what it holds with `list` (protocol v1), and stopped with `SIGTERM`, which
//! its drain path has always handled — so the first upgrade works the same as
//! every later one.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::UnixStream;

use crate::paths;
use crate::protocol::{
    read_frame, write_control, ChannelRole, Control, Frame, SessionInfo, PROTOCOL_VERSION,
};

/// The build this binary is: `<app version>+<build number>`, stamped by
/// `build.rs` from the same two values the app bundle carries.
pub const BUILD_VERSION: &str = env!("FYOLOD_VERSION");

/// How long the loop waits for a daemon to answer after it has been asked to
/// start or stop. Autostart binds within a second on a loaded box; the drain
/// after `SIGTERM` has to bury every session first.
const SETTLE: Duration = Duration::from_secs(15);

/// How long one liveness probe may take. A connect to a Unix socket on the same
/// machine either completes at once or is queued behind a listener that is not
/// accepting; a probe that outlives this has learned what it is going to learn,
/// and the settle budget belongs to the next one.
const PROBE: Duration = Duration::from_secs(1);

/// How long to wait between probes. Sized from what is left of the deadline
/// each time, so the last one never sleeps past it.
const POLL: Duration = Duration::from_millis(100);

/// Exit code for a stop the daemon declined because it holds work someone is
/// using. Distinct from failure: the state is named, and running again after
/// the sessions close is the whole recovery.
pub const EXIT_BUSY: i32 = 3;

// MARK: Versions

/// `major.minor.patch+build`, ordered as written. `build` breaks ties between
/// two builds of one version, which is every dev build.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    major: u64,
    minor: u64,
    patch: u64,
    build: u64,
}

impl Version {
    pub fn parse(text: &str) -> Option<Version> {
        let (semver, build) = match text.trim().split_once('+') {
            Some((semver, build)) => (semver, build.parse().ok()?),
            None => (text.trim(), 0),
        };
        let mut parts = semver.split('.').map(|part| part.parse::<u64>().ok());
        let major = parts.next()??;
        let minor = parts.next()??;
        let patch = parts.next()??;
        if parts.next().is_some() {
            return None;
        }
        Some(Version {
            major,
            minor,
            patch,
            build,
        })
    }
}

// MARK: The handshake, without a client

/// What a daemon says about itself at `hello`.
pub struct DaemonHello {
    /// Absent on a daemon that predates the field — older than anything that
    /// reports one, which is how the loop reads it.
    pub version: Option<String>,
    /// The protocol version this handshake negotiated (`hello_ok.proto`).
    pub proto: u32,
    pub host_id: String,
    /// What the daemon can do, from its own `hello_ok`. Read for one thing: a
    /// daemon that does not list `handoff` has to be stopped to be upgraded,
    /// and the loop needs to know that before it takes the destructive path.
    pub caps: Vec<String>,
}

/// `hello` as a control channel with no capabilities, returning the daemon's
/// self-description. Works against every daemon that speaks protocol v1.
pub async fn handshake<R, W>(reader: &mut R, writer: &mut W) -> Result<DaemonHello>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    handshake_asking(reader, writer, Vec::new()).await
}

/// `handshake`, negotiating capabilities. A verb the daemon gates on one — as
/// `handoff` is — is refused unless it was asked for here.
pub async fn handshake_asking<R, W>(
    reader: &mut R,
    writer: &mut W,
    ask: Vec<String>,
) -> Result<DaemonHello>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    write_control(
        writer,
        &Control::Hello {
            proto: PROTOCOL_VERSION,
            min_proto: PROTOCOL_VERSION,
            role: ChannelRole::Control,
            caps: ask,
            client: format!("fyolod-cli/{BUILD_VERSION}"),
        },
    )
    .await?;
    match read_frame(reader).await? {
        Some(Frame::Control(Control::HelloOk {
            proto,
            version,
            host_id,
            caps,
            ..
        })) => Ok(DaemonHello {
            version: version.filter(|value| !value.is_empty()),
            proto,
            host_id,
            caps,
        }),
        Some(Frame::Control(Control::HelloErr { supported, .. })) => bail!(
            "the daemon speaks protocol {supported:?}; this binary speaks {PROTOCOL_VERSION}"
        ),
        Some(_) => bail!("the daemon answered hello with something other than hello_ok"),
        None => bail!("the daemon closed the connection during hello"),
    }
}

async fn list_sessions<R, W>(reader: &mut R, writer: &mut W) -> Result<Vec<SessionInfo>>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    write_control(writer, &Control::List { seq: Some(1) }).await?;
    loop {
        match read_frame(reader).await? {
            Some(Frame::Control(Control::Sessions { sessions, .. })) => return Ok(sessions),
            Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
            Some(_) => continue,
            None => bail!("the daemon closed the connection before answering list"),
        }
    }
}

/// A connection to the daemon on `socket`, or `None` when nothing answers.
/// Never autostarts: the question here is what *is* running.
async fn connect_existing(socket: &Path) -> Option<UnixStream> {
    tokio::time::timeout(Duration::from_secs(5), UnixStream::connect(socket))
        .await
        .ok()?
        .ok()
}

/// The pid of the process on the far end of `stream`, from the kernel. This is
/// the process that *owns the socket* — the only one the loop may ever stop —
/// and it needs no protocol, so it identifies a daemon of any age. Never argv:
/// a box running a second daemon by hand on another socket has the same
/// command line, and matching it is how an upgrade kills the wrong process.
fn peer_pid(stream: &UnixStream) -> Option<i32> {
    use std::os::fd::AsRawFd;
    let descriptor = stream.as_raw_fd();
    #[cfg(target_os = "linux")]
    {
        let mut credential = libc::ucred {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        let result = unsafe {
            libc::getsockopt(
                descriptor,
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                &mut credential as *mut libc::ucred as *mut libc::c_void,
                &mut length,
            )
        };
        (result == 0 && credential.pid > 0).then_some(credential.pid)
    }
    #[cfg(target_os = "macos")]
    {
        const SOL_LOCAL: libc::c_int = 0;
        const LOCAL_PEERPID: libc::c_int = 0x002;
        let mut pid: libc::pid_t = 0;
        let mut length = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
        let result = unsafe {
            libc::getsockopt(
                descriptor,
                SOL_LOCAL,
                LOCAL_PEERPID,
                &mut pid as *mut libc::pid_t as *mut libc::c_void,
                &mut length,
            )
        };
        (result == 0 && pid > 0).then_some(pid)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = descriptor;
        None
    }
}

// MARK: Node side — `fyolod status`

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeStatus {
    pub binary: BinaryStatus,
    /// The `fyolo` client installed beside the daemon binary. Absent when the
    /// file is not there — or when the report comes from a build too old to
    /// look for it, which the loop reads the same way: something to install.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client: Option<BinaryStatus>,
    pub daemon: DaemonStatus,
    pub sessions: Vec<SessionSummary>,
    /// The identity written on the daemon's first start. Present without a
    /// running daemon: it is a file beside the socket.
    pub host_id: Option<String>,
    pub supervisor: Supervisor,
    /// The machine's operating system, as the binary answering knows it
    /// (`macos`, `linux`). Absent from a build too old to report it.
    ///
    /// It is here so the control plane can decide what a machine needs without
    /// asking it a second question: `uname -sm` is a round trip on every deploy
    /// and every attach, and the machine has already answered.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os: Option<String>,
}

impl NodeStatus {
    /// Whether this machine takes a `fyolo` client from a deploy.
    ///
    /// The same rule `remote::target_takes_a_client` applies to a detected
    /// target, answered from the machine's own report instead: a Mac links its
    /// own client from its app bundle and is sent none. A build too old to name
    /// its OS is treated as a box, which is what every machine this loop had
    /// deployed to before Macs were reachable was — and the first upgrade makes
    /// it answer for itself.
    pub fn takes_a_client(&self) -> bool {
        self.os.as_deref() != Some("macos")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BinaryStatus {
    /// The build of the binary answering — the one on disk.
    pub version: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonStatus {
    pub running: bool,
    /// The *running* daemon's build, from its own `hello`. Differs from the
    /// binary's exactly when an update is staged and not yet activated, which
    /// is the state the loop most needs to see. `None` on a daemon too old to
    /// say, or none running.
    pub version: Option<String>,
    /// The protocol version this probe's own handshake with the daemon
    /// negotiated — what `fyolo version` reports for the local daemon.
    /// `None` when no daemon is running.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proto: Option<u32>,
    pub pid: Option<i32>,
    pub socket: String,
}

/// One session, reduced to what a stop decision needs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    pub id: String,
    pub name: String,
    pub command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub status: String,
    pub attached: usize,
    /// A command is running in the foreground — the shell is not at its
    /// prompt. The daemon's own "closing this loses work" signal.
    #[serde(default)]
    pub running: bool,
    pub alive: bool,
}

impl From<SessionInfo> for SessionSummary {
    fn from(info: SessionInfo) -> SessionSummary {
        SessionSummary {
            id: info.id,
            name: info.name,
            command: info.command,
            title: info.title,
            status: info.status,
            attached: info.attached_clients,
            running: info.foreground_job,
            alive: info.alive,
        }
    }
}

impl SessionSummary {
    /// Whether stopping the daemon would take *work* from someone: a command
    /// running in the foreground, or an agent still working or waiting on its
    /// user. The workstream status is in the protocol so a daemon does not
    /// have to guess from a screen, and an agent nobody is watching is exactly
    /// the session "lives on the box" promises to keep.
    ///
    /// Being attached is deliberately not the test. A client on a shell at its
    /// prompt loses nothing but the prompt, and that client is usually the
    /// app whose user just asked for the update — an update the user's own
    /// idle tabs could veto would have them closing tabs to get it.
    pub fn busy(&self) -> bool {
        self.alive && (self.running || matches!(self.status.as_str(), "working" | "needs_you"))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Supervisor {
    None,
    Launchd,
    SystemdUser,
}

/// What this machine has, from the binary that answers: its own build, the
/// daemon on the canonical socket, and that daemon's sessions. One process,
/// one connection — this replaces `test -x`, two handshakes and a roster read
/// as separate round trips over ssh.
pub async fn status() -> Result<NodeStatus> {
    let socket = paths::socket_path()?;
    let binary = BinaryStatus {
        version: BUILD_VERSION.to_string(),
        path: std::env::current_exe()
            .map(|path| path.display().to_string())
            .unwrap_or_default(),
    };
    let client = client_beside_this_binary().await;
    let host_id = paths::stored_host_id();
    let mut daemon = DaemonStatus {
        running: false,
        version: None,
        proto: None,
        pid: None,
        socket: socket.display().to_string(),
    };
    let mut sessions = Vec::new();
    if let Some(mut stream) = connect_existing(&socket).await {
        daemon.running = true;
        daemon.pid = peer_pid(&stream);
        let (mut reader, mut writer) = stream.split();
        let asked = tokio::time::timeout(Duration::from_secs(5), async {
            let hello = handshake(&mut reader, &mut writer).await;
            let list = list_sessions(&mut reader, &mut writer).await;
            (hello, list)
        })
        .await;
        if let Ok((hello, list)) = asked {
            if let Ok(hello) = hello {
                daemon.version = hello.version;
                daemon.proto = Some(hello.proto);
            }
            sessions = list
                .unwrap_or_default()
                .into_iter()
                .map(SessionSummary::from)
                .collect();
        }
    }
    Ok(NodeStatus {
        binary,
        client,
        daemon,
        sessions,
        host_id,
        supervisor: detect_supervisor().await,
        os: Some(std::env::consts::OS.to_string()),
    })
}

/// The `fyolo` client beside this binary, answering for itself. Executed
/// rather than stat'ed because installed means "answers `--version`": a
/// half-copied file or a wrong-architecture slice is exactly what the deploy
/// loop needs to read as something to replace, not something present. An
/// unanswerable client — one that errors, exits nonzero, or hangs past the
/// timeout — reports with an empty version, which no build stamp parses as.
/// The timeout matters because `status` is on the path of every deploy and
/// attach: before this probe existed, `status` executed nothing beside
/// itself, and a wedged client must not turn it into a hang.
async fn client_beside_this_binary() -> Option<BinaryStatus> {
    let candidate = paired_client()?;
    let (_, stamp) = binary_version(&candidate).await;
    Some(BinaryStatus {
        version: stamp.unwrap_or_default(),
        path: candidate.display().to_string(),
    })
}

/// The `fyolo` client installed beside this daemon binary, or `None` when
/// there is none there.
///
/// The directory comes from `argv[0]` whenever this process was started by an
/// absolute path, and from `current_exe` otherwise. The two differ exactly
/// where the daemon's path is a symlink: `current_exe` resolves it
/// (`/proc/self/exe` on Linux), so a daemon installed at
/// `~/.local/bin/fyolod` pointing into `/opt/fyolo` would report a client at
/// `/opt/fyolo/fyolo` while the control plane stages and verifies
/// `~/.local/bin/fyolo`. The two halves then disagree forever — the box
/// verifies as unhealthy while being healthy, or restages every pass. `argv[0]`
/// is the name the control plane actually used, so it is the one that answers.
pub(crate) fn paired_client() -> Option<PathBuf> {
    let invoked = std::env::args_os()
        .next()
        .map(PathBuf::from)
        .filter(|path| path.is_absolute());
    let directory = match invoked {
        Some(path) => path.parent().map(Path::to_path_buf)?,
        None => std::env::current_exe().ok()?.parent().map(Path::to_path_buf)?,
    };
    let candidate = directory.join("fyolo");
    candidate.is_file().then_some(candidate)
}

/// Which init owns the daemon, if any. This is what decides what "restart"
/// means for a node: a supervised daemon is bounced by its supervisor, an
/// unsupervised one is stopped and autostarted by the next client.
async fn detect_supervisor() -> Supervisor {
    if cfg!(target_os = "macos") {
        let target = format!("gui/{}/{}", unsafe { libc::getuid() }, crate::service::label());
        let loaded = tokio::process::Command::new("launchctl")
            .args(["print", &target])
            .output()
            .await
            .map(|output| output.status.success())
            .unwrap_or(false);
        return if loaded {
            Supervisor::Launchd
        } else {
            Supervisor::None
        };
    }
    // Enabled counts as well as active: after a clean `stop` the unit is
    // inactive (`Restart=on-failure` does not restart a clean exit), but the
    // next client contact starts it again through systemd, so systemd still
    // owns whatever runs next. Mirrors "loaded" on launchd, which likewise
    // says nothing about a pid.
    let owned = tokio::task::spawn_blocking(crate::service::systemd_unit_owns_daemon)
        .await
        .unwrap_or(false);
    if owned {
        Supervisor::SystemdUser
    } else {
        Supervisor::None
    }
}

pub fn print_status(status: &NodeStatus) {
    println!("binary:  {} ({})", status.binary.version, status.binary.path);
    if let Some(client) = &status.client {
        println!(
            "client:  {} ({})",
            if client.version.is_empty() {
                "does not answer --version"
            } else {
                &client.version
            },
            client.path
        );
    }
    match (&status.daemon.running, &status.daemon.version, status.daemon.pid) {
        (false, _, _) => println!("daemon:  not running ({})", status.daemon.socket),
        (true, version, pid) => println!(
            "daemon:  {} pid {} ({})",
            version.as_deref().unwrap_or("older than this binary, no version"),
            pid.map(|pid| pid.to_string()).unwrap_or_else(|| "?".to_string()),
            status.daemon.socket
        ),
    }
    if let Some(host_id) = &status.host_id {
        println!("host:    {host_id}");
    }
    println!(
        "service: {}",
        match status.supervisor {
            Supervisor::None => "none (autostarts on first contact)",
            Supervisor::Launchd => "launchd",
            Supervisor::SystemdUser => "systemd --user",
        }
    );
    for session in &status.sessions {
        println!(
            "  {:<10} {:<14} {:<9} {} — {}",
            session.id,
            session.name,
            session.status,
            if session.attached > 0 {
                "attached"
            } else {
                "nobody attached"
            },
            session.command
        );
    }
}

// MARK: Node side — `fyolod stop`

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StopOutcome {
    pub stopped: bool,
    /// The sessions that kept the daemon up, by name — the user decides
    /// whether to close an agent mid-task, and a count cannot inform that.
    pub busy: Vec<SessionSummary>,
    pub message: String,
}

/// Ask the daemon on the canonical socket to leave. Declines while any session
/// is in use unless `force`; nothing running is already the state wanted, so
/// it is success rather than an error.
pub async fn stop(force: bool) -> Result<StopOutcome> {
    let socket = paths::socket_path()?;
    let Some(mut stream) = connect_if_serving(&socket).await? else {
        return Ok(StopOutcome {
            stopped: true,
            busy: Vec::new(),
            message: "no daemon is running".to_string(),
        });
    };
    let Some(pid) = peer_pid(&stream) else {
        bail!(
            "could not identify the process behind {}; not stopping one by guess",
            socket.display()
        );
    };
    if !force {
        let (mut reader, mut writer) = stream.split();
        let sessions = tokio::time::timeout(Duration::from_secs(5), async {
            // The version is not the question here; the handshake is what
            // makes `list` answerable on a negotiated channel.
            let _ = handshake(&mut reader, &mut writer).await;
            list_sessions(&mut reader, &mut writer).await
        })
        .await
        .context("the daemon did not answer in time")?
        .context("asking the daemon what it holds — not stopping it blind")?;
        let busy: Vec<SessionSummary> = sessions
            .into_iter()
            .map(SessionSummary::from)
            .filter(SessionSummary::busy)
            .collect();
        if !busy.is_empty() {
            let message = format!(
                "{} still working on this machine; wait, or pass --force",
                if busy.len() == 1 {
                    "1 session is".to_string()
                } else {
                    format!("{} sessions are", busy.len())
                }
            );
            return Ok(StopOutcome {
                stopped: false,
                busy,
                message,
            });
        }
    }
    drop(stream);

    if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        bail!(
            "sending SIGTERM to pid {pid}: {}",
            std::io::Error::last_os_error()
        );
    }
    // What was asked for is that `pid` stop serving this socket, and that is
    // what is waited on. The two proxies this loop used to read instead each
    // answer a different question: `kill(pid, 0)` succeeds for a *zombie*, so a
    // daemon nobody reaped reads as one that refuses to leave, and the socket
    // file existing says only that a path is occupied — a client autostarting
    // its replacement re-creates it in milliseconds. Together they turned a
    // stop that had already worked into a failed upgrade (#571).
    let deadline = Instant::now() + SETTLE;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            bail!(
                "pid {pid} was asked to stop and is still serving {} after {}s; \
                 its log says what it is waiting on",
                socket.display(),
                SETTLE.as_secs()
            );
        }
        if !still_serving(&socket, pid, remaining.min(PROBE)).await {
            return Ok(StopOutcome {
                stopped: true,
                busy: Vec::new(),
                message: format!("stopped pid {pid}"),
            });
        }
        let left = deadline.saturating_duration_since(Instant::now());
        tokio::time::sleep(left.min(POLL)).await;
    }
}

/// Whether `pid` is still the process behind `socket`.
///
/// The daemon holds its listener bound through the whole drain, on purpose, so
/// that nothing can place a replacement over state still being buried: while it
/// answers here it really is still working, and waiting is right. Nothing
/// answering, or a different pid answering, both mean this daemon let the
/// socket go — which is the postcondition, whatever became of its process
/// table entry afterwards.
///
/// Connect to a daemon that may not be there.
///
/// `Ok(None)` is the one answer that proves nothing is: a connection this
/// process was denied, or one that never completed, is a daemon it could not
/// reach. Reporting that as "no daemon is running" would answer a stop that
/// never happened with success, and the caller would go on to replace a binary
/// under a daemon still serving every session it had.
async fn connect_if_serving(socket: &Path) -> Result<Option<UnixStream>> {
    match tokio::time::timeout(Duration::from_secs(5), UnixStream::connect(socket)).await {
        Ok(Ok(stream)) => Ok(Some(stream)),
        Ok(Err(error)) if nothing_is_serving(error.raw_os_error()) => Ok(None),
        Ok(Err(error)) => Err(anyhow::Error::new(error)
            .context(format!("reaching the daemon at {}", socket.display()))),
        Err(_elapsed) => bail!(
            "the daemon at {} did not accept a connection within 5s",
            socket.display()
        ),
    }
}

/// Whether a failed connect proves nothing is behind the path.
///
/// Three errnos do. `ENOENT` and `ECONNREFUSED` are the socket gone and the
/// socket unserved; `ENOTSOCK` is a plain file where the socket was, which is
/// no daemon either. Everything else is a daemon this process could not reach
/// rather than one that left — `EPERM` from a sandbox, `EAGAIN` from a listener
/// whose backlog is full, `EINTR`, `ETIMEDOUT` — and reading any of those as
/// absence is how a stop reports success over a daemon still holding every
/// session it had.
///
/// This licenses a conclusion, never an action on the path — see
/// [`crate::client::absent_daemon`] for the narrower rule that does.
pub(crate) fn nothing_is_serving(errno: Option<i32>) -> bool {
    matches!(
        errno,
        Some(libc::ENOENT) | Some(libc::ECONNREFUSED) | Some(libc::ENOTSOCK)
    )
}

/// Whether `pid` is still the process behind `socket`, within `budget`.
///
/// Anything short of proof that the path is unserved keeps waiting, and the
/// deadline decides — including a probe that ran out of budget, and a daemon
/// that answers but whose pid the kernel will not name.
async fn still_serving(socket: &Path, pid: i32, budget: Duration) -> bool {
    match tokio::time::timeout(budget, UnixStream::connect(socket)).await {
        Ok(Ok(stream)) => peer_pid(&stream).is_none_or(|serving| serving == pid),
        Ok(Err(error)) => !nothing_is_serving(error.raw_os_error()),
        Err(_elapsed) => true,
    }
}

// MARK: Node side — `fyolod handoff`

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandoffOutcome {
    /// The daemon's pid. Unchanged across a handoff — that is the claim, and
    /// printing it is what lets a human check it.
    pub pid: Option<i32>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub sessions: usize,
    pub message: String,
}

/// The capability a daemon must advertise before it can be asked to hand off.
pub const HANDOFF_CAPABILITY: &str = "handoff";

/// Ask the daemon on the canonical socket to become `binary`.
///
/// Defaults to this executable, which is the shape a control plane wants: stage
/// the new build over the old path, then run the new build's own `handoff`. The
/// daemon vets the path before it takes a single session apart, so a refusal
/// here costs nothing.
pub async fn handoff(binary: Option<PathBuf>) -> Result<HandoffOutcome> {
    let binary = match binary {
        Some(path) => path,
        None => std::env::current_exe().context("resolving this executable")?,
    };
    let binary = binary
        .canonicalize()
        .with_context(|| format!("resolving {}", binary.display()))?;
    // What the daemon should be afterwards is the version of the binary it is
    // becoming, which is only this build when the default was taken. An
    // explicit `--binary` naming an older compatible build is a legitimate
    // request — a rollback — and checking it against this CLI's own stamp would
    // report a handoff that worked as one that failed.
    let (want, want_text) = binary_version(&binary).await;

    let socket = paths::socket_path()?;
    let Some(mut stream) = connect_existing(&socket).await else {
        return Ok(HandoffOutcome {
            pid: None,
            from: None,
            to: None,
            sessions: 0,
            message: "no daemon is running; the next client to connect starts this build"
                .to_string(),
        });
    };
    let pid = peer_pid(&stream);

    let (from, sessions) = {
        let (mut reader, mut writer) = stream.split();
        let hello = tokio::time::timeout(
            Duration::from_secs(5),
            handshake_asking(
                &mut reader,
                &mut writer,
                vec![HANDOFF_CAPABILITY.to_string()],
            ),
        )
        .await
        .context("the daemon did not answer hello in time")?
        .context("asking the daemon what it is")?;
        if !hello.caps.iter().any(|cap| cap == HANDOFF_CAPABILITY) {
            bail!(
                "the daemon running here ({}) cannot replace its own binary; stop it to upgrade",
                hello.version.as_deref().unwrap_or("no version")
            );
        }
        let sessions = list_sessions(&mut reader, &mut writer).await.unwrap_or_default();
        write_control(
            &mut writer,
            &Control::Handoff {
                binary: binary.display().to_string(),
                seq: Some(1),
            },
        )
        .await?;
        // The reply says the daemon accepted, not that it finished: the exec
        // follows it and takes this connection with it. Anything after this is
        // read from the *new* image, over a new connection.
        match read_frame(&mut reader).await? {
            Some(Frame::Control(Control::Ok { .. })) => {}
            Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
            Some(_) => bail!("the daemon answered handoff with something else"),
            None => bail!("the daemon closed the connection without answering handoff"),
        }
        // This connection dies with the image, so its EOF *is* the exec. That
        // makes it the only honest signal a client has: an `ok` here means the
        // request was accepted, not that anything happened, and a handoff that
        // aborts leaves this connection open and serving. Waiting was already
        // right; throwing the answer away was not. On a same-build handoff the
        // version cannot tell the two apart, so without this the CLI reported an
        // aborted upgrade as a completed one.
        let crossed = tokio::time::timeout(SETTLE, async {
            while let Ok(Some(_)) = read_frame(&mut reader).await {}
        })
        .await
        .is_ok();
        if !crossed {
            bail!(
                "the daemon accepted the handoff but is still answering on the \
                 connection that asked for it, so the exec never happened — the \
                 sessions are untouched; its log says why"
            );
        }
        (hello.version, sessions.len())
    };
    drop(stream);

    let deadline = Instant::now() + SETTLE;
    let mut last = None;
    while Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let Some(mut stream) = connect_existing(&socket).await else {
            continue;
        };
        let now_pid = peer_pid(&stream);
        let (mut reader, mut writer) = stream.split();
        let Ok(Ok(hello)) = tokio::time::timeout(
            Duration::from_secs(5),
            handshake(&mut reader, &mut writer),
        )
        .await
        else {
            continue;
        };
        let reported = hello.version.as_deref().and_then(Version::parse);
        if want.is_some() && reported < want {
            last = hello.version;
            continue;
        }
        // A different pid means the daemon was replaced rather than rebuilt:
        // something stopped it and something else autostarted. The sessions did
        // not survive that, so it must not be reported as a handoff.
        if pid.is_some() && now_pid != pid {
            bail!(
                "the daemon answering now is pid {} where the handoff started at pid {} — it was restarted, not handed off",
                now_pid.map(|value| value.to_string()).unwrap_or_else(|| "?".to_string()),
                pid.map(|value| value.to_string()).unwrap_or_else(|| "?".to_string())
            );
        }
        let carried = list_sessions(&mut reader, &mut writer)
            .await
            .map(|list| list.len())
            .unwrap_or(0);
        let to = hello.version;
        return Ok(HandoffOutcome {
            pid: now_pid,
            from: from.clone(),
            to: to.clone(),
            sessions: carried,
            message: format!(
                "pid {} is now fyolod {}; {carried} of {sessions} session(s) carried",
                now_pid.map(|value| value.to_string()).unwrap_or_else(|| "?".to_string()),
                to.as_deref().unwrap_or("an unnamed build")
            ),
        });
    }
    bail!(
        "the daemon did not come back as {} within {}s (last seen: {})",
        want_text.as_deref().unwrap_or("the requested build"),
        SETTLE.as_secs(),
        last.as_deref().unwrap_or("nothing answering")
    )
}

/// The build stamp a candidate binary reports — parsed, and as it printed it.
///
/// `None` is not a failure: it means the version check is skipped and the
/// handoff is judged on the pid and the reconnect alone. Refusing to hand off
/// to a binary whose `--version` this build cannot parse would be refusing on
/// the strength of a string. A nonzero exit is `None` too: a stamp printed on
/// the way to failing is not an answer, and `verify_client` holds the same
/// line — a probe that accepted it would mask exactly what verification
/// exists to catch.
/// Bounded, because a binary that blocks on `--version` is one of the things
/// this is looking for: a wrapper waiting on the network, a wedged home
/// directory. Unbounded, it hung the command that asked with nothing on screen.
pub(crate) async fn binary_version(binary: &Path) -> (Option<Version>, Option<String>) {
    let answered = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::process::Command::new(binary)
            .arg("--version")
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true)
            .output()
            .await
            .ok()
    })
    .await
    .ok()
    .flatten();
    let stamp = answered
        .filter(|output| output.status.success())
        .and_then(|output| version_stamp(&String::from_utf8_lossy(&output.stdout)));
    (stamp.as_deref().and_then(Version::parse), stamp)
}

/// The first word of `printed` that parses as a build stamp.
fn version_stamp(printed: &str) -> Option<String> {
    printed
        .split_whitespace()
        .find(|word| Version::parse(word).is_some())
        .map(str::to_string)
}

/// `fyolod handoff` — the CLI around [`handoff`].
pub async fn run_handoff(json: bool, binary: Option<PathBuf>) -> Result<()> {
    let outcome = handoff(binary).await?;
    if json {
        println!("{}", serde_json::to_string(&outcome)?);
    } else {
        println!("{}", outcome.message);
    }
    Ok(())
}

// MARK: Control-plane side — the loop

/// What one command on a node produced. `Err` from [`Node::run`] is reserved
/// for the transport failing; a command that ran and failed is an `Ok(Run)`
/// with a non-zero code, because the two mean different things to the loop.
#[derive(Debug, Clone, Default)]
pub struct Run {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// The transport to a node failed — ssh could not connect, or authenticate.
/// Its own error type so the loop can name the state (`unreachable`) rather
/// than fold it into "something failed".
#[derive(Debug)]
pub struct Unreachable(pub String);

impl std::fmt::Display for Unreachable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Unreachable {}

/// A machine the loop can act on. Everything the loop needs from a node is
/// these five operations; the arms — this machine, a Linux box over ssh, a
/// Mac over ssh — differ only in how they carry them out.
pub trait Node {
    /// How the node is named in messages: the ssh alias, or "this Mac".
    fn label(&self) -> String;
    /// The daemon binary's path, as the node's own shell should see it.
    fn binary(&self) -> String;
    /// Run a shell command on the node.
    fn run(&self, command: &str) -> impl std::future::Future<Output = Result<Run>> + Send;
    /// Copy `local` to `<name>` beside the daemon binary on the node.
    fn put(&self, local: &Path, name: &str) -> impl std::future::Future<Output = Result<()>> + Send;
    /// The build this control plane would install on the node — the daemon,
    /// and the `fyolo` client that ships beside it in the same pass
    /// (docker-lessons RFC §1.2), so a box's client and daemon are always the
    /// same build and skew between them is structurally impossible.
    ///
    /// `client_only` says the daemon plane is already current and only the
    /// client is being repaired. A node that would have to *build* the daemon
    /// to answer must decline instead: the machine is healthy, this runs before
    /// every attach, and starting a cross-compile — or failing for the want of
    /// one — is not something a client repair may cost.
    fn artifact(
        &self,
        client_only: bool,
    ) -> impl std::future::Future<Output = Result<Artifacts>> + Send;
    /// The client binary's path on the node, as the node's own shell should
    /// see it — or `None` on a node whose client ships another way (this
    /// Mac's lives inside the app bundle), which turns every client step of
    /// the loop off.
    fn client_binary(&self) -> Option<String>;
    /// Handshake with the node's daemon, starting it if nothing answers —
    /// which is the contact that brings a freshly staged binary up.
    fn hello(&self) -> impl std::future::Future<Output = Result<DaemonHello>> + Send;
    /// How the node recovers when a new image fails verification. The default
    /// is the staging convention: `.prev` sits beside the binary and moves
    /// back over it. The local node overrides it — its binary lives inside a
    /// signed bundle nothing may write to, so its known-good copy is a stash
    /// this loop keeps (`preserve_command`), and it is tried even on a run
    /// that staged nothing, because the local node never stages at all.
    fn rollback_plan(&self) -> RollbackPlan {
        RollbackPlan {
            source: format!("{}.prev", self.binary()),
            restores_path: true,
            even_unstaged: false,
        }
    }
    /// A command that keeps the just-verified binary where `rollback_plan`
    /// expects to find it, run after an upgrade verifies. `None` where staging
    /// already left `.prev` behind.
    fn preserve_command(&self) -> Option<String> {
        None
    }

    /// Where this control plane may note that a client repair did not take, so
    /// the next one waits instead of going again on the next attach. The wait
    /// grows with each failure and stops at a cap, so nothing is ever written
    /// off: a short upload, a host that dropped and a machine that refuses the
    /// file all get another attempt, which is why none of them has to be told
    /// apart from the others. Stamped with the build, so other bytes get their
    /// own first chance, and forgotten as soon as a client installs.
    ///
    /// `None` turns the memory off, which is right for a node that installs no
    /// client at all — and keeps a node that is not a real machine from writing
    /// anywhere. Only a client-*only* pass consults it: a daemon upgrade is
    /// sending a build to the machine regardless, and the client rides along for
    /// almost nothing.
    fn client_repair_note(&self) -> Option<PathBuf> {
        None
    }
}

/// What [`Node::artifact`] stages: one build, both binaries. Every build of
/// this crate produces both, so `client` is `None` only when a developer's
/// `--bin` override points at a daemon with no client beside it — and that
/// same override turns the node's client plane off (`client_binary` returns
/// `None`), so the two stay consistent rather than shipping half a build.
#[derive(Debug, Clone)]
pub struct Artifacts {
    pub daemon: PathBuf,
    pub client: Option<PathBuf>,
}

/// See [`Node::rollback_plan`].
#[derive(Debug, Clone)]
pub struct RollbackPlan {
    /// The known-good binary to hand the unhealthy daemon back to.
    pub source: String,
    /// Whether `source` is then moved back over the binary's path, so the
    /// next autostart runs the build that worked.
    pub restores_path: bool,
    /// Attempt the rollback even when this run staged nothing.
    pub even_unstaged: bool,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Options {
    /// Stop the daemon even while sessions are in use.
    pub force: bool,
    /// Put the binary in place and stop there; the daemon is not touched.
    pub stage_only: bool,
    /// Upgrade only through the handoff rung: when the daemon cannot hand
    /// off and holds any live session — busy or idle — leave it running and
    /// report `staged` naming them, instead of stopping. The mode for a
    /// caller nobody asked, like the app's launch reconcile: an idle shell
    /// declines a `stop` nothing (`SessionSummary::busy` lets it through by
    /// design, for the user who clicked Update), but an automatic caller has
    /// no user behind it to have consented.
    pub handoff_only: bool,
}

/// The state a node was left in. Every variant is a place the loop can resume
/// from by being run again; none is an instruction to the user beyond what the
/// variant carries.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Outcome {
    /// The daemon running is the desired build, or a newer one.
    Current {
        version: String,
        host_id: String,
        /// The protocol the verifying handshake negotiated (`hello_ok.proto`).
        /// Optional so a report written by an older build still parses.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proto: Option<u32>,
        /// Another control plane put a newer build here. Left alone.
        newer: bool,
        /// What is wrong with the `fyolo` client beside the daemon, or what
        /// could not be learned about it. The daemon is still the build wanted
        /// and the machine is still usable — that is why this rides `Current`
        /// rather than a failure: a report that could not name the host would
        /// have every reader treat a healthy box as unusable.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        client: Option<String>,
        /// Whether that note is the client's own fault rather than something
        /// this pass could not find out. Only a fault fails the deploy: ssh
        /// being flaky for the seconds of a `--version` probe is not a reason
        /// to call an otherwise perfect deploy failed, and it must still be
        /// *said*, which is why it is a separate question from `client`.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        client_failed: bool,
    },
    /// The binary is in place and the daemon still running is the old one.
    /// `busy` is why it was not stopped — empty when stopping was not asked for.
    Staged {
        version: String,
        daemon: Option<String>,
        busy: Vec<SessionSummary>,
        /// What is wrong with the `fyolo` client, or what could not be learned
        /// about it — the same note `Current` carries, under the same key, so a
        /// reader does not have to ask which rung it is looking at.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        client: Option<String>,
    },
    /// The new daemon did not verify. `rolled_back` means the previous binary is
    /// back in place and whatever it autostarts next is the build that worked.
    /// Only ever the daemon: a client that fails verification leaves the machine
    /// running and is reported on `Current`.
    Unhealthy { message: String, rolled_back: bool },
    /// The transport failed; nothing on the node was touched.
    Unreachable { message: String },
    /// A step failed in a way the loop could not classify.
    Failed { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Report {
    pub node: String,
    pub desired: String,
    #[serde(flatten)]
    pub outcome: Outcome,
}

impl Report {
    pub fn exit_code(&self) -> i32 {
        match self.outcome {
            // A client at fault is still a failed deploy for whoever ran one,
            // even though the machine came out of it working. One this pass
            // merely could not reach is not.
            Outcome::Current { client_failed: true, .. } => 1,
            Outcome::Current { .. } => 0,
            Outcome::Staged { .. } => EXIT_BUSY,
            _ => 1,
        }
    }

    /// One line per state, for a terminal.
    pub fn describe(&self) -> String {
        let node = &self.node;
        match &self.outcome {
            Outcome::Current {
                version,
                host_id,
                newer,
                client,
                ..
            } => format!(
                "{node}: fyolod {version} is running (host {host_id}){}{}",
                if *newer {
                    " — newer than this build, left alone"
                } else {
                    ""
                },
                match client {
                    Some(trouble) => format!("\n{trouble}"),
                    None => String::new(),
                }
            ),
            Outcome::Staged {
                version,
                daemon,
                busy,
                client,
            } if busy.is_empty() => format!(
                "{node}: fyolod {version} is staged; the running daemon ({}) takes over once it is stopped{}",
                daemon.as_deref().unwrap_or("no version"),
                match client {
                    Some(trouble) => format!("\n{trouble}"),
                    None => String::new(),
                }
            ),
            Outcome::Staged { version, busy, client, .. } => {
                let mut text = format!(
                    "{node}: fyolod {version} is staged, but the daemon still running there has work in progress:"
                );
                for session in busy {
                    text.push_str(&format!(
                        "\n  • {} — {} ({})",
                        session.title.as_deref().unwrap_or(&session.name),
                        session.command,
                        session.status
                    ));
                }
                text.push_str("\nRun this again once it finishes, or pass --force to stop it now.");
                // The client rides this rung as much as the others; destructured
                // away, the note reached the app and the JSON but never the
                // person reading the command's own output.
                if let Some(trouble) = client {
                    text.push('\n');
                    text.push_str(trouble);
                }
                text
            }
            Outcome::Unhealthy {
                message,
                rolled_back,
            } => format!(
                "{node}: the new fyolod did not come up — {message}{}",
                if *rolled_back {
                    "\nThe previous binary is back in place."
                } else {
                    ""
                }
            ),
            Outcome::Unreachable { message } => format!("{node}: unreachable — {message}"),
            Outcome::Failed { message } => format!("{node}: {message}"),
        }
    }
}

enum Observed {
    /// No binary at the path.
    Absent,
    /// A binary that predates `status` — it cannot say what it is, only that
    /// it is older than this build.
    OldBinary,
    Reported(NodeStatus),
}

/// Observe → stage → activate → verify → roll back, and a report of where
/// that left the node. Never returns an error: every failure is a state.
pub async fn reconcile<N: Node>(node: &N, desired: &str, options: Options) -> Report {
    let outcome = match run_loop(node, desired, options).await {
        Ok(outcome) => outcome,
        Err(error) => match error.downcast_ref::<Unreachable>() {
            Some(unreachable) => Outcome::Unreachable {
                message: unreachable.0.clone(),
            },
            None => Outcome::Failed {
                message: format!("{error:#}"),
            },
        },
    };
    Report {
        node: node.label(),
        desired: desired.to_string(),
        outcome,
    }
}

async fn run_loop<N: Node>(node: &N, desired: &str, options: Options) -> Result<Outcome> {
    let want = Version::parse(desired)
        .with_context(|| format!("desired version {desired:?} is not a build stamp"))?;
    let label = node.label();

    let repair_note = node.client_repair_note();
    // What this pass will have to say about the client even when it stages
    // nothing for it. A note that stops a doomed repair may not also stop the
    // box from reporting the skew it is carrying.
    let mut client_skew: Option<(String, bool)> = None;
    let mut observed = observe(node).await?;
    let plan = match &observed {
        Observed::Absent | Observed::OldBinary => Some(StagePlan::Full),
        Observed::Reported(status) => match Version::parse(&status.binary.version) {
            None => Some(StagePlan::Full),
            Some(have) if have < want => Some(StagePlan::Full),
            // A newer control plane owns this box, client and all; nothing
            // here may downgrade any part of it.
            Some(have) if have > want => None,
            // The daemon binary is already this build. The client ships in
            // the same pass, so a box missing it — or holding one from
            // another build — is staged again, client only: re-renaming the
            // daemon would destroy `fyolod.prev`, the box's one rollback
            // point, to repair a file the daemon plane never lost.
            Some(_) => {
                // A machine that takes no client — a Mac, which links its own
                // from its app bundle — is current by having none. Asked only of
                // the node's own report, never of the network: planning a client
                // pass for one meant a `uname` round trip on every deploy and
                // every attach, to stage nothing and say so wrongly.
                let takes_client = node.client_binary().is_some() && status.takes_a_client();
                // `>=`, the same line `verify_client` holds: a client newer than
                // this build is one a newer plane installed, and restaging would
                // downgrade what verification would have accepted. Reachable
                // whenever a rollback put the daemon back without its client.
                let client_current = !takes_client
                    || status
                        .client
                        .as_ref()
                        .and_then(|client| Version::parse(&client.version))
                        .is_some_and(|have| have >= want);
                if client_current {
                    // A delayed repair is plainly moot once the machine has the
                    // client it was for.
                    clear_client_repair(repair_note.as_deref());
                    None
                } else if let Some(wait) =
                    client_repair_waiting(repair_note.as_deref(), desired)
                {
                    // Installing this build's client here failed recently, so it
                    // waits rather than going again on this attach — but the
                    // machine is carrying a client that is not this build, and it
                    // says so every pass until that changes. Silence here would
                    // report the exact skew §1.2 exists to prevent as a clean
                    // bill of health.
                    client_skew = Some((
                        format!(
                            "the client on {label} is {}, not {desired}; installing this build's \
                             here failed, and it is tried again in {}",
                            status
                                .client
                                .as_ref()
                                .map(|client| client.version.as_str())
                                .filter(|version| !version.is_empty())
                                .unwrap_or("missing"),
                            describe_wait(wait),
                        ),
                        true,
                    ));
                    None
                } else {
                    Some(StagePlan::ClientOnly)
                }
            }
        },
    };
    // What this run put on the node, per plane. Every undo below reads this and
    // nothing else: a run that staged only the client may not touch the daemon,
    // and one that staged no client may not touch the client — the box's own,
    // which it has been using all along, is not this run's to restore or remove.
    let mut staged = Staged::default();
    if let Some(plan) = plan {
        staged = match stage(node, plan).await {
            Ok(staged) => staged,
            // A client-only pass may not fail the reconcile. It repairs a machine
            // whose daemon is already the build wanted, and it runs before every
            // attach — so an upload that fails, or an activation that does, would
            // have made a healthy box unreachable ("Couldn't set up fyolod on
            // …") over the CLI inside its sessions.
            Err(error)
                if plan == StagePlan::ClientOnly
                    // A host that dropped is unreachable, which is a state of its
                    // own: swallowed here it came back as `Unhealthy`, after a
                    // full settle budget spent waiting for a daemon nothing
                    // could reach.
                    && error.downcast_ref::<Unreachable>().is_none() =>
            {
                eprintln!("[deploy] {label}'s client could not be installed ({error:#}); leaving it as it is");
                // Put off rather than written off, and with no need to work out
                // which kind of failure this was: a host that dropped, a control
                // plane without the slice and a machine that refuses the file all
                // want another attempt, just not on the next attach. And none of
                // them establishes anything about the *binary*, which is what
                // calling it the client's fault would claim — this pass never got
                // to run it.
                let wait = delay_client_repair(repair_note.as_deref(), desired);
                // The same fault the next passes report: this one did the failing
                // work and left the box on a client that is not this build, so it
                // would be the odd one out calling that a success while every
                // later pass that attempts nothing calls it a failure.
                client_skew = Some((
                    format!("{error:#}; tried again in {}", describe_wait(wait)),
                    true,
                ));
                Staged::default()
            }
            Err(error) => return Err(error),
        };
        match (staged.daemon, staged.client) {
            (true, true) => eprintln!("[deploy] installed fyolod {desired} and its client on {label}"),
            (true, false) => eprintln!("[deploy] installed fyolod {desired} on {label}"),
            (false, true) => eprintln!("[deploy] installed the fyolo {desired} client on {label}"),
            // Nothing reached the node, so nothing is announced; whatever
            // declined to ship a client said why.
            (false, false) => {}
        }
        // Only a node something landed on can have a new answer.
        if staged.anything() {
            observed = observe(node).await?;
        }
    }
    let Observed::Reported(status) = observed else {
        bail!("fyolod was installed on {label} but does not answer `status` there");
    };

    // The client this pass installed is answered for here, before any of the
    // ways out below. It needs nothing from the daemon — it is one `--version`
    // over ssh — and every rung that returns early was otherwise leaving a box
    // holding a client nothing had run, already at the head of every session's
    // PATH through the daemon's own symlink, with the report silent about it.
    if staged.client {
        client_skew = match verify_client(node, want).await {
            ClientVerdict::Good => {
                clear_client_repair(repair_note.as_deref());
                None
            }
            ClientVerdict::Bad(message) => {
                let removed = roll_back_client(node).await.is_ok();
                let wait = delay_client_repair(repair_note.as_deref(), desired);
                Some((
                    format!(
                        "{message}{}; installing it again in {}",
                        if removed {
                            "; it was taken back off the box"
                        } else {
                            "; it could not be taken back off the box"
                        },
                        describe_wait(wait),
                    ),
                    true,
                ))
            }
            ClientVerdict::Unknown(message) => Some((message, false)),
        };
    }

    if options.stage_only {
        return Ok(Outcome::Staged {
            version: status.binary.version,
            daemon: status.daemon.version,
            busy: Vec::new(),
            client: client_skew.as_ref().map(|(note, _)| note.clone()),
        });
    }

    let daemon_is_stale = status.daemon.running
        && status
            .daemon
            .version
            .as_deref()
            .and_then(Version::parse)
            .map_or(true, |have| have < want);
    if daemon_is_stale {
        // Handoff first, always. It is not an optimisation over stopping: it is
        // the difference between an upgrade the user pays for in lost work and
        // one they do not notice. Stopping stays as the fallback for a daemon
        // too old to replace its own image, and as what `--force` reaches for
        // when the handoff itself fails.
        eprintln!("[deploy] asking the daemon on {label} to take on the new binary…");
        let handoff = node.run(&format!("{} handoff --json", node.binary())).await?;
        if handoff.code == 0 {
            eprintln!("[deploy] {}", handoff_line(&handoff.stdout));
        } else {
            if options.handoff_only {
                let alive: Vec<SessionSummary> = status
                    .sessions
                    .iter()
                    .filter(|session| session.alive)
                    .cloned()
                    .collect();
                if !alive.is_empty() {
                    eprintln!(
                        "[deploy] {label} could not hand off ({}); its sessions stay up",
                        last_line(&handoff.stderr)
                    );
                    return Ok(Outcome::Staged {
                        version: status.binary.version.clone(),
                        daemon: status.daemon.version.clone(),
                        busy: alive,
                        client: client_skew.as_ref().map(|(note, _)| note.clone()),
                    });
                }
                // A daemon holding no session has nothing a stop can cost, so
                // handoff-only still takes the bounce — but only on a roster
                // read after the handoff attempt: a session created since the
                // first snapshot must veto it. A daemon on this rung predates
                // the handoff verb, so it cannot be asked to refuse a stop
                // atomically; the read-to-stop gap is the window that remains,
                // and anything short of a fresh read (an error included) keeps
                // the daemon up rather than stopping on a stale picture.
                match observe(node).await {
                    Ok(Observed::Reported(fresh)) => {
                        let alive: Vec<SessionSummary> = fresh
                            .sessions
                            .iter()
                            .filter(|session| session.alive)
                            .cloned()
                            .collect();
                        if !alive.is_empty() {
                            return Ok(Outcome::Staged {
                                version: fresh.binary.version,
                                daemon: fresh.daemon.version,
                                busy: alive,
                                client: client_skew.as_ref().map(|(note, _)| note.clone()),
                            });
                        }
                    }
                    _ => {
                        return Ok(Outcome::Staged {
                            version: status.binary.version.clone(),
                            daemon: status.daemon.version.clone(),
                            busy: Vec::new(),
                            client: client_skew.as_ref().map(|(note, _)| note.clone()),
                        });
                    }
                }
            }
            eprintln!(
                "[deploy] {label} could not hand off ({}); stopping it instead",
                last_line(&handoff.stderr)
            );
            // The bounce is the same under every supervisor: `stop` SIGTERMs the
            // daemon and waits for the socket to go, and `verify` reconnects,
            // which autostarts the staged binary. Under launchd `KeepAlive`
            // respawns it; under systemd a clean exit leaves the unit inactive
            // (`Restart=on-failure`) and the reconnect's `spawn_daemon` starts
            // the unit again, so the new daemon comes up supervised rather than
            // as a `setsid` orphan.
            eprintln!("[deploy] asking the daemon on {label} to stop…");
            let command = format!(
                "{} stop --json{}",
                node.binary(),
                if options.force { " --force" } else { "" }
            );
            let run = node.run(&command).await?;
            match run.code {
                0 => {}
                EXIT_BUSY => {
                    let outcome: StopOutcome = serde_json::from_str(run.stdout.trim())
                        .context("reading the daemon's answer to stop")?;
                    return Ok(Outcome::Staged {
                        version: status.binary.version,
                        daemon: status.daemon.version,
                        busy: outcome.busy,
                        client: client_skew.as_ref().map(|(note, _)| note.clone()),
                    });
                }
                _ => bail!("stopping fyolod on {label}: {}", last_line(&run.stderr)),
            }
        }
    }

    // The two planes are verified — and answered for — separately. Folding the
    // client's verdict into the daemon's put a box's every live session at the
    // mercy of one artifact the daemon does not depend on: a truncated `fyolo`
    // drove the daemon rollback, whose fallback is `stop --force`, and SIGTERMed
    // every agent on a box whose daemon had verified perfectly.
    let (hello, version) = match verify_daemon(node, want).await {
        Ok(answered) => answered,
        Err(error) => {
            let message = format!("{error:#}");
            let plan = node.rollback_plan();
            // Only a run that staged a *daemon* may undo one. A client-only
            // pass that trips this arm would otherwise move `fyolod.prev` over
            // a daemon binary it never wrote — downgrading the box and spending
            // its one rollback point over an artifact it never touched.
            let rolled_back = (staged.daemon || plan.even_unstaged)
                && roll_back(node, &plan, staged).await.is_ok();
            return Ok(Outcome::Unhealthy {
                message,
                rolled_back,
            });
        }
    };

    // Settled above, before the first way out of this function.
    let client_trouble = client_skew;

    if daemon_is_stale || staged.daemon {
        // Best effort: a copy that fails costs the *next* upgrade its free
        // rollback, not this one anything.
        if let Some(preserve) = node.preserve_command() {
            let _ = node.run(&preserve).await;
        }
    }
    Ok(Outcome::Current {
        version: hello.version.unwrap_or_default(),
        host_id: hello.host_id,
        proto: Some(hello.proto),
        newer: version > want,
        client: client_trouble.as_ref().map(|(note, _)| note.clone()),
        client_failed: client_trouble.is_some_and(|(_, fault)| fault),
    })
}

/// What a reconcile pass needs to put on the node: the whole build, or only
/// the `fyolo` client when the daemon plane is already current.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StagePlan {
    Full,
    ClientOnly,
}

/// How long a client repair waits before it is tried again, and the longest that
/// wait grows to.
///
/// It is a wait rather than a refusal because a repair that did not take says
/// almost nothing about whether the next one will: a short upload, a host that
/// dropped, a control plane without the slice, a disk that was full an hour ago.
/// Those all want another attempt, just not on every attach. The first minute
/// costs a blip nothing, and the cap means a machine that truly cannot take the
/// client spends one upload every few hours instead of one each time someone
/// reaches it.
const CLIENT_REPAIR_WAIT: Duration = Duration::from_secs(60);
const CLIENT_REPAIR_WAIT_CAP: Duration = Duration::from_secs(6 * 60 * 60);

/// What a note holds: the build whose client would not install, how many times
/// it has been tried, and when it may be tried again.
struct ClientRepairWait {
    build: String,
    attempts: u32,
    after: SystemTime,
}

/// How much longer a client repair for `desired` should be left alone, or `None`
/// when it is due — including because nothing is remembered, or because what is
/// remembered is about another build and this one has not been tried yet.
fn client_repair_waiting(note: Option<&Path>, desired: &str) -> Option<Duration> {
    let waiting = read_client_repair(note?)?;
    if waiting.build != desired {
        return None;
    }
    waiting.after.duration_since(SystemTime::now()).ok()
}

fn read_client_repair(path: &Path) -> Option<ClientRepairWait> {
    let written = std::fs::read_to_string(path).ok()?;
    let mut fields = written.split_whitespace();
    let build = fields.next()?.to_string();
    let attempts = fields.next()?.parse().ok()?;
    let seconds: u64 = fields.next()?.parse().ok()?;
    Some(ClientRepairWait {
        build,
        attempts,
        after: SystemTime::UNIX_EPOCH + Duration::from_secs(seconds),
    })
}

/// Put a client repair for `desired` off for a while, longer each time it fails.
fn delay_client_repair(note: Option<&Path>, desired: &str) -> Duration {
    let attempts = note
        .and_then(read_client_repair)
        .filter(|waiting| waiting.build == desired)
        .map_or(0, |waiting| waiting.attempts)
        .saturating_add(1);
    let wait = CLIENT_REPAIR_WAIT
        .saturating_mul(1u32 << attempts.saturating_sub(1).min(16))
        .min(CLIENT_REPAIR_WAIT_CAP);
    if let Some(path) = note {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let due = SystemTime::now() + wait;
        let seconds = due
            .duration_since(SystemTime::UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        let _ = std::fs::write(path, format!("{desired} {attempts} {seconds}"));
    }
    wait
}

/// Forget a delayed repair, because one just installed.
fn clear_client_repair(note: Option<&Path>) {
    if let Some(path) = note {
        let _ = std::fs::remove_file(path);
    }
}

/// A wait, for a sentence a person reads.
fn describe_wait(wait: Duration) -> String {
    let minutes = wait.as_secs() / 60;
    match minutes {
        0 => "shortly".to_string(),
        1 => "a minute".to_string(),
        2..=90 => format!("{minutes} minutes"),
        _ => format!("{} hours", (minutes + 30) / 60),
    }
}

async fn observe<N: Node>(node: &N) -> Result<Observed> {
    let run = node
        .run(&format!("{} status --json", node.binary()))
        .await?;
    if run.code == 0 {
        let status: NodeStatus = serde_json::from_str(run.stdout.trim())
            .context("reading the node's status report")?;
        return Ok(Observed::Reported(status));
    }
    let stderr = run.stderr.to_ascii_lowercase();
    // The shell's own verdicts. 127 is "command not found"; clap exits 2 for a
    // subcommand this binary does not have, which only an older build lacks.
    if run.code == 127 || stderr.contains("no such file") || stderr.contains("not found") {
        return Ok(Observed::Absent);
    }
    if run.code == 2 && (stderr.contains("unrecognized subcommand") || stderr.contains("unexpected argument")) {
        return Ok(Observed::OldBinary);
    }
    bail!(
        "fyolod on {} could not report its status: {}",
        node.label(),
        last_line(&run.stderr)
    )
}

/// Upload beside the target and rename over it, keeping the previous binary
/// as `.prev`. Atomic on the filesystem, and safe against a running daemon —
/// it keeps the old inode until it exits, which is the handover wanted. Linux
/// refuses to open a running executable for writing (`ETXTBSY`), so writing
/// in place is the one shape that always fails when a box is in use.
async fn stage<N: Node>(node: &N, plan: StagePlan) -> Result<Staged> {
    // Every failure here is the caller's to judge: a client-only pass is allowed
    // to fail without failing the reconcile, and that holds for the artifact it
    // cannot produce, the upload that does not land, and the activation that does
    // not run — not only the first of the three.
    let artifacts = node.artifact(plan == StagePlan::ClientOnly).await?;
    let mut staged = Staged::default();
    let mut command = String::new();
    if plan == StagePlan::Full {
        node.put(&artifacts.daemon, "fyolod.new").await?;
        command = swap_command(&node.binary(), "fyolod_replaced");
        staged.daemon = true;
    }
    // The client lands in the same pass, with the same discipline, activated
    // by the same shell command — the narrowest window there is for a box to
    // hold one binary of a build without the other. When the client's half
    // fails after the daemon's rename succeeded, the daemon is renamed back
    // in the same command: a failed stage must leave the box as it was, not
    // holding a new daemon beside an old client — the exact skew this loop
    // exists to prevent — with `.prev` already spent.
    // A build with no client for this node deploys the daemon alone rather than
    // failing: a Mac is sent none by design, and `cargo build --bin fyolod` in
    // a checkout produces none at all — a deploy that worked before this pass
    // must not become one that cannot be done. Only a real bundle's missing
    // Linux slice is an error, and `Node::artifact` is where that is refused.
    // Silent here because neither case is a degradation this step discovered:
    // the artifact source names the one that is.
    if let (Some(local), Some(client)) = (&artifacts.client, node.client_binary()) {
        node.put(local, "fyolo.new").await?;
        let client_swap = swap_command(&client, "fyolo_replaced");
        command = if command.is_empty() {
            client_swap
        } else {
            format!(
                "{command} && {{ {client_swap} || {{ {}; false; }}; }}",
                // The daemon's undo reads the same shell variable its own swap
                // set, so it puts back only what this command renamed aside.
                shell_restore(&node.binary(), "fyolod_replaced")
            )
        };
        staged.client = true;
    }
    if command.is_empty() {
        return Ok(staged);
    }
    // The activation reports what it renamed aside, because it is the only thing
    // that looked. Deriving it here from the observation instead read a field
    // (`status.client`) that only a daemon built from this pass onward reports,
    // so on the first upgrade of a box already in the field the loop concluded
    // there had been no client — and a client that then failed verification was
    // removed rather than put back from the `fyolo.prev` this very stage had
    // just written. Every existing box passes through that once.
    command.push_str(&format!(" && echo \"{STAGE_REPORT} client_replaced=${{fyolo_replaced:-0}}\""));
    let run = node.run(&command).await?;
    if run.code != 0 {
        bail!(
            "installing the binary on {}: {}",
            node.label(),
            last_line(&run.stderr)
        );
    }
    staged.client_replaced = staged.client
        && run
            .stdout
            .lines()
            .any(|line| line.contains(STAGE_REPORT) && line.contains("client_replaced=1"));
    Ok(staged)
}

/// Marks the activation's own account of itself, so a login banner on the way
/// through cannot be mistaken for it.
const STAGE_REPORT: &str = "fyolod-stage:";

/// Which planes a stage actually put on the node. A pass that shipped no client
/// — because this build has none — turns the client plane off for the rest of
/// the run, so nothing is verified against a client that was never sent.
#[derive(Debug, Clone, Copy, Default)]
struct Staged {
    daemon: bool,
    client: bool,
    /// Whether the stage renamed a previous *client* aside — the fact an undo in
    /// a later ssh command needs and cannot read off the disk, since a
    /// `fyolo.prev` sitting there says nothing about whose it is. Reported by
    /// the activation command itself, which is the only thing that tested the
    /// path at the moment it mattered.
    ///
    /// There is deliberately no daemon twin. The daemon's `.prev` is the box's
    /// rollback point and is kept across runs on purpose, so a failed upgrade
    /// hands back to whatever known-good build is there rather than to nothing;
    /// the client's is not a rollback point but a skew risk, because a client
    /// from an earlier build beside this build's daemon is exactly what the
    /// same-pass rule exists to prevent.
    client_replaced: bool,
}

impl Staged {
    fn anything(&self) -> bool {
        self.daemon || self.client
    }
}

/// Upload-activate for one binary: rename the current file aside as `.prev`,
/// put the `.new` upload over the path — and if that last rename fails, undo it,
/// so a partial swap never leaves the path empty.
///
/// `replaced` names a shell variable this records the answer in: set when the
/// rename-aside actually moved something, empty when there was nothing at the
/// path to move. That is what an undo needs, and it cannot be read off the disk
/// afterwards — a `.prev` sitting there may be this run's or an older run's, and
/// the two call for opposite moves. Restoring an older one installs the build
/// some *earlier* deploy replaced: a 0.43 client beside a 0.44 daemon, reported
/// as a successful rollback.
///
/// A `.prev` this run did not write is never deleted either. Clearing it up
/// front — to make the file itself mean "this run" — threw away a working
/// previous daemon whenever the binary happened to be missing at stage time,
/// leaving a box that then failed verification with nothing to hand back to.
fn swap_command(target: &str, replaced: &str) -> String {
    format!(
        "chmod +x {target}.new && {{ if [ -e {target} ]; then mv -f {target} {target}.prev && {replaced}=1; else {replaced}=; fi; }} && {{ mv -f {target}.new {target} || {{ {}; false; }}; }}",
        shell_restore(target, replaced)
    )
}

/// The undo for a swap in the *same* shell command, reading the variable that
/// swap set: the build it renamed aside, or removal where it installed onto an
/// empty path.
fn shell_restore(target: &str, replaced: &str) -> String {
    // Copied to a temporary name and renamed over the path, rather than moved
    // straight back: the rename is what keeps the replacement atomic, and the
    // copy is what leaves `.prev` where it was. Moving it back put the right
    // daemon on the box with nothing beside it to roll back to — exactly the
    // "`.prev` already spent" state the stage is supposed to prevent.
    format!(
        "if [ -n \"${replaced}\" ]; then cp -f {target}.prev {target}.undo && mv -f {target}.undo {target}; else rm -f {target}; fi"
    )
}

/// The undo for a swap that happened in an *earlier* ssh command, where no shell
/// variable survives. The control plane knows what that swap found — it observed
/// the node before staging — so it says whether a previous build was renamed
/// aside, and the same two moves follow.
fn restore_command(target: &str, replaced: bool) -> String {
    if replaced {
        format!("mv -f {target}.prev {target}")
    } else {
        // Removal is what makes "a failed stage leaves the box as it was" true
        // where this run installed onto an empty path. The `.prev` beside it is
        // an older run's and stays untouched, still there for a `handoff
        // --binary` to reach for.
        format!("rm -f {target}")
    }
}

/// Run the installed client over the node's own shell. Existence is not the
/// question — `stage` just put it there — but a wrong-architecture slice or a
/// truncated copy execs and fails, and finding that out here, while `.prev` is
/// still beside it, is the whole point of verifying before reporting.
async fn verify_client<N: Node>(node: &N, want: Version) -> ClientVerdict {
    let Some(client) = node.client_binary() else {
        return ClientVerdict::Good;
    };
    // Retried within the same budget the daemon probe uses, and for the same
    // reason: ssh failing is not the client answering. Taken as a verdict, a
    // dropped connection during the probe had the loop delete the very client it
    // had just correctly installed.
    let deadline = Instant::now() + SETTLE;
    let mut unreachable = String::new();
    loop {
        match node.run(&format!("{client} --version")).await {
            Ok(run) if run.code != 0 => {
                return ClientVerdict::Bad(format!(
                    "the client at {client} does not answer --version: {}",
                    last_line(&run.stderr)
                ))
            }
            Ok(run) => {
                return match run.stdout.split_whitespace().find_map(Version::parse) {
                    Some(stamp) if stamp >= want => ClientVerdict::Good,
                    Some(_) => ClientVerdict::Bad(format!(
                        "the client at {client} answers as an older build ({})",
                        last_line(&run.stdout)
                    )),
                    None => ClientVerdict::Bad(format!(
                        "the client at {client} answers --version with no build stamp ({})",
                        last_line(&run.stdout)
                    )),
                }
            }
            Err(error) => unreachable = format!("{error:#}"),
        }
        if Instant::now() >= deadline {
            return ClientVerdict::Unknown(format!(
                "could not reach {} to check the client at {client}: {unreachable}",
                node.label()
            ));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// What a probe of the installed client established.
enum ClientVerdict {
    /// It answered as the build wanted, or newer.
    Good,
    /// It answered, and the answer is the client's own fault.
    Bad(String),
    /// The machine could not be asked, so nothing about the client is known.
    /// Never grounds for undoing an install: a dropped connection is not a
    /// verdict on a binary, and the next pass asks again.
    Unknown(String),
}

/// Handshake with whatever answers now — which, after a stop, is the daemon
/// autostart brings up from the staged binary — and check it is the build
/// wanted, or a newer one.
async fn verify_daemon<N: Node>(node: &N, want: Version) -> Result<(DaemonHello, Version)> {
    let deadline = Instant::now() + SETTLE;
    let mut last_error = None;
    while Instant::now() < deadline {
        match node.hello().await {
            Ok(hello) => {
                let Some(version) = hello.version.as_deref().and_then(Version::parse) else {
                    // A daemon with no version is the old one, still up: the
                    // socket it is draining has not gone yet. Ask again.
                    last_error = Some(anyhow::anyhow!(
                        "the daemon that answered is an older build with no version"
                    ));
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    continue;
                };
                if version < want {
                    last_error = Some(anyhow::anyhow!(
                        "the daemon that answered is {}, older than {}",
                        hello.version.as_deref().unwrap_or_default(),
                        BUILD_VERSION
                    ));
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    continue;
                }
                return Ok((hello, version));
            }
            Err(error) => {
                last_error = Some(error);
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow::anyhow!("no daemon answered")))
}

/// Put the previous binary back, asking the daemon to hand off to it first —
/// the same pid keeps every PTY — and stopping only when that also fails, so
/// an image that turned out bad costs the sessions only when there is no
/// non-destructive way back.
async fn roll_back<N: Node>(node: &N, plan: &RollbackPlan, staged: Staged) -> Result<()> {
    let binary = node.binary();
    let label = node.label();
    let source = &plan.source;
    eprintln!("[deploy] rolling {label} back to the previous binary…");
    let prev = node.run(&format!("[ -e {source} ]")).await?;
    if prev.code != 0 {
        bail!("no previous binary to roll back to on {label}");
    }
    // The previous build's own CLI drives the recovery: the staged binary just
    // failed verification, so it is the last thing to trust with it.
    let handoff = node
        .run(&format!("{source} handoff --binary {source} --json"))
        .await;
    match handoff {
        Ok(run) if run.code == 0 => {
            // With no path restore, the handoff is the only way the source
            // build ever serves again — so "no daemon was running" (exit 0,
            // no pid) is not a recovery: the next autostart runs the binary
            // that just failed, and reporting rolled-back would say otherwise.
            if !plan.restores_path {
                let handed_to_a_daemon = serde_json::from_str::<HandoffOutcome>(run.stdout.trim())
                    .map(|outcome| outcome.pid.is_some())
                    .unwrap_or(false);
                if !handed_to_a_daemon {
                    bail!("nothing was serving on {label} to hand back to the previous binary");
                }
            }
            eprintln!("[deploy] {}", handoff_line(&run.stdout));
        }
        outcome => {
            let reason = match &outcome {
                Ok(run) => last_line(&run.stderr),
                Err(error) => format!("{error:#}"),
            };
            // Same rule: stopping restores nothing when the path is not
            // restored — autostart would bring the failed build right back —
            // so it would spend the sessions to change nothing.
            if !plan.restores_path {
                bail!("could not hand {label} back to the previous binary: {reason}");
            }
            eprintln!("[deploy] {label} could not hand back ({reason}); stopping it instead");
            let _ = node.run(&format!("{binary} stop --force --json")).await;
        }
    }
    if plan.restores_path {
        // The rename keeps the old inode alive for the daemon now exec'd from
        // it, while the path serves the build that worked to the next
        // autostart.
        let run = node.run(&format!("mv -f {source} {binary}")).await?;
        if run.code != 0 {
            bail!(
                "restoring the previous binary on {label}: {}",
                last_line(&run.stderr)
            );
        }
        // The client comes back only where this run replaced one, and its
        // failure is a note rather than the rollback's.
        //
        // Both halves were bugs. Restoring on `client_binary().is_some()` alone
        // ran `rm -f` over a client this run never staged — a working client,
        // deleted because a *daemon* failed to verify, on any node whose build
        // ships no client of its own. And chaining it onto the daemon's restore
        // under one exit code reported the whole rollback as failed when only
        // the client would not move, telling an operator the box was left on
        // the build that broke it while the daemon had already been put back.
        if staged.client {
            if let Some(client) = node.client_binary() {
                let restored = node.run(&restore_command(&client, staged.client_replaced)).await;
                if !matches!(&restored, Ok(run) if run.code == 0) {
                    eprintln!(
                        "[deploy] {label} is back on the previous daemon, but its client could not be \
                         restored; the next deploy replaces it"
                    );
                }
            }
        }
    }
    Ok(())
}

/// Take a client that failed verification back off the box.
///
/// It is removed, not replaced by the one it displaced: the daemon here is
/// staying on the new build, and the older client beside it is the skew §1.2
/// exists to rule out. A machine with no `fyolo` is a state the next pass
/// closes — nothing even leads its sessions' PATH with a client that is not
/// there — and one with the wrong `fyolo` is not.
async fn roll_back_client<N: Node>(node: &N) -> Result<()> {
    let Some(client) = node.client_binary() else {
        return Ok(());
    };
    let label = node.label();
    eprintln!("[deploy] taking the client that did not verify back off {label}…");
    let run = node.run(&format!("rm -f {client}")).await?;
    if run.code != 0 {
        bail!(
            "removing the client that did not verify on {label}: {}",
            last_line(&run.stderr)
        );
    }
    Ok(())
}

/// The one line worth showing from a `handoff --json` reply, falling back to
/// the raw output when the node answered with something this build cannot read.
fn handoff_line(stdout: &str) -> String {
    serde_json::from_str::<HandoffOutcome>(stdout.trim())
        .map(|outcome| outcome.message)
        .unwrap_or_else(|_| last_line(stdout))
}

fn last_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .last()
        .unwrap_or("no output")
        .to_string()
}

// MARK: This machine

/// The node this process runs on. Its daemon is the binary running this code,
/// so there is nothing to stage: the loop here is observe → stop-if-idle →
/// verify, which is what picks a new build up after the app updated.
pub struct LocalNode;

impl Node for LocalNode {
    fn label(&self) -> String {
        "this machine".to_string()
    }

    fn binary(&self) -> String {
        std::env::current_exe()
            .map(|path| shell_quote(&path.display().to_string()))
            .unwrap_or_else(|_| "fyolod".to_string())
    }

    async fn run(&self, command: &str) -> Result<Run> {
        let output = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(command)
            .output()
            .await
            .context("running sh")?;
        Ok(Run {
            code: output.status.code().unwrap_or(1),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }

    async fn put(&self, _local: &Path, _name: &str) -> Result<()> {
        bail!("this machine's fyolod ships inside the app; update the app to update it")
    }

    async fn artifact(&self, _client_only: bool) -> Result<Artifacts> {
        bail!("this machine's fyolod ships inside the app; update the app to update it")
    }

    fn client_binary(&self) -> Option<String> {
        // The Mac's client ships inside the app bundle and reaches PATH
        // through the app's own support copy; the loop installs nothing here.
        None
    }

    async fn hello(&self) -> Result<DaemonHello> {
        let mut stream = crate::client::connect().await?;
        let (mut reader, mut writer) = stream.split();
        tokio::time::timeout(Duration::from_secs(5), handshake(&mut reader, &mut writer))
            .await
            .context("the daemon did not answer hello in time")?
    }

    fn rollback_plan(&self) -> RollbackPlan {
        // The binary lives inside a signed app bundle nothing may write to,
        // so the known-good copy is the stash `preserve_command` keeps in
        // durable state, and the path is never restored — the bundle stays
        // whatever the app shipped. With no stash yet (a box this loop has
        // not upgraded before), the default `.prev` beside the bundle binary
        // never exists and the rollback declines without touching anything.
        match Self::stash_path() {
            Some(stash) => RollbackPlan {
                source: stash,
                restores_path: false,
                even_unstaged: true,
            },
            // No durable state dir means no stash was ever kept; this source
            // never exists, so the rollback declines at its existence check.
            None => RollbackPlan {
                source: format!("{}.prev", self.binary()),
                restores_path: false,
                even_unstaged: true,
            },
        }
    }

    fn preserve_command(&self) -> Option<String> {
        let stash = Self::stash_path()?;
        let dir = paths::durable_state_dir().ok()?;
        // Copy beside, rename over: an interrupted copy must leave the
        // previous stash intact, since it is the only rollback there is.
        Some(format!(
            "mkdir -p {} && cp -f {} {stash}.new && mv -f {stash}.new {stash}",
            shell_quote(&dir.display().to_string()),
            self.binary()
        ))
    }
}

impl LocalNode {
    /// Where the last verified daemon binary is kept for rollback: durable
    /// state, because the socket's directory is a tmpfs on Linux and the
    /// previous app bundle is gone the moment an update lands.
    fn stash_path() -> Option<String> {
        let dir = paths::durable_state_dir().ok()?;
        Some(shell_quote(&dir.join("fyolod.prev").display().to_string()))
    }
}

/// Single-quote shell escaping for a path this loop hands to `sh -c`.
pub fn shell_quote(text: &str) -> String {
    if !text.is_empty()
        && text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b'/' | b'=' | b'@' | b':'))
    {
        return text.to_string();
    }
    format!("'{}'", text.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::VecDeque;

    /// Which answers a liveness probe is allowed to end the wait on. An
    /// unserved path is the daemon having let it go; a path this process merely
    /// could not reach is not, and ending a stop on that would report an
    /// upgrade over a daemon still holding every session it had.
    ///
    /// The other unserved shape — a socket file the daemon could not unlink on
    /// the way out, which answers `ECONNREFUSED` — is the one #571 was reported
    /// on, and `stop_succeeds_when_the_daemon_left_its_socket_and_its_pid_behind`
    /// covers it end to end against a real daemon.
    #[tokio::test]
    async fn only_an_unserved_socket_ends_the_wait() {
        use std::os::unix::fs::PermissionsExt;

        let ours = std::process::id() as i32;
        let dir = std::path::PathBuf::from(format!("/tmp/tss-{ours}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir(&dir).expect("test directory");

        // Nothing at the path at all: ENOENT.
        let missing = dir.join("missing.sock");
        assert!(!still_serving(&missing, ours, PROBE).await);

        // A plain file where the socket was: no daemon, and one that cannot be
        // autostarted over either — which is why the two rules differ.
        let occupied = dir.join("occupied.sock");
        std::fs::write(&occupied, b"not a socket").expect("occupying file");
        assert!(!still_serving(&occupied, ours, PROBE).await);

        // Someone is serving it. The same pid means the daemon is still there
        // — mid-drain, which is what the settle budget is for — and a different
        // pid means it went and something else took the path over.
        let live = dir.join("live.sock");
        let listener = tokio::net::UnixListener::bind(&live).expect("bind");
        assert!(still_serving(&live, ours, PROBE).await);
        assert!(!still_serving(&live, ours + 1, PROBE).await);
        drop(listener);

        // Denied, not absent. The daemon may be serving perfectly well behind a
        // sandbox this process cannot cross, so the wait continues.
        let denied = dir.join("denied.sock");
        let listener = tokio::net::UnixListener::bind(&denied).expect("bind");
        std::fs::set_permissions(&denied, std::fs::Permissions::from_mode(0o000))
            .expect("deny the socket");
        assert!(still_serving(&denied, ours + 1, PROBE).await);
        drop(listener);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn versions_order_by_release_then_build() {
        let parse = |text| Version::parse(text).expect(text);
        assert!(parse("0.43.0+100") < parse("0.44.0+1"));
        assert!(parse("0.44.0+1") < parse("0.44.0+2"));
        assert!(parse("0.44.0") == parse("0.44.0+0"));
        assert!(parse("0.0.0+1533") < parse("0.1.0+0"));
        assert!(parse("1.0.0+5") > parse("0.99.99+999"));
    }

    #[test]
    fn a_crate_version_or_garbage_is_not_a_build_stamp() {
        assert!(Version::parse("").is_none());
        assert!(Version::parse("fyolod/0.1.0 linux-aarch64").is_none());
        assert!(Version::parse("0.44").is_none());
        assert!(Version::parse("0.44.0.1").is_none());
        assert!(Version::parse("0.44.0+abc").is_none());
    }

    /// Busy is about work, not watchers: a command in the foreground or an
    /// agent mid-task holds the daemon up; a client attached to an idle prompt
    /// does not, because that client is usually the app asking for the update.
    #[test]
    fn a_session_is_busy_when_work_is_in_progress_not_when_someone_is_attached() {
        let session = |attached, running, status: &str, alive| SessionSummary {
            id: "1".into(),
            name: "s".into(),
            command: "bash".into(),
            title: None,
            status: status.into(),
            attached,
            running,
            alive,
        };
        assert!(!session(0, false, "unknown", true).busy());
        assert!(!session(1, false, "idle", true).busy());
        assert!(!session(3, false, "done", true).busy());
        assert!(session(0, true, "unknown", true).busy());
        assert!(session(0, false, "working", true).busy());
        assert!(session(0, false, "needs_you", true).busy());
        assert!(!session(1, true, "working", false).busy());
    }

    /// The build stamp `build.rs` produces always parses — the loop's desired
    /// version is never garbage.
    #[test]
    fn this_build_has_a_comparable_version() {
        assert!(Version::parse(BUILD_VERSION).is_some(), "{BUILD_VERSION}");
    }

    /// A node scripted as a sequence of answers, one per operation, so every
    /// state in the RFC's table can be walked without a machine.
    struct FakeNode {
        runs: RefCell<VecDeque<Run>>,
        hellos: RefCell<VecDeque<Result<DaemonHello>>>,
        commands: RefCell<Vec<String>>,
        puts: RefCell<Vec<String>>,
        plan: Option<RollbackPlan>,
        preserve: Option<String>,
        client: Option<String>,
        /// The client this build would ship. `None` is a daemon-only build.
        client_artifact: Option<PathBuf>,
        /// Where a refused client repair is remembered, when a test cares.
        repair_note: Option<PathBuf>,
        /// Makes `put` fail the way ssh does when the host drops.
        unreachable_put: bool,
        /// What `fyolo --version` answers. Kept out of the scripted queue so a
        /// test states what the client does rather than where in the sequence it
        /// is asked — the loop is free to ask earlier or later. `None` falls
        /// through to the queue, which is how a test makes the box unreachable
        /// for the probe.
        client_version: Option<Run>,
    }

    impl FakeNode {
        fn new(runs: Vec<Run>, hellos: Vec<Result<DaemonHello>>) -> FakeNode {
            FakeNode {
                runs: RefCell::new(runs.into()),
                hellos: RefCell::new(hellos.into()),
                commands: RefCell::new(Vec::new()),
                puts: RefCell::new(Vec::new()),
                plan: None,
                preserve: None,
                client: Some("$HOME/.local/bin/fyolo".to_string()),
                client_artifact: Some(PathBuf::from("/bundle/fyolo-aarch64-unknown-linux-musl")),
                repair_note: None,
                unreachable_put: false,
                client_version: Some(client_answers()),
            }
        }

        /// The local node's shape: a stash instead of `.prev`, no path
        /// restore, rollback attempted even unstaged, and no client to
        /// install — the Mac's ships inside the app bundle.
        fn local_style(mut self) -> FakeNode {
            self.plan = Some(RollbackPlan {
                source: "/state/fyolod.prev".to_string(),
                restores_path: false,
                even_unstaged: true,
            });
            self.preserve =
                Some("mkdir -p /state && cp -f $HOME/.local/bin/fyolod /state/fyolod.prev".to_string());
            self.client = None;
            self
        }
    }

    // The fake is single-threaded by construction; the trait's `Send` bound
    // is for the ssh arm's sake.
    unsafe impl Sync for FakeNode {}

    impl Node for FakeNode {
        fn label(&self) -> String {
            "box".to_string()
        }
        fn binary(&self) -> String {
            "$HOME/.local/bin/fyolod".to_string()
        }
        async fn run(&self, command: &str) -> Result<Run> {
            self.commands.borrow_mut().push(command.to_string());
            if command.ends_with("fyolo --version") {
                if let Some(answer) = self.client_version.clone() {
                    return Ok(answer);
                }
            }
            self.runs
                .borrow_mut()
                .pop_front()
                .ok_or_else(|| anyhow::anyhow!("unscripted command: {command}"))
        }
        async fn put(&self, local: &Path, name: &str) -> Result<()> {
            if self.unreachable_put {
                return Err(Unreachable("ssh: connect to host box port 22: Broken pipe".into()).into());
            }
            self.puts.borrow_mut().push(format!("{} → {name}", local.display()));
            Ok(())
        }
        async fn artifact(&self, _client_only: bool) -> Result<Artifacts> {
            Ok(Artifacts {
                daemon: PathBuf::from("/bundle/fyolod-aarch64-unknown-linux-musl"),
                client: self.client_artifact.clone(),
            })
        }
        fn client_binary(&self) -> Option<String> {
            self.client.clone()
        }
        async fn hello(&self) -> Result<DaemonHello> {
            self.hellos
                .borrow_mut()
                .pop_front()
                .unwrap_or_else(|| Err(anyhow::anyhow!("unscripted hello")))
        }
        fn rollback_plan(&self) -> RollbackPlan {
            self.plan.clone().unwrap_or(RollbackPlan {
                source: format!("{}.prev", self.binary()),
                restores_path: true,
                even_unstaged: false,
            })
        }
        fn preserve_command(&self) -> Option<String> {
            self.preserve.clone()
        }
        fn client_repair_note(&self) -> Option<PathBuf> {
            self.repair_note.clone()
        }
    }

    /// What the activation echoes when it renamed a client aside, which is what
    /// the loop reads to know whose `fyolo.prev` is on the box.
    fn staged_over_a_client() -> Run {
        ok("fyolod-stage: client_replaced=1")
    }

    fn ok(stdout: &str) -> Run {
        Run {
            code: 0,
            stdout: stdout.to_string(),
            stderr: String::new(),
        }
    }

    fn failed(code: i32, stderr: &str) -> Run {
        Run {
            code,
            stdout: String::new(),
            stderr: stderr.to_string(),
        }
    }

    fn status_json(binary: &str, daemon: Option<&str>, running: bool) -> String {
        status_json_holding(binary, daemon, running, Vec::new())
    }

    fn status_json_holding(
        binary: &str,
        daemon: Option<&str>,
        running: bool,
        sessions: Vec<SessionSummary>,
    ) -> String {
        status_json_with_client(binary, Some(binary), daemon, running, sessions)
    }

    fn status_json_with_client(
        binary: &str,
        client: Option<&str>,
        daemon: Option<&str>,
        running: bool,
        sessions: Vec<SessionSummary>,
    ) -> String {
        serde_json::to_string(&NodeStatus {
            binary: BinaryStatus {
                version: binary.to_string(),
                path: "/home/u/.local/bin/fyolod".to_string(),
            },
            client: client.map(|version| BinaryStatus {
                version: version.to_string(),
                path: "/home/u/.local/bin/fyolo".to_string(),
            }),
            daemon: DaemonStatus {
                running,
                version: daemon.map(str::to_string),
                proto: running.then_some(1),
                pid: running.then_some(4242),
                socket: "/run/user/1001/fyolod/fyolod.sock".to_string(),
            },
            sessions,
            host_id: Some("h_1".to_string()),
            supervisor: Supervisor::None,
            os: Some("linux".to_string()),
        })
        .expect("status serializes")
    }

    /// What a Mac reachable over ssh reports: it links its own client from its
    /// app bundle, so it is sent none and is not missing one.
    fn status_json_from_a_mac(binary: &str, daemon: Option<&str>) -> String {
        let mut status: serde_json::Value =
            serde_json::from_str(&status_json_with_client(binary, None, daemon, true, Vec::new()))
                .expect("status parses");
        status["os"] = "macos".into();
        status.to_string()
    }

    /// A shell at its prompt with someone attached: alive, not busy — exactly
    /// what `stop` lets through and `--handoff-only` must not.
    fn idle_shell() -> SessionSummary {
        SessionSummary {
            id: "1".into(),
            name: "1".into(),
            command: "zsh".into(),
            title: Some("~/project".into()),
            status: "idle".into(),
            attached: 1,
            running: false,
            alive: true,
        }
    }

    fn hello(version: Option<&str>) -> Result<DaemonHello> {
        Ok(DaemonHello {
            version: version.map(str::to_string),
            proto: 1,
            host_id: "h_1".to_string(),
            caps: vec![HANDOFF_CAPABILITY.to_string()],
        })
    }

    /// What a daemon that can replace its own image answers `handoff --json`.
    fn handed_off(sessions: usize) -> Run {
        ok(&serde_json::to_string(&HandoffOutcome {
            pid: Some(4242),
            from: Some("0.43.0+1500".to_string()),
            to: Some(WANT.to_string()),
            sessions,
            message: format!("pid 4242 is now fyolod {WANT}; {sessions} of {sessions} session(s) carried"),
        })
        .unwrap())
    }

    /// What a daemon too old to know the verb answers.
    fn cannot_hand_off() -> Run {
        failed(2, "error: unrecognized subcommand 'handoff'")
    }

    /// What the freshly installed client answers `--version`.
    fn client_answers() -> Run {
        ok(&format!("fyolo {WANT} (release)"))
    }

    const WANT: &str = "0.44.0+1600";

    /// Install from an empty box: the binary is staged, nothing is stopped, and
    /// the verify handshake is what starts the daemon.
    #[tokio::test]
    async fn an_empty_box_is_installed_and_verified() {
        let node = FakeNode::new(
            vec![
                failed(127, "bash: /home/u/.local/bin/fyolod: No such file or directory"),
                ok(""), // chmod + mv, both binaries
                ok(&status_json(WANT, None, false)),
            ],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { ref version, newer: false, .. } if version == WANT), "{report:?}");
        // The client ships in the same pass: two uploads, one activation
        // command carrying the rename-over discipline for both binaries.
        let puts = node.puts.borrow();
        assert_eq!(puts.len(), 2, "{puts:?}");
        assert!(puts[0].ends_with("→ fyolod.new"), "{puts:?}");
        assert!(puts[1].ends_with("→ fyolo.new"), "{puts:?}");
        let commands = node.commands.borrow();
        assert!(commands[1].contains("mv -f $HOME/.local/bin/fyolod.new $HOME/.local/bin/fyolod"), "{}", commands[1]);
        assert!(commands[1].contains("mv -f $HOME/.local/bin/fyolo.new $HOME/.local/bin/fyolo"), "{}", commands[1]);
        assert!(commands.last().unwrap().ends_with("fyolo --version"), "{commands:?}");
        assert!(!commands.iter().any(|command| command.contains(" stop")));
    }

    /// A binary too old to answer `status` is staged first and asked again with
    /// the new one — the first-upgrade path, which needs nothing from the old
    /// build but a path.
    #[tokio::test]
    async fn an_old_binary_is_staged_before_it_is_asked_anything() {
        let node = FakeNode::new(
            vec![
                failed(2, "error: unrecognized subcommand 'status'"),
                ok(""),
                ok(&status_json(WANT, None, true)), // old daemon: running, no version
                cannot_hand_off(),
                ok(""), // stop
            ],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(commands[1].contains("fyolod.prev"), "{}", commands[1]);
        assert!(commands.iter().any(|command| command.ends_with("handoff --json")), "{commands:?}");
        assert!(commands.iter().any(|command| command.ends_with("stop --json")), "{commands:?}");
    }

    /// The whole point: a daemon that can take on the new binary is never
    /// stopped, so the sessions running under it are never asked about.
    #[tokio::test]
    async fn a_daemon_that_can_hand_off_is_never_stopped() {
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""), // chmod + mv
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(3),
            ],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(commands.iter().any(|command| command.ends_with("handoff --json")), "{commands:?}");
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
    }

    /// A daemon busy enough to refuse a stop is upgraded anyway when it can
    /// hand off — the state that used to leave a box permanently staged.
    #[tokio::test]
    async fn a_busy_daemon_is_upgraded_by_handing_off() {
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(1),
            ],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
        assert_eq!(report.exit_code(), 0);
    }

    /// The daemon declining to stop is a named state with the sessions in it,
    /// not a failure — the binary stays staged for the next run.
    #[tokio::test]
    async fn a_busy_daemon_leaves_the_update_staged() {
        let busy = StopOutcome {
            stopped: false,
            busy: vec![SessionSummary {
                id: "1".into(),
                name: "claude".into(),
                command: "claude".into(),
                title: None,
                status: "working".into(),
                attached: 0,
                running: true,
                alive: true,
            }],
            message: "1 session is in use".into(),
        };
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                cannot_hand_off(),
                Run {
                    code: EXIT_BUSY,
                    stdout: serde_json::to_string(&busy).unwrap(),
                    stderr: String::new(),
                },
            ],
            vec![],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        match &report.outcome {
            Outcome::Staged { busy, daemon, .. } => {
                assert_eq!(busy.len(), 1);
                assert_eq!(busy[0].name, "claude");
                assert_eq!(daemon.as_deref(), Some("0.43.0+1500"));
            }
            other => panic!("expected staged, got {other:?}"),
        }
        assert_eq!(report.exit_code(), EXIT_BUSY);
    }

    /// Handoff-only: a daemon that cannot hand off and holds a live session —
    /// even an idle one `stop` would let through — is left running and
    /// reported staged with that session named.
    #[tokio::test]
    async fn handoff_only_never_stops_a_daemon_holding_a_live_session() {
        let node = FakeNode::new(
            vec![
                ok(&status_json_holding("0.43.0+1500", Some("0.43.0+1500"), true, vec![idle_shell()])),
                ok(""), // stage: chmod + mv
                ok(&status_json_holding(WANT, Some("0.43.0+1500"), true, vec![idle_shell()])),
                cannot_hand_off(),
            ],
            vec![],
        );
        let options = Options { handoff_only: true, ..Options::default() };
        let report = reconcile(&node, WANT, options).await;
        match &report.outcome {
            Outcome::Staged { busy, .. } => {
                assert_eq!(busy.len(), 1);
                assert_eq!(busy[0].command, "zsh");
            }
            other => panic!("expected staged, got {other:?}"),
        }
        let commands = node.commands.borrow();
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
    }

    /// Handoff-only still bounces a daemon holding nothing: an empty daemon
    /// has nothing a stop can cost. The emptiness is read again after the
    /// failed handoff, not taken from the opening snapshot.
    #[tokio::test]
    async fn handoff_only_still_bounces_an_empty_daemon() {
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                cannot_hand_off(),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)), // still empty
                ok(""),                                            // stop
            ],
            vec![hello(Some(WANT))],
        );
        let options = Options { handoff_only: true, ..Options::default() };
        let report = reconcile(&node, WANT, options).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(commands.iter().any(|command| command.ends_with("stop --json")), "{commands:?}");
    }

    /// A session created between the opening snapshot and the failed handoff
    /// vetoes the bounce: the fresh read finds it, and nothing is stopped.
    #[tokio::test]
    async fn handoff_only_vetoes_the_bounce_on_a_session_created_meanwhile() {
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)), // empty when read
                cannot_hand_off(),
                ok(&status_json_holding(WANT, Some("0.43.0+1500"), true, vec![idle_shell()])),
            ],
            vec![],
        );
        let options = Options { handoff_only: true, ..Options::default() };
        let report = reconcile(&node, WANT, options).await;
        match &report.outcome {
            Outcome::Staged { busy, .. } => assert_eq!(busy.len(), 1),
            other => panic!("expected staged, got {other:?}"),
        }
        let commands = node.commands.borrow();
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
    }

    /// The local shape: nothing stages (the bundle already carries the new
    /// build), so a verify failure recovers through the kept stash — handed
    /// back, never stopped, and the bundle path never written.
    #[tokio::test]
    async fn a_local_verify_failure_is_handed_back_to_the_stash() {
        let node = FakeNode::new(
            vec![
                ok(&status_json(WANT, Some("0.43.0+1500"), true)), // binary already new: no stage
                handed_off(3),
                ok(""),        // roll back: [ -e stash ]
                handed_off(3), // roll back: handoff --binary stash
            ],
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        )
        .local_style();
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unhealthy { rolled_back: true, .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(
            commands.iter().any(|command| command.contains("/state/fyolod.prev handoff --binary /state/fyolod.prev")),
            "{commands:?}"
        );
        assert!(!commands.iter().any(|command| command.starts_with("mv")), "{commands:?}");
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
    }

    /// A handback that found no daemon to hand to is not a recovery when
    /// nothing restores the path: the next autostart would run the failed
    /// build, so the report must not claim rolled-back.
    #[tokio::test]
    async fn a_local_handback_that_finds_no_daemon_is_not_a_recovery() {
        let nobody = ok(&serde_json::to_string(&HandoffOutcome {
            pid: None,
            from: None,
            to: None,
            sessions: 0,
            message: "no daemon is running; the next client to connect starts this build".into(),
        })
        .unwrap());
        let node = FakeNode::new(
            vec![
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(3),
                ok(""), // roll back: [ -e stash ]
                nobody, // roll back: handoff finds nothing serving
            ],
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        )
        .local_style();
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unhealthy { rolled_back: false, .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
    }

    /// A failed local handback never falls through to a stop: with no path to
    /// restore, stopping spends the sessions to change nothing.
    #[tokio::test]
    async fn a_failed_local_handback_never_stops() {
        let node = FakeNode::new(
            vec![
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(3),
                ok(""), // roll back: [ -e stash ]
                failed(1, "the daemon did not answer hello in time"),
            ],
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        )
        .local_style();
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unhealthy { rolled_back: false, .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
    }

    /// A verified upgrade keeps a copy of the binary where the next rollback
    /// looks for it.
    #[tokio::test]
    async fn a_verified_upgrade_preserves_the_binary_for_the_next_rollback() {
        let node = FakeNode::new(
            vec![
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(3),
                ok(""), // preserve: mkdir + cp
            ],
            vec![hello(Some(WANT))],
        )
        .local_style();
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(
            commands.last().unwrap().contains("cp -f"),
            "{commands:?}"
        );
    }

    /// An unhealthy new image is handed back to the previous binary — same
    /// pid, sessions kept — and nothing on the box is stopped.
    #[tokio::test]
    async fn an_unhealthy_new_image_is_rolled_back_without_stopping() {
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                staged_over_a_client(), // stage: chmod + mv
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(3), // the daemon takes the bad image on
                ok(""),        // roll back: [ -e prev ]
                handed_off(3), // roll back: handoff --binary prev
                ok(""),        // roll back: mv prev back
                ok(""),        // roll back: the client, in its own command
            ],
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unhealthy { rolled_back: true, .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(
            commands.iter().any(|command| command.contains("handoff --binary")),
            "{commands:?}"
        );
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
        assert!(
            commands.iter().any(|command| command == "mv -f $HOME/.local/bin/fyolod.prev $HOME/.local/bin/fyolod"),
            "{commands:?}"
        );
        assert!(commands.last().unwrap().contains("fyolo.prev"), "{commands:?}");
    }

    /// The daemon is what a rollback is judged on. A client that will not move
    /// back is a note, not a failed rollback: the box really is on the build
    /// that worked, and saying otherwise sends an operator after a recovery
    /// that already happened.
    #[tokio::test]
    async fn a_client_that_cannot_be_restored_does_not_fail_the_rollback() {
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""), // stage
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(3),
                ok(""), // roll back: [ -e prev ]
                handed_off(3),
                ok(""), // roll back: the daemon is back
                failed(1, "mv: cannot move: Read-only file system"), // the client is not
            ],
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unhealthy { rolled_back: true, .. }), "{report:?}");
    }

    /// A new daemon that never verifies and cannot hand back is rolled back the
    /// destructive way, and the report says so.
    #[tokio::test]
    async fn a_daemon_that_does_not_come_up_is_rolled_back() {
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                cannot_hand_off(),
                ok(""), // stop
                ok(""), // roll back: [ -e prev ]
                failed(1, "the daemon did not answer hello in time"), // roll back: handoff
                ok(""), // roll back: stop --force
                ok(""), // roll back: mv prev
                ok(""), // roll back: the client
            ],
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unhealthy { rolled_back: true, .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(commands.iter().any(|command| command.contains("stop --force")), "{commands:?}");
        assert!(
            commands.iter().any(|command| command.contains("fyolod.prev")),
            "{commands:?}"
        );
    }

    /// A box another, newer control plane set up is left alone and reported as
    /// such, rather than downgraded.
    #[tokio::test]
    async fn a_newer_box_is_left_alone() {
        let node = FakeNode::new(
            vec![ok(&status_json("0.45.0+1700", Some("0.45.0+1700"), true))],
            vec![hello(Some("0.45.0+1700"))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { newer: true, .. }), "{report:?}");
        assert!(node.puts.borrow().is_empty());
    }

    /// A box whose daemon is already this build but whose client is missing —
    /// deployed before the client shipped, or half of a copy lost — is staged
    /// again, client only: the repair never re-renames the daemon, so
    /// `fyolod.prev` — the box's one rollback point — survives it, and the
    /// multi-MB daemon is not uploaded to fix a file it never lost.
    #[tokio::test]
    async fn a_current_daemon_missing_its_client_is_restaged_client_only() {
        let node = FakeNode::new(
            vec![
                ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new())),
                ok(""), // stage: the client alone
                ok(&status_json(WANT, Some(WANT), true)),
            ],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
        let puts = node.puts.borrow();
        assert_eq!(puts.len(), 1, "{puts:?}");
        assert!(puts[0].ends_with("→ fyolo.new"), "{puts:?}");
        // The daemon plane is untouched: not bounced, not renamed.
        let commands = node.commands.borrow();
        assert!(!commands.iter().any(|command| command.contains(" stop") || command.ends_with("handoff --json")), "{commands:?}");
        assert!(!commands.iter().any(|command| command.contains("fyolod.prev")), "{commands:?}");
    }

    /// A client-only stage that fails verification rolls back the client
    /// alone — handing the daemon to `.prev` would downgrade a plane that
    /// never failed — and a first-time client with no `.prev` is removed
    /// rather than left broken at the head of every session's PATH.
    #[tokio::test]
    async fn a_failed_client_only_stage_rolls_back_only_the_client() {
        let mut node = FakeNode::new(
            vec![
                ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new())),
                ok(""), // stage: the client alone
                ok(&status_json(WANT, Some(WANT), true)),
                ok(""), // roll back: restore or remove the client
            ],
            vec![hello(Some(WANT))],
        );
        node.client_version = Some(failed(126, "cannot execute binary file"));
        let report = reconcile(&node, WANT, Options::default()).await;
        match &report.outcome {
            Outcome::Current { client: Some(_), .. } => {}
            other => panic!("expected current with a client note, got {other:?}"),
        }
        let commands = node.commands.borrow();
        // The box had no client, so this run renamed nothing aside: the undo is
        // the removal, and the `.prev` an older deploy left is not this run's to
        // put back — installing it would be a build from before this one.
        assert_eq!(commands.last().unwrap(), "rm -f $HOME/.local/bin/fyolo", "{commands:?}");
        // The daemon plane is untouched. A client-only pass may not reach the
        // daemon's rollback: `fyolod.prev` is the box's one way back to the
        // build before this one, and moving it would downgrade a plane that
        // never failed and never staged.
        assert!(!commands.iter().any(|command| command.contains("fyolod.prev") || command.contains(" stop")), "{commands:?}");
    }

    /// A client-only pass whose *daemon* stops answering leaves the daemon
    /// alone: this run staged no daemon, so it has none to undo, and moving
    /// `fyolod.prev` over the binary would downgrade the box over a client.
    #[tokio::test]
    async fn a_client_only_pass_never_arms_the_daemon_rollback() {
        let node = FakeNode::new(
            vec![
                ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new())),
                ok(""), // stage: the client alone
                ok(&status_json(WANT, Some(WANT), true)),
            ],
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(
            matches!(report.outcome, Outcome::Unhealthy { rolled_back: false, .. }),
            "{report:?}"
        );
        let commands = node.commands.borrow();
        assert!(!commands.iter().any(|command| command.contains("fyolod.prev")), "{commands:?}");
        assert!(!commands.iter().any(|command| command.contains("handoff --binary")), "{commands:?}");
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
    }

    /// A daemon rollback restores only what the run staged. Where the build
    /// shipped no client, the box's own — installed by something else, and
    /// working — must survive: the restore command's other half is `rm -f`.
    #[tokio::test]
    async fn a_daemon_rollback_leaves_a_client_this_run_never_staged() {
        let mut node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""), // stage: the daemon alone
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(1),
                ok(""),        // roll back: [ -e prev ]
                handed_off(1), // roll back: handoff --binary prev
                ok(""),        // roll back: the daemon
            ],
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        );
        node.client_artifact = None;
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unhealthy { rolled_back: true, .. }), "{report:?}");
        let commands = node.commands.borrow();
        // The client's own restore — whose other half deletes — never runs.
        // Matched whole, because `fyolod`'s commands contain `fyolo`'s as a
        // prefix and a substring test would pass on the daemon's own removal.
        // This run installed the client fresh (the box had none), so its
        // undo is the removal half, not a `.prev` it never wrote.
        let client_restore = restore_command("$HOME/.local/bin/fyolo", false);
        assert!(!commands.iter().any(|command| command == &client_restore), "{commands:?}");
    }

    /// This run staged the box, so the client is verified even when a newer
    /// daemon answers — two planes racing must not turn an unverified client
    /// into `Current { newer: true }`.
    #[tokio::test]
    async fn a_staged_box_verifies_its_client_even_under_a_newer_daemon() {
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""), // stage
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(1),
            ],
            vec![hello(Some("0.45.0+1700"))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { newer: true, .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(
            commands.iter().any(|command| command.ends_with("fyolo --version")),
            "{commands:?}"
        );
    }

    /// The activation command undoes itself: a client half that fails after
    /// the daemon's rename must put the daemon back in the same command, so a
    /// failed stage never leaves a new daemon beside an old client with
    /// `.prev` already spent.
    #[tokio::test]
    async fn a_failed_stage_restores_the_daemon_in_the_same_command() {
        let node = FakeNode::new(
            vec![
                failed(127, "bash: fyolod: No such file or directory"),
                failed(1, "mv: cannot overwrite directory"), // stage activation
            ],
            vec![],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Failed { .. }), "{report:?}");
        let activation = node.commands.borrow().last().unwrap().clone();
        // The client's failure branch puts the daemon back — by copy and rename,
        // so the box still has a `.prev` to roll back to afterwards. Moving it
        // back restored the right daemon and spent the only way back from it.
        assert!(
            activation.contains(
                "cp -f $HOME/.local/bin/fyolod.prev $HOME/.local/bin/fyolod.undo \
                 && mv -f $HOME/.local/bin/fyolod.undo $HOME/.local/bin/fyolod"
            ),
            "{activation}"
        );
        assert!(
            !activation.contains("mv -f $HOME/.local/bin/fyolod.prev $HOME/.local/bin/fyolod"),
            "{activation}"
        );
    }

    /// A client that does not answer `--version` is reported on an otherwise
    /// healthy machine and put back, and costs the box nothing else. The daemon
    /// verified as the build wanted, so it is not handed back, not stopped, and
    /// not downgraded: the previous shape drove the daemon's own rollback from
    /// this failure, whose fallback is `stop --force`, and spent every live
    /// session on the box over one artifact the daemon does not depend on.
    ///
    /// It rides `Current` because the machine is usable and every reader needs
    /// to be told which machine it is — a report that could not say would have
    /// the app refuse to register a box whose daemon is perfectly healthy — and
    /// it is still a non-zero exit for whoever ran the deploy.
    #[tokio::test]
    async fn a_client_that_cannot_answer_version_never_touches_the_daemon() {
        let mut node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                staged_over_a_client(), // stage
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(2),
                ok(""),                                    // put the client back
            ],
            vec![hello(Some(WANT))],
        );
        node.client_version = Some(failed(126, "cannot execute binary file"));
        let report = reconcile(&node, WANT, Options::default()).await;
        match &report.outcome {
            Outcome::Current {
                client: Some(trouble),
                host_id,
                ..
            } => {
                assert!(trouble.contains("--version"), "{trouble}");
                assert!(trouble.contains("taken back off the box"), "{trouble}");
                assert_eq!(host_id, "h_1");
            }
            other => panic!("expected current with a client note, got {other:?}"),
        }
        // Still a failed deploy for whoever ran one.
        assert_eq!(report.exit_code(), 1);
        let commands = node.commands.borrow();
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
        assert!(
            !commands.iter().any(|command| command.contains("handoff --binary")),
            "{commands:?}"
        );
        // The daemon's own restore is a command of its own; `fyolod.prev`
        // inside the stage's activation is the swap keeping a rollback point,
        // which is not a rollback.
        assert!(
            !commands.iter().any(|command| command == "mv -f $HOME/.local/bin/fyolod.prev $HOME/.local/bin/fyolod"),
            "{commands:?}"
        );
        // Taken off the box rather than swapped for the older one it replaced:
        // the daemon here is staying on the new build, and an older client beside
        // it is the skew §1.2 exists to rule out. A missing client is a state the
        // next pass closes; a mismatched one is not.
        assert!(
            commands.iter().any(|command| command == "rm -f $HOME/.local/bin/fyolo"),
            "{commands:?}"
        );
        // And it happened before the daemon was asked anything, which is the
        // point of settling the client plane first: every way out of the loop
        // after that carries what was learned about it.
        let removed = commands
            .iter()
            .position(|command| command == "rm -f $HOME/.local/bin/fyolo");
        let handed = commands.iter().position(|command| command.ends_with("handoff --json"));
        assert!(removed < handed, "{commands:?}");
    }

    /// The undo follows what the activation reported, not what the box's status
    /// implied. A daemon built before this pass reports no `client` field at all,
    /// so deriving replaced-ness from the status concluded there had never been a
    /// client — and a rollback then *removed* one instead of putting back the
    /// `fyolo.prev` the same stage had just written. Every box already in the
    /// field passes through that on its first upgrade.
    ///
    /// The rollback that asks is the daemon's: when the daemon goes back to its
    /// previous build the client goes with it, so the pair stays one build. (A
    /// client that fails on its own is taken off instead, because the daemon is
    /// staying new — see above.)
    #[tokio::test]
    async fn a_client_is_put_back_even_when_the_old_daemon_never_reported_one() {
        // An older build's status: no `client` key, which `serde(default)`
        // reads as `None` however many clients are actually on the box.
        let older_status = serde_json::json!({
            "binary": { "version": "0.43.0+1500", "path": "/home/u/.local/bin/fyolod" },
            "daemon": { "running": true, "version": "0.43.0+1500", "pid": 4242,
                        "socket": "/run/user/1001/fyolod/fyolod.sock" },
            "sessions": [],
            "host_id": "h_1",
            "supervisor": "none"
        })
        .to_string();
        let node = FakeNode::new(
            vec![
                ok(&older_status),
                // The activation says what it found: a client was renamed aside.
                staged_over_a_client(),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                handed_off(1),
                ok(""),        // roll back: [ -e prev ]
                handed_off(1), // roll back: handoff --binary prev
                ok(""),        // roll back: the daemon
                ok(""),        // roll back: the client, with it
            ],
            // The daemon never comes up, so the rollback is the daemon's and the
            // client rides along with it.
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unhealthy { rolled_back: true, .. }), "{report:?}");
        assert_eq!(
            node.commands.borrow().last().unwrap(),
            "mv -f $HOME/.local/bin/fyolo.prev $HOME/.local/bin/fyolo"
        );
    }

    /// The activation never deletes a `.prev` it did not write. Clearing one to
    /// make the file itself mean "this run" threw away a working previous daemon
    /// whenever the binary happened to be missing at stage time, leaving a box
    /// that then failed verification with nothing to hand back to. What this run
    /// renamed aside is recorded in a shell variable instead.
    #[tokio::test]
    async fn a_stage_never_deletes_a_previous_build_it_did_not_write() {
        let node = FakeNode::new(
            vec![
                failed(127, "bash: /home/u/.local/bin/fyolod: No such file or directory"),
                ok(""),
                ok(&status_json(WANT, None, false)),
            ],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
        let activation = node.commands.borrow()[1].clone();
        assert!(!activation.contains("rm -f $HOME/.local/bin/fyolod.prev"), "{activation}");
        assert!(!activation.contains("rm -f $HOME/.local/bin/fyolo.prev"), "{activation}");
        // It records what it renamed aside, which is what the undo reads.
        assert!(activation.contains("fyolod_replaced=1"), "{activation}");
        assert!(activation.contains("fyolo_replaced=1"), "{activation}");
    }

    /// ssh failing during the client probe is not the client answering. Taken as
    /// a verdict it deleted the very client the same pass had just correctly
    /// installed, so an unreachable machine leaves the install alone and says it
    /// could not tell — the next pass asks again.
    ///
    /// Slow on purpose: it waits out the same `SETTLE` budget the daemon probe
    /// retries within, which is what a network blip needs to pass.
    #[tokio::test]
    async fn an_unreachable_box_does_not_cost_the_client_it_just_installed() {
        let mut node = FakeNode::new(
            vec![
                ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new())),
                staged_over_a_client(),
                ok(&status_json(WANT, Some(WANT), true)),
                // Every `fyolo --version` attempt after this finds no scripted
                // answer, which the fake reports as a transport error.
            ],
            vec![hello(Some(WANT))],
        );
        // Nothing answers the probe, so it falls through to the queue — which is
        // empty, and the fake reports that as a transport failure.
        node.client_version = None;
        let report = reconcile(&node, WANT, Options::default()).await;
        match &report.outcome {
            Outcome::Current { client: Some(note), client_failed, .. } => {
                assert!(note.contains("could not reach"), "{note}");
                // Said, but not counted against the deploy: everything installed
                // correctly and the daemon verified, and ssh being flaky for the
                // seconds of one probe is not the client's fault.
                assert!(!client_failed, "{note}");
            }
            other => panic!("expected current with an unknown-client note, got {other:?}"),
        }
        assert_eq!(report.exit_code(), 0);
        // The client it installed is still there: nothing restored, nothing removed.
        let commands = node.commands.borrow();
        let client_restore = restore_command("$HOME/.local/bin/fyolo", false);
        let client_revert = restore_command("$HOME/.local/bin/fyolo", true);
        assert!(
            !commands.iter().any(|command| command == &client_restore || command == &client_revert),
            "{commands:?}"
        );
    }

    /// A client-only pass whose upload or activation fails leaves the machine
    /// attachable. Its daemon is the build wanted and every session on it is
    /// running; failing the reconcile turned reaching a healthy box into
    /// "Couldn't set up fyolod on …" over the CLI inside its sessions.
    #[tokio::test]
    async fn a_client_repair_that_will_not_install_still_leaves_the_box_usable() {
        let node = FakeNode::new(
            vec![
                ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new())),
                failed(1, "mv: cannot move: Read-only file system"), // activation
            ],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
    }

    /// The wait grows each time and stops growing at the cap, and a due wait is
    /// no wait at all. Nothing is remembered forever: a repair that failed for
    /// any reason — a short upload, a host that dropped, a control plane without
    /// the slice — is always tried again, which is why none of those has to be
    /// told apart from a machine that truly cannot take the client.
    #[test]
    fn a_failed_repair_waits_longer_each_time_and_never_stops_being_retried() {
        let note = std::path::PathBuf::from(format!(
            "/tmp/fyolod-repair-{}-backoff",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&note);

        // Nothing remembered is nothing to wait for.
        assert_eq!(client_repair_waiting(Some(&note), WANT), None);

        let first = delay_client_repair(Some(&note), WANT);
        assert_eq!(first, CLIENT_REPAIR_WAIT);
        let second = delay_client_repair(Some(&note), WANT);
        assert!(second > first, "{second:?} should outgrow {first:?}");

        // It is a wait, and a short one: the box is tried again.
        let waiting = client_repair_waiting(Some(&note), WANT).expect("a wait");
        assert!(waiting <= second);

        // Growing stops somewhere, so it never becomes a refusal in disguise.
        let mut wait = second;
        for _ in 0..32 {
            wait = delay_client_repair(Some(&note), WANT);
        }
        assert_eq!(wait, CLIENT_REPAIR_WAIT_CAP);

        // Another build's client is other bytes, and gets its own first chance.
        assert_eq!(client_repair_waiting(Some(&note), "0.45.0+1700"), None);
        // And a client that installs forgets the whole thing.
        clear_client_repair(Some(&note));
        assert_eq!(client_repair_waiting(Some(&note), WANT), None);
    }

    /// A daemon too busy to be replaced does not excuse the client from being
    /// answered for. The pass installed one, the running daemon's own symlink
    /// already leads every session's PATH to it, and the rung that reports the
    /// box staged used to return without ever running it — so a truncated or
    /// wrong-architecture `fyolo` sat there unreported until something else
    /// happened to look.
    #[tokio::test]
    async fn a_box_left_staged_still_answers_for_its_client() {
        let busy = StopOutcome {
            stopped: false,
            busy: vec![SessionSummary {
                id: "1".into(),
                name: "claude".into(),
                command: "claude".into(),
                title: None,
                status: "working".into(),
                attached: 0,
                running: true,
                alive: true,
            }],
            message: "1 session is in use".into(),
        };
        let mut node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                staged_over_a_client(),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                ok(""), // take the client that did not verify back off
                cannot_hand_off(),
                Run {
                    code: EXIT_BUSY,
                    stdout: serde_json::to_string(&busy).unwrap(),
                    stderr: String::new(),
                },
            ],
            vec![],
        );
        node.client_version = Some(failed(126, "cannot execute binary file"));
        let report = reconcile(&node, WANT, Options::default()).await;
        match &report.outcome {
            Outcome::Staged { busy, client: Some(note), .. } => {
                assert_eq!(busy.len(), 1);
                assert!(note.contains("--version"), "{note}");
            }
            other => panic!("expected staged naming the client trouble, got {other:?}"),
        }
        // And the CLI's own line says it, not only the JSON.
        assert!(report.describe().contains("--version"), "{}", report.describe());
    }

    /// Stopping at the stage still runs the client it just installed. That is
    /// about not touching the *daemon*, and running a client touches none — so a
    /// box was otherwise left holding a client nothing had ever executed, with
    /// the report saying nothing about it.
    #[tokio::test]
    async fn stopping_at_the_stage_still_answers_for_the_client_it_installed() {
        let mut node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                staged_over_a_client(),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                ok(""),                                    // take it back off
            ],
            vec![],
        );
        node.client_version = Some(failed(126, "cannot execute binary file"));
        let options = Options { stage_only: true, ..Options::default() };
        let report = reconcile(&node, WANT, options).await;
        match &report.outcome {
            Outcome::Staged { client: Some(note), .. } => {
                assert!(note.contains("--version"), "{note}");
            }
            other => panic!("expected staged naming the client trouble, got {other:?}"),
        }
        let commands = node.commands.borrow();
        assert_eq!(commands.last().unwrap(), "rm -f $HOME/.local/bin/fyolo", "{commands:?}");
        // The daemon is what `--stage-only` promises not to touch.
        assert!(!commands.iter().any(|command| command.contains(" stop")), "{commands:?}");
        assert!(
            !commands.iter().any(|command| command.ends_with("handoff --json")),
            "{commands:?}"
        );
    }

    /// A host that drops mid-repair is reported as what it is. Folded into the
    /// soft arm it came back as `Unhealthy` — after a full settle budget spent
    /// waiting on a daemon nothing could reach — and nothing about the client is
    /// learned either way, so no wait is recorded against it.
    #[tokio::test]
    async fn a_host_that_drops_mid_repair_is_reported_unreachable() {
        let note = std::path::PathBuf::from(format!(
            "/tmp/fyolod-repair-{}-dropped",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&note);
        let mut node = FakeNode::new(
            vec![ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new()))],
            vec![hello(Some(WANT))],
        );
        node.repair_note = Some(note.clone());
        node.unreachable_put = true;
        let report = reconcile(&node, WANT, Options::default()).await;

        assert!(matches!(report.outcome, Outcome::Unreachable { .. }), "{report:?}");
        // And nothing is held against the client: the repair never got far enough
        // to learn anything about it, so the next pass starts fresh.
        assert_eq!(client_repair_waiting(Some(&note), WANT), None);
        let _ = std::fs::remove_file(&note);
    }

    /// And it is put off, so the next attach does not spend another upload
    /// learning the same thing. A machine that can never take this build's
    /// client was otherwise restaged on every single attach, for good.
    #[tokio::test]
    async fn a_failed_client_repair_is_not_attempted_again_right_away() {
        let note = std::path::PathBuf::from(format!(
            "/tmp/fyolod-repair-{}-{}",
            std::process::id(),
            "refused"
        ));
        let _ = std::fs::remove_file(&note);
        let mut node = FakeNode::new(
            vec![
                ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new())),
                failed(1, "mv: cannot move: Read-only file system"),
            ],
            vec![hello(Some(WANT))],
        );
        node.repair_note = Some(note.clone());
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");

        // The next pass: the same box, the same build, and nothing sent — but
        // the box is carrying a client that is not this build, and a note that
        // stops a doomed repair may not also stop it saying so. Silence here
        // would report the very skew §1.2 exists to prevent as a clean bill of
        // health, on every pass, for good.
        let mut again = FakeNode::new(
            vec![ok(&status_json_with_client(WANT, Some("0.43.0+1500"), Some(WANT), true, Vec::new()))],
            vec![hello(Some(WANT))],
        );
        again.repair_note = Some(note.clone());
        let report = reconcile(&again, WANT, Options::default()).await;
        match &report.outcome {
            Outcome::Current { client: Some(note), .. } => {
                assert!(note.contains("0.43.0+1500"), "{note}");
                assert!(note.contains(WANT), "{note}");
            }
            other => panic!("expected current naming the skew, got {other:?}"),
        }
        assert_eq!(report.exit_code(), 1, "a skewed box is a failed deploy");
        assert!(again.puts.borrow().is_empty(), "{:?}", again.puts.borrow());

        // A later build is a fresh chance: the wait was about the bytes that
        // failed, and these are different ones.
        let mut newer = FakeNode::new(
            vec![
                ok(&status_json_with_client("0.45.0+1700", None, Some("0.45.0+1700"), true, Vec::new())),
                staged_over_a_client(),
                ok(&status_json("0.45.0+1700", Some("0.45.0+1700"), true)),
            ],
            vec![hello(Some("0.45.0+1700"))],
        );
        newer.client_version = Some(ok("fyolo 0.45.0+1700 (release)"));
        newer.repair_note = Some(note.clone());
        let report = reconcile(&newer, "0.45.0+1700", Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { client: None, .. }), "{report:?}");
        assert_eq!(newer.puts.borrow().len(), 1);

        let _ = std::fs::remove_file(&note);
    }

    /// A client-only pass on a control plane that cannot produce a client leaves
    /// the client alone instead of failing the reconcile. This runs before every
    /// attach, and a checkout with no cross-toolchain would otherwise turn
    /// reaching a healthy machine into an error.
    #[tokio::test]
    async fn a_client_only_pass_that_cannot_build_one_leaves_the_client_alone() {
        struct NoClientBuild;
        impl Node for NoClientBuild {
            fn label(&self) -> String {
                "box".into()
            }
            fn binary(&self) -> String {
                "$HOME/.local/bin/fyolod".into()
            }
            async fn run(&self, command: &str) -> Result<Run> {
                assert!(command.ends_with("status --json"), "unexpected command: {command}");
                Ok(ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new())))
            }
            async fn put(&self, _: &Path, _: &str) -> Result<()> {
                unreachable!("nothing to send")
            }
            async fn artifact(&self, client_only: bool) -> Result<Artifacts> {
                assert!(client_only, "the daemon is current; only the client is missing");
                bail!("no bundled client to repair box with")
            }
            fn client_binary(&self) -> Option<String> {
                Some("$HOME/.local/bin/fyolo".into())
            }
            async fn hello(&self) -> Result<DaemonHello> {
                hello(Some(WANT))
            }
        }
        let report = reconcile(&NoClientBuild, WANT, Options::default()).await;
        // Usable, and honest about it: the machine is reachable and its daemon
        // is the build wanted, while the client it is missing is still named.
        match &report.outcome {
            Outcome::Current { client: Some(note), .. } => {
                assert!(note.contains("no bundled client"), "{note}")
            }
            other => panic!("expected current with a client note, got {other:?}"),
        }
    }

    /// A Mac reachable over ssh is current with no client of the deploy's: it
    /// links its own from its app bundle. Nothing is staged, and — the point —
    /// nothing is *asked*: planning a client pass for it meant a `uname` round
    /// trip on every deploy and every attach, to ship nothing and say so
    /// wrongly.
    #[tokio::test]
    async fn a_mac_box_is_current_without_a_client_and_without_asking() {
        let node = FakeNode::new(
            vec![ok(&status_json_from_a_mac(WANT, Some(WANT)))],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { client: None, .. }), "{report:?}");
        assert!(node.puts.borrow().is_empty(), "{:?}", node.puts.borrow());
        // One command: the status read. No artifact resolution, no client probe.
        let commands = node.commands.borrow();
        assert_eq!(commands.len(), 1, "{commands:?}");
        assert!(commands[0].ends_with("status --json"), "{commands:?}");
    }

    /// A client already on the box answered for itself in the `status` this pass
    /// read — that reading executes it — so nothing re-asks it over ssh before
    /// every attach.
    #[tokio::test]
    async fn a_client_already_in_place_is_not_probed_again() {
        let node = FakeNode::new(
            vec![ok(&status_json(WANT, Some(WANT), true))],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { client: None, .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(
            !commands.iter().any(|command| command.ends_with("fyolo --version")),
            "{commands:?}"
        );
    }

    /// A build with no client in it deploys the daemon alone: nothing is put
    /// there for the client, and nothing is verified against one. A control
    /// plane run out of a checkout (`cargo build --bin fyolod`) is this, and
    /// failing it would turn a Mac→Mac deploy that worked into one that cannot
    /// be done.
    #[tokio::test]
    async fn a_build_carrying_no_client_deploys_the_daemon_alone() {
        let mut node = FakeNode::new(
            vec![
                ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new())),
                ok(&status_json_with_client(WANT, None, Some(WANT), true, Vec::new())),
            ],
            vec![hello(Some(WANT))],
        );
        node.client_artifact = None;
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
        assert!(node.puts.borrow().is_empty(), "{:?}", node.puts.borrow());
        let commands = node.commands.borrow();
        assert!(
            !commands.iter().any(|command| command.contains("fyolo --version")),
            "{commands:?}"
        );
    }

    /// The keys the app decodes (`Fyolod.LifecycleReport`, camel-cased from
    /// these by `convertFromSnakeCase`). A client that failed rides `current`
    /// with the host named, because the app registers a machine from that state
    /// and only that state — reporting it as a failure left the app telling the
    /// user a healthy daemon had not answered, and refusing the box.
    #[test]
    fn a_client_failure_reports_as_a_usable_machine() {
        let report = Report {
            node: "box".to_string(),
            desired: WANT.to_string(),
            outcome: Outcome::Current {
                version: WANT.to_string(),
                host_id: "h_1".to_string(),
                proto: Some(1),
                newer: false,
                client: Some("the client at ~/.local/bin/fyolo does not answer --version".into()),
                client_failed: true,
            },
        };
        let json: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&report).unwrap()).unwrap();
        assert_eq!(json["state"], "current");
        assert_eq!(json["host_id"], "h_1");
        assert_eq!(json["version"], WANT);
        assert!(json["client"].as_str().unwrap().contains("--version"));
        // The app reads this to tell a client at fault from one it could not
        // check, and says a different sentence for each.
        assert_eq!(json["client_failed"], true);

        // And a healthy one carries no such key at all, so nothing downstream
        // has to tell "absent" from "empty".
        let healthy = Report {
            node: "box".to_string(),
            desired: WANT.to_string(),
            outcome: Outcome::Current {
                version: WANT.to_string(),
                host_id: "h_1".to_string(),
                proto: Some(1),
                newer: false,
                client: None,
                client_failed: false,
            },
        };
        let json: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&healthy).unwrap()).unwrap();
        assert!(json.get("client").is_none(), "{json}");
        assert!(json.get("client_failed").is_none(), "{json}");
    }

    /// ssh failing is `unreachable`, kept apart from a step that ran and failed.
    #[tokio::test]
    async fn a_transport_failure_is_unreachable() {
        struct Down;
        impl Node for Down {
            fn label(&self) -> String {
                "vps".into()
            }
            fn binary(&self) -> String {
                "fyolod".into()
            }
            async fn run(&self, _: &str) -> Result<Run> {
                Err(Unreachable("ssh: connect to host vps port 22: Operation timed out".into()).into())
            }
            async fn put(&self, _: &Path, _: &str) -> Result<()> {
                unreachable!()
            }
            async fn artifact(&self, _client_only: bool) -> Result<Artifacts> {
                unreachable!()
            }
            fn client_binary(&self) -> Option<String> {
                None
            }
            async fn hello(&self) -> Result<DaemonHello> {
                unreachable!()
            }
        }
        let report = reconcile(&Down, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unreachable { ref message } if message.contains("timed out")), "{report:?}");
    }
}
