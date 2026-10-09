//! Which channel the `fyolo` client drives, resolved from its own name.
//!
//! The shell client carried three build-time rewritten variables
//! (`SUPPORT_DIR_NAME`, `BUNDLE_ID`, `VERSION`); this derives the same
//! bindings from argv[0] instead: the dev bundle installs the binary as
//! `fyolo-dev`, which selects the `.dev` bundle id, the `fyolo-dev`
//! support directory, and the dev daemon socket. One binary, no sed.
//!
//! An inherited `FYOLO_CHANNEL` is deliberately not consulted: the shell
//! client pinned `FYOLO_CHANNEL="$CHANNEL"` on every daemon exec so a stale
//! value could not cross channels, and this keeps that rule. The one runtime
//! override is `FYOLOD_SOCK`, which pins the daemon socket outright
//! (`paths::socket_path` honors it first) — that is how a hook firing inside
//! a channel-pinned session reaches the daemon that owns it. `fyolo
//! version` prints which of the two answered, so a surprising socket names
//! its own cause.

/// The bindings the shell client's three rewritten variables carried.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Channel {
    /// `release`, `dev`, or a custom probe channel name.
    pub name: String,
    /// The Mac app this client drives (`open -b`, `lsappinfo`).
    pub bundle_id: String,
    /// Directory name under `~/Library/Application Support` holding the
    /// app's control socket, support copies, and device registry.
    pub support_dir_name: String,
}

/// Which rung decided where the daemon socket is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provenance {
    /// `FYOLOD_SOCK` names the socket directly.
    ExplicitSocket,
    /// Derived from the binary's own name (`fyolo` / `fyolo-<channel>`).
    ProgramName,
}

impl Channel {
    fn release() -> Channel {
        Channel {
            name: "release".to_string(),
            bundle_id: "sh.fyolo.app".to_string(),
            support_dir_name: "fyolo".to_string(),
        }
    }

    /// Same validation rule as `paths::channel_suffix`: a channel name is a
    /// path component, so anything that isn't lowercase alphanumeric-or-dash
    /// falls back to the release channel instead of opening a stray
    /// directory.
    fn named(candidate: &str) -> Channel {
        let name = candidate.trim().to_lowercase();
        if name.is_empty() || name == "release" {
            return Channel::release();
        }
        if !name
            .chars()
            .all(|character| character.is_alphanumeric() || character == '-')
        {
            return Channel::release();
        }
        Channel {
            bundle_id: format!("sh.fyolo.app.{name}"),
            support_dir_name: format!("fyolo-{name}"),
            name,
        }
    }

    /// `fyolo` → release; `fyolo-dev` → dev; `fyolo-<name>` → `<name>`;
    /// anything else → release. Takes the bare program name, not a path.
    pub fn from_program_name(program: &str) -> Channel {
        match program.strip_prefix("fyolo-") {
            Some(rest) => Channel::named(rest),
            None => Channel::release(),
        }
    }

    /// The deep-link scheme this channel's app claims (`fyolo` /
    /// `fyolo-dev`), mirroring `AppChannel.urlScheme`.
    pub fn url_scheme(&self) -> String {
        if self.name == "release" {
            "fyolo".to_string()
        } else {
            format!("fyolo-{}", self.name)
        }
    }
}

fn program_name() -> String {
    std::env::args()
        .next()
        .as_deref()
        .map(std::path::Path::new)
        .and_then(|path| path.file_name())
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "fyolo".to_string())
}

fn explicit_socket() -> bool {
    std::env::var_os("FYOLOD_SOCK").is_some_and(|value| !value.is_empty())
}

/// Resolve the channel and pin it for everything downstream: sets
/// `FYOLO_CHANNEL` in this process's environment so `paths::*` and every
/// exec'd daemon derive the same socket, overwriting any inherited value —
/// the same pin the shell client applied on every daemon exec.
pub fn resolve() -> (Channel, Provenance) {
    let channel = Channel::from_program_name(&program_name());
    std::env::set_var("FYOLO_CHANNEL", &channel.name);
    let provenance = if explicit_socket() {
        Provenance::ExplicitSocket
    } else {
        Provenance::ProgramName
    };
    (channel, provenance)
}

/// The shell client's `locate_fyolod()`, same rungs in the same order: the
/// explicit `FYOLOD_BIN` override; the daemon beside this binary, but only
/// when this binary itself runs out of a bundle's `Contents/Resources` (a
/// checkout's `target/debug/fyolo` must not quietly prefer its sibling over
/// the live app); the running app's bundle via `lsappinfo`, which only
/// answers for a live process so it can never name a stale bundle; then the
/// standalone install locations. Every rung requires an executable file,
/// like the shell's `-x` and `command -v`.
pub fn daemon_binary(channel: &Channel) -> Option<std::path::PathBuf> {
    use std::path::{Path, PathBuf};
    if let Some(explicit) = std::env::var_os("FYOLOD_BIN") {
        let path = PathBuf::from(explicit);
        if executable(&path) {
            return Some(path);
        }
    }
    if let Some(resolved) = std::env::current_exe()
        .ok()
        .and_then(|own| own.canonicalize().ok())
    {
        if let Some(parent) = resolved.parent() {
            if parent.ends_with("Contents/Resources") {
                let candidate = parent.join("fyolod");
                if executable(&candidate) {
                    return Some(candidate);
                }
            }
        }
    }
    if cfg!(target_os = "macos") {
        if let Ok(info) = std::process::Command::new("lsappinfo")
            .args(["info", "-only", "bundlepath", &channel.bundle_id])
            .output()
        {
            let stdout = String::from_utf8_lossy(&info.stdout);
            if let Some(bundle) = stdout
                .lines()
                .find_map(|line| line.strip_prefix("\"LSBundlePath\"=\""))
                .and_then(|rest| rest.strip_suffix('"'))
            {
                let candidate = Path::new(bundle).join("Contents/Resources/fyolod");
                if executable(&candidate) {
                    return Some(candidate);
                }
            }
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let candidate = Path::new(&home).join(".local/bin/fyolod");
        if executable(&candidate) {
            return Some(candidate);
        }
    }
    let path_variable = std::env::var_os("PATH")?;
    std::env::split_paths(&path_variable)
        .map(|directory| directory.join("fyolod"))
        .find(|candidate| executable(candidate))
}

fn executable(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.is_file()
        && std::fs::metadata(path)
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plain_name_is_the_release_channel() {
        let channel = Channel::from_program_name("fyolo");
        assert_eq!(channel.name, "release");
        assert_eq!(channel.bundle_id, "sh.fyolo.app");
        assert_eq!(channel.support_dir_name, "fyolo");
    }

    #[test]
    fn a_dev_suffix_selects_the_dev_bundle_and_support_dir() {
        let channel = Channel::from_program_name("fyolo-dev");
        assert_eq!(channel.name, "dev");
        assert_eq!(channel.bundle_id, "sh.fyolo.app.dev");
        assert_eq!(channel.support_dir_name, "fyolo-dev");
    }

    #[test]
    fn a_custom_suffix_is_its_own_probe_channel() {
        let channel = Channel::from_program_name("fyolo-smoke2");
        assert_eq!(channel.name, "smoke2");
        assert_eq!(channel.support_dir_name, "fyolo-smoke2");
    }

    #[test]
    fn an_explicit_release_suffix_collapses_to_release() {
        assert_eq!(Channel::from_program_name("fyolo-release"), Channel::release());
    }

    #[test]
    fn an_invalid_suffix_falls_back_to_release_like_paths_does() {
        assert_eq!(Channel::from_program_name("fyolo-../evil"), Channel::release());
        assert_eq!(Channel::from_program_name("fyolo-a_b"), Channel::release());
    }

    #[test]
    fn an_unrelated_program_name_is_release() {
        assert_eq!(Channel::from_program_name("fyolofoo"), Channel::release());
        assert_eq!(Channel::from_program_name("cargo"), Channel::release());
    }
}
