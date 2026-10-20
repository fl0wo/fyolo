//! Python integration: records pytest runs in the sessions the daemon spawns.
//!
//! A session's `PYTHONPATH` gains a directory holding a `sitecustomize.py`.
//! Python imports it at startup, and outside pytest it costs one argv check.
//! Inside pytest it names fyolo's plugin for that one process, which reports
//! each run to this daemon as `report_test_run` (`crate::test_runs`). Then it
//! runs the user's own `sitecustomize`, if there is one, as if it were first on
//! the path. `python_integration/*.py` holds the mechanism and why each step
//! takes the shape it does.
//!
//! `FYOLOD_PYTHONPATH` carries the same entry. The zsh shim re-appends it before
//! each command, because a `.zshrc` that sets `PYTHONPATH` would otherwise
//! replace the session's value. Losing it only loses the recording: nothing in
//! the session depends on the plugin being importable.

use crate::test_runners::Family;

pub const DIRECTORY: &str = "python-integration";

const FILES: [(&str, &str); 2] = [
    (
        "sitecustomize.py",
        include_str!("python_integration/sitecustomize.py"),
    ),
    (
        "fyolo_pytest.py",
        include_str!("python_integration/fyolo_pytest.py"),
    ),
];

/// `PYTHONPATH` and `FYOLOD_PYTHONPATH` for a new session, or nothing when the
/// files can't be written.
pub fn session_env(lookup: &dyn Fn(&str) -> Option<String>) -> Vec<(&'static str, String)> {
    let Some(directory) =
        crate::test_runners::installed_directory(DIRECTORY, &FILES, Family::Python)
    else {
        return Vec::new();
    };
    let Some(entry) = directory
        .to_str()
        .filter(|path| !path.contains(':'))
        .map(str::to_string)
    else {
        eprintln!(
            "fyolod: python integration disabled, path can't be a PYTHONPATH entry: {}",
            directory.display()
        );
        return Vec::new();
    };
    vec![
        (
            "PYTHONPATH",
            python_path(lookup("PYTHONPATH").as_deref(), &entry),
        ),
        ("FYOLOD_PYTHONPATH", entry),
    ]
}

/// `PYTHONPATH` with `entry` appended, last so the user's own modules always
/// win. An empty segment would put the working directory on `sys.path`, so a
/// separator is added only after a non-empty value.
pub fn python_path(inherited: Option<&str>, entry: &str) -> String {
    match inherited.filter(|path| !path.is_empty()) {
        Some(path) if path.split(':').any(|segment| segment == entry) => path.to_string(),
        Some(path) => format!("{path}:{entry}"),
        None => entry.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_entry_is_appended_once_and_never_empty() {
        let entry = "/run/fyolod/python-integration";
        assert_eq!(python_path(None, entry), entry);
        assert_eq!(python_path(Some(""), entry), entry);
        assert_eq!(python_path(Some("src"), entry), format!("src:{entry}"));
        let already = format!("src:{entry}");
        assert_eq!(python_path(Some(&already), entry), already);
    }
}
