//! The test runners fyolod records, and the switch for each one.
//!
//! Every runner reports through the same `report_test_run` control
//! (`crate::test_runs`). What differs is how it gets into the process. The
//! Node runners share one `NODE_OPTIONS` preload (`crate::node_integration`).
//! pytest uses a `PYTHONPATH` entry (`crate::python_integration`). Each of
//! those is a family.
//!
//! A runner that is off costs nothing:
//! - A session spawned while every runner of a family is off gets no
//!   environment change for that family.
//! - A session that is already running sees `<runner>.off` next to the
//!   family's files. The integration checks for it only after the process
//!   has recognised itself as that runner.
//! - The daemon drops reports from a runner that is off.
//!
//! The switch is the app's setting, pushed with `set_test_runners`. The daemon
//! keeps the last value it received, so a session spawned while no app is
//! connected still honours it.

use anyhow::{Context, Result};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Family {
    Node,
    Python,
}

/// Every runner this daemon can record. A report naming anything else is
/// dropped.
pub const RUNNERS: [(&str, Family); 3] = [
    ("vitest", Family::Node),
    ("playwright", Family::Node),
    ("pytest", Family::Python),
];

fn disabled_set() -> &'static Mutex<BTreeSet<String>> {
    static DISABLED: OnceLock<Mutex<BTreeSet<String>>> = OnceLock::new();
    DISABLED.get_or_init(|| {
        Mutex::new(
            settings_path()
                .and_then(|path| read(&path))
                .unwrap_or_default(),
        )
    })
}

pub fn is_enabled(runner: &str) -> bool {
    RUNNERS.iter().any(|(name, _)| *name == runner)
        && !disabled_set().lock().unwrap().contains(runner)
}

fn family_enabled(family: Family) -> bool {
    let disabled = disabled_set().lock().unwrap();
    RUNNERS
        .iter()
        .any(|(name, member)| *member == family && !disabled.contains(*name))
}

/// The runners that are off. Names this daemon doesn't know are kept, so an
/// older daemon doesn't forget a newer app's choice.
pub fn disabled() -> Vec<String> {
    disabled_set().lock().unwrap().iter().cloned().collect()
}

/// Replace the set of runners that are off, persist it, and update the markers
/// that running sessions check.
pub fn set_disabled(runners: Vec<String>) -> Result<Vec<String>> {
    let runners: BTreeSet<String> = runners
        .into_iter()
        .filter(|name| {
            !name.is_empty()
                && name.len() <= 32
                && name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
        .collect();
    *disabled_set().lock().unwrap() = runners.clone();
    if let Some(path) = settings_path() {
        write(&path, &runners)?;
    }
    if let Ok(state) = crate::paths::state_dir() {
        for (directory, family) in [
            (crate::node_integration::DIRECTORY, Family::Node),
            (crate::python_integration::DIRECTORY, Family::Python),
        ] {
            let directory = state.join(directory);
            if directory.is_dir() {
                sync_markers(&directory, family)?;
            }
        }
    }
    Ok(runners.into_iter().collect())
}

/// Environment for a session about to be spawned. `lookup` reads what the
/// session would otherwise inherit.
pub fn session_env(lookup: &dyn Fn(&str) -> Option<String>) -> Vec<(&'static str, String)> {
    let mut env = Vec::new();
    if family_enabled(Family::Node) {
        env.extend(crate::node_integration::session_env(lookup));
    }
    if family_enabled(Family::Python) {
        env.extend(crate::python_integration::session_env(lookup));
    }
    env
}

/// Write a family's files if missing or stale, and its `.off` markers.
/// Comparing bytes first keeps the steady state to reads, and the files always
/// match the daemon that wrote them.
pub(crate) fn install(
    directory: &Path,
    files: &[(&str, &str)],
    family: Family,
) -> std::io::Result<()> {
    for (name, contents) in files {
        let path = directory.join(name);
        if std::fs::read(&path).is_ok_and(|current| current == contents.as_bytes()) {
            continue;
        }
        std::fs::create_dir_all(directory)?;
        std::fs::write(&path, contents)?;
    }
    sync_markers(directory, family)
}

fn sync_markers(directory: &Path, family: Family) -> std::io::Result<()> {
    let disabled = disabled_set().lock().unwrap().clone();
    for (name, _) in RUNNERS.iter().filter(|(_, member)| *member == family) {
        let marker = directory.join(format!("{name}.off"));
        if disabled.contains(*name) {
            if !marker.exists() {
                std::fs::write(&marker, "")?;
            }
        } else if let Err(error) = std::fs::remove_file(&marker) {
            if error.kind() != std::io::ErrorKind::NotFound {
                return Err(error);
            }
        }
    }
    Ok(())
}

/// Absolute, because a session reads it from whatever directory its process
/// starts in, and a pinned `FYOLOD_SOCK` can be relative. `None` when the files
/// can't be written, which never fails the spawn: the runner just isn't
/// recorded.
pub(crate) fn installed_directory(
    name: &str,
    files: &[(&str, &str)],
    family: Family,
) -> Option<PathBuf> {
    let directory = match crate::paths::state_dir() {
        Ok(state) => state.join(name),
        Err(error) => {
            eprintln!("fyolod: {name} disabled, no state dir: {error}");
            return None;
        }
    };
    if let Err(error) = install(&directory, files, family) {
        eprintln!(
            "fyolod: {name} disabled, cannot write {}: {error}",
            directory.display()
        );
        return None;
    }
    match std::fs::canonicalize(&directory) {
        Ok(directory) => Some(directory),
        Err(error) => {
            eprintln!(
                "fyolod: {name} disabled, cannot resolve {}: {error}",
                directory.display()
            );
            None
        }
    }
}

fn settings_path() -> Option<PathBuf> {
    crate::paths::durable_state_dir()
        .ok()
        .map(|state| state.join("test-runners.json"))
}

fn read(path: &Path) -> Option<BTreeSet<String>> {
    #[derive(serde::Deserialize)]
    struct Settings {
        #[serde(default)]
        disabled: BTreeSet<String>,
    }
    let text = std::fs::read(path).ok()?;
    match serde_json::from_slice::<Settings>(&text) {
        Ok(settings) => Some(settings.disabled),
        Err(error) => {
            eprintln!("fyolod: ignoring unreadable {}: {error}", path.display());
            None
        }
    }
}

fn write(path: &Path, disabled: &BTreeSet<String>) -> Result<()> {
    let text = serde_json::to_vec(&serde_json::json!({ "disabled": disabled }))?;
    let temporary = path.with_extension("tmp");
    std::fs::write(&temporary, text).with_context(|| format!("writing {}", temporary.display()))?;
    std::fs::rename(&temporary, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markers_follow_the_disabled_set() {
        let directory =
            std::env::temp_dir().join(format!("fyolod-runner-markers-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("scratch");
        *disabled_set().lock().unwrap() = BTreeSet::from(["playwright".to_string()]);
        sync_markers(&directory, Family::Node).expect("sync");
        assert!(directory.join("playwright.off").exists());
        assert!(!directory.join("vitest.off").exists());
        assert!(!is_enabled("playwright"));
        assert!(is_enabled("vitest"));
        assert!(!is_enabled("jest"), "unknown runners are never recorded");
        *disabled_set().lock().unwrap() = BTreeSet::new();
        sync_markers(&directory, Family::Node).expect("resync");
        assert!(!directory.join("playwright.off").exists());
        let _ = std::fs::remove_dir_all(&directory);
    }
}
