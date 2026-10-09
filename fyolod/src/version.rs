//! `fyolo version` — every version in one table: this client, the running
//! app, the local fyolod, and one row per known remote from the device
//! registry the app writes at each handshake (`devices.json`). A remote row
//! is what the last connect observed, stamped so a stale row announces its
//! staleness instead of posing as live state; a host this Mac has never
//! spoken to is absent, and nothing here touches the network.
//!
//! Ported from the shell client's `version_table()`, with two deliberate
//! deviations: the located daemon's `status --json` is parsed into the typed
//! `lifecycle::NodeStatus` instead of awk over its pretty printing, and a
//! final line names the resolved socket and which rung chose it
//! (`FYOLOD_SOCK` or the program name), so a surprising socket names its
//! own cause. Like the shell client, the daemon rows come from the *located
//! daemon binary*, not this process — a staged daemon/client skew must show
//! in this table, and asking ourselves would hide it.

use crate::channel::{self, Channel, Provenance};
use crate::{lifecycle, paths};
use anyhow::Result;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn row(name: &str, version: &str, proto: &str, note: &str) {
    let line = format!("{name:<14} {version:<22} {proto:<9} {note}");
    println!("{}", line.trim_end());
}

pub async fn print_table(channel: &Channel, provenance: Provenance) -> Result<()> {
    row(
        "fyolo",
        lifecycle::BUILD_VERSION,
        "",
        &format!("(client, {} channel)", channel.name),
    );

    match running_app_version(&channel.bundle_id) {
        Some(version) => row("fyolo.app", &version, "", "(running)"),
        None => row("fyolo.app", "-", "", "(not running)"),
    }

    // What the printed command must carry to land on the same daemon this
    // table just described: the socket when one was named, else the channel —
    // spelled out even for release, so the shell it is pasted into cannot
    // redirect it with whatever those variables happen to hold there.
    let env_pin = match provenance {
        Provenance::ExplicitSocket => paths::socket_path()
            .map(|socket| {
                format!(
                    "FYOLOD_SOCK={}",
                    lifecycle::shell_quote(&socket.display().to_string())
                )
            })
            .unwrap_or_default(),
        Provenance::ProgramName => format!("FYOLO_CHANNEL={}", channel.name),
    };

    match channel::daemon_binary(channel) {
        None => row("fyolod local", "-", "", "(not installed)"),
        Some(daemon) => match daemon_status(&daemon) {
            Some(status) if status.daemon.running => {
                // A stale local daemon is the one skew with no command in this
                // table's margins — a remote is reconciled before each terminal
                // opens, and the machine the app runs on is the one nobody
                // asks — so the row itself names the way out.
                let behind = behind_note(
                    status.daemon.version.as_deref(),
                    &status.binary.version,
                    &daemon,
                    &env_pin,
                );
                let version = status.daemon.version.unwrap_or(status.binary.version);
                let proto = status
                    .daemon
                    .proto
                    .map(|proto| format!("proto {proto}"))
                    .unwrap_or_default();
                row("fyolod local", &version, &proto, &behind);
            }
            Some(status) if !status.binary.version.is_empty() => row(
                "fyolod local",
                &status.binary.version,
                "",
                "(binary; daemon not running)",
            ),
            _ => row(
                "fyolod local",
                "-",
                "",
                &format!("(no answer from {})", daemon.display()),
            ),
        },
    }

    for remote in remote_rows(&channel.support_dir_name) {
        row(&remote.alias, &remote.version, &remote.proto, &remote.stamp);
    }

    if let Ok(socket) = paths::socket_path() {
        let why = match provenance {
            Provenance::ExplicitSocket => "via FYOLOD_SOCK",
            Provenance::ProgramName => "via program name",
        };
        println!();
        println!("socket {} ({why})", socket.display());
    }
    Ok(())
}

/// "← behind; run `<daemon> handoff`" when the running daemon is older than
/// the binary staged at its path, and quiet in every other case — including
/// the versionless answer of a daemon too old to say, which `handoff` would
/// refuse anyway. The command names the resolved binary, not a bare
/// `fyolod`: the app puts `fyolo` on PATH and keeps the daemon inside the
/// bundle, so the bare name is "command not found" on a normal install — or,
/// worse, some other build that happens to be on PATH.
fn behind_note(
    running: Option<&str>,
    staged: &str,
    daemon: &std::path::Path,
    env_pin: &str,
) -> String {
    let (Some(running), Some(staged)) = (
        running.and_then(lifecycle::Version::parse),
        lifecycle::Version::parse(staged),
    ) else {
        return String::new();
    };
    if running < staged {
        let space = if env_pin.is_empty() { "" } else { " " };
        format!(
            "← behind; run `{env_pin}{space}{} handoff`",
            lifecycle::shell_quote(&daemon.display().to_string())
        )
    } else {
        String::new()
    }
}

/// The located daemon binary answering for itself, exactly as the shell
/// client asked it: its own build, the daemon on the canonical socket, and
/// that daemon's hello — so a staged binary that differs from the running
/// daemon shows as two different versions. `channel::resolve` already pinned
/// `FYOLO_CHANNEL`, which the child inherits.
fn daemon_status(daemon: &std::path::Path) -> Option<lifecycle::NodeStatus> {
    let output = Command::new(daemon).args(["status", "--json"]).output().ok()?;
    if !output.status.success() {
        return None;
    }
    serde_json::from_slice(&output.stdout).ok()
}

/// The running app's `CFBundleShortVersionString+CFBundleVersion`, through
/// `lsappinfo` so only a live process answers — a stale bundle on disk never
/// poses as running. macOS only; anywhere else there is no app.
fn running_app_version(bundle_id: &str) -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let info = Command::new("lsappinfo")
        .args(["info", "-only", "bundlepath", bundle_id])
        .output()
        .ok()?;
    let stdout = String::from_utf8_lossy(&info.stdout);
    let bundle = stdout
        .lines()
        .find_map(|line| line.strip_prefix("\"LSBundlePath\"=\""))
        .and_then(|rest| rest.strip_suffix('"'))?;
    let plist = format!("{bundle}/Contents/Info.plist");
    let read = |key: &str| -> Option<String> {
        let output = Command::new("/usr/libexec/PlistBuddy")
            .args(["-c", &format!("Print :{key}"), &plist])
            .output()
            .ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
            .filter(|value| !value.is_empty())
    };
    let version = read("CFBundleShortVersionString").unwrap_or_else(|| "?".to_string());
    match read("CFBundleVersion") {
        Some(build) => Some(format!("{version}+{build}")),
        None => Some(version),
    }
}

struct RemoteRow {
    alias: String,
    version: String,
    proto: String,
    stamp: String,
}

/// One record per device that has been reached over SSH, labeled by its most
/// recently used alias. Devices only ever seen locally are the local row.
fn remote_rows(support_dir_name: &str) -> Vec<RemoteRow> {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let path = std::path::Path::new(&home)
        .join("Library/Application Support")
        .join(support_dir_name)
        .join("devices.json");
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let Ok(devices) = serde_json::from_str::<Vec<serde_json::Value>>(&raw) else {
        return Vec::new();
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0);
    devices
        .iter()
        .filter_map(|device| {
            let alias = device
                .get("routes")?
                .as_array()?
                .iter()
                .filter_map(|route| route.as_str())
                .find_map(|route| route.strip_prefix("ssh:"))?;
            let version = device
                .get("daemonVersion")
                .and_then(|value| value.as_str())
                .unwrap_or("");
            let proto = device
                .get("proto")
                .and_then(|value| match value {
                    serde_json::Value::Number(number) => Some(number.to_string()),
                    serde_json::Value::String(text) => Some(text.clone()),
                    _ => None,
                })
                .map(|proto| format!("proto {proto}"))
                .unwrap_or_default();
            let stamp = device
                .get("observedAt")
                .and_then(|value| value.as_str())
                .and_then(parse_utc_timestamp)
                .map(|observed| {
                    format!("(as of last connect, {})", age(now.saturating_sub(observed)))
                })
                .unwrap_or_else(|| "(as of an earlier connect)".to_string());
            Some(RemoteRow {
                alias: alias.to_string(),
                version: version.to_string(),
                proto,
                stamp,
            })
        })
        .collect()
}

fn age(seconds: i64) -> String {
    let seconds = seconds.max(0);
    if seconds < 60 {
        "just now".to_string()
    } else if seconds < 3600 {
        format!("{}m ago", seconds / 60)
    } else if seconds < 86400 {
        format!("{}h ago", seconds / 3600)
    } else {
        format!("{}d ago", seconds / 86400)
    }
}

/// `2026-08-31T12:34:56Z` → Unix seconds. The registry writes exactly this
/// shape; anything else reads as "an earlier connect" rather than guessing.
fn parse_utc_timestamp(stamp: &str) -> Option<i64> {
    let bytes = stamp.as_bytes();
    if bytes.len() != 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }
    if bytes[13] != b':' || bytes[16] != b':' || bytes[19] != b'Z' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| stamp.get(range)?.parse::<i64>().ok();
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }
    if !(0..24).contains(&hour) || !(0..60).contains(&minute) || !(0..60).contains(&second) {
        return None;
    }
    // Days-from-civil (Howard Hinnant's algorithm), avoiding a time crate for
    // one fixed-format field. The month-length check above matters because
    // the algorithm normalizes impossible dates instead of rejecting them.
    let year_adjusted = if month <= 2 { year - 1 } else { year };
    let era = year_adjusted.div_euclid(400);
    let year_of_era = year_adjusted - era * 400;
    let month_shifted = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * month_shifted + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
                29
            } else {
                28
            }
        }
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_registry_timestamp_shape_parses_to_unix_seconds() {
        assert_eq!(parse_utc_timestamp("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_utc_timestamp("2026-08-31T00:00:00Z"), Some(1_788_134_400));
    }

    #[test]
    fn anything_else_reads_as_an_earlier_connect() {
        assert_eq!(parse_utc_timestamp(""), None);
        assert_eq!(parse_utc_timestamp("2026-08-31 00:00:00"), None);
        assert_eq!(parse_utc_timestamp("2026-08-31T00:00:00.123Z"), None);
        assert_eq!(parse_utc_timestamp("2026-13-01T00:00:00Z"), None);
    }

    #[test]
    fn impossible_calendar_dates_are_rejected_not_normalized() {
        assert_eq!(parse_utc_timestamp("2026-02-31T00:00:00Z"), None);
        assert_eq!(parse_utc_timestamp("2026-02-29T00:00:00Z"), None);
        assert_eq!(parse_utc_timestamp("2026-04-31T00:00:00Z"), None);
        // 2024-02-29 is real: a leap day, one day after the 28th.
        assert_eq!(
            parse_utc_timestamp("2024-02-29T00:00:00Z"),
            parse_utc_timestamp("2024-02-28T00:00:00Z").map(|epoch| epoch + 86_400)
        );
    }

    #[test]
    fn only_a_running_daemon_older_than_its_binary_is_flagged() {
        let daemon = std::path::Path::new("/Applications/Fyolo.app/Contents/Resources/fyolod");
        let pin = "FYOLO_CHANNEL=dev";
        assert_eq!(
            behind_note(Some("0.49.0+1881"), "0.50.0+1913", daemon, pin),
            "← behind; run `FYOLO_CHANNEL=dev /Applications/Fyolo.app/Contents/Resources/fyolod handoff`"
        );
        assert_eq!(behind_note(Some("0.50.0+1913"), "0.50.0+1913", daemon, pin), "");
        assert_eq!(behind_note(Some("0.51.0+2000"), "0.50.0+1913", daemon, pin), "");
        assert_eq!(behind_note(None, "0.50.0+1913", daemon, pin), "");
    }

    #[test]
    fn ages_bucket_like_the_shell_client() {
        assert_eq!(age(0), "just now");
        assert_eq!(age(59), "just now");
        assert_eq!(age(60), "1m ago");
        assert_eq!(age(3_599), "59m ago");
        assert_eq!(age(3_600), "1h ago");
        assert_eq!(age(86_400 * 3 + 5), "3d ago");
        assert_eq!(age(-5), "just now");
    }
}
