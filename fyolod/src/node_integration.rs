//! Node integration: records Vitest and Playwright Test runs in the sessions
//! the daemon spawns.
//!
//! A session's `NODE_OPTIONS` gains `--require` of a preload that returns at
//! once unless the process is one of those runners' own CLI. Inside it, the
//! runner's adapter adds a reporter *beside* the user's reporters:
//! - Vitest: module hooks add one Vite plugin, whose `configureVitest` appends
//!   the reporter.
//! - Playwright: `PW_TEST_REPORTER`, which Playwright appends after the
//!   configured reporters.
//!
//! The reporter sends each run to this daemon as `report_test_run`
//! (`crate::test_runs`). Nothing in the user's repository or config changes,
//! and their terminal output stays byte-identical. `node_integration/*` holds
//! the mechanism and why each step takes the shape it does.
//!
//! `FYOLOD_NODE_OPTIONS` carries the same flag. The zsh shim re-appends it
//! before each command, because a `.zshrc` that sets `NODE_OPTIONS` would
//! otherwise replace the session's value.

use crate::test_runners::Family;
use std::path::Path;

pub const DIRECTORY: &str = "node-integration";

const FILES: [(&str, &str); 5] = [
    ("preload.cjs", include_str!("node_integration/preload.cjs")),
    ("channel.cjs", include_str!("node_integration/channel.cjs")),
    ("hooks.mjs", include_str!("node_integration/hooks.mjs")),
    (
        "vitest-reporter.mjs",
        include_str!("node_integration/vitest-reporter.mjs"),
    ),
    (
        "playwright-reporter.cjs",
        include_str!("node_integration/playwright-reporter.cjs"),
    ),
];

/// `NODE_OPTIONS` and `FYOLOD_NODE_OPTIONS` for a new session, or nothing when
/// the files can't be written. Nothing never fails the spawn: the session just
/// runs its tests unrecorded.
pub fn session_env(lookup: &dyn Fn(&str) -> Option<String>) -> Vec<(&'static str, String)> {
    let Some(directory) = crate::test_runners::installed_directory(DIRECTORY, &FILES, Family::Node)
    else {
        return Vec::new();
    };
    let Some(flag) = flag_for(&directory.join("preload.cjs")) else {
        return Vec::new();
    };
    vec![
        (
            "NODE_OPTIONS",
            node_options(lookup("NODE_OPTIONS").as_deref(), &flag),
        ),
        ("FYOLOD_NODE_OPTIONS", flag),
    ]
}

/// `NODE_OPTIONS` with `flag` appended, keeping whatever the session already had.
pub fn node_options(inherited: Option<&str>, flag: &str) -> String {
    match inherited
        .map(str::trim)
        .filter(|options| !options.is_empty())
    {
        Some(options) if options.split_whitespace().any(|option| option == flag) => {
            options.to_string()
        }
        Some(options) => format!("{options} {flag}"),
        None => flag.to_string(),
    }
}

/// Node splits `NODE_OPTIONS` on whitespace, and the zsh shim matches the flag as
/// one word. A path that needs quoting gets no integration rather than a
/// half-quoted flag.
fn flag_for(preload: &Path) -> Option<String> {
    let path = preload.to_str()?;
    if path.chars().any(|character| {
        character.is_whitespace() || character == '"' || character == '\'' || character == '\\'
    }) {
        eprintln!("fyolod: node integration disabled, path needs quoting: {path}");
        return None;
    }
    Some(format!("--require={path}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_runners::install;

    #[test]
    fn options_are_appended_once() {
        let flag = "--require=/run/fyolod/node-integration/preload.cjs";
        assert_eq!(node_options(None, flag), flag);
        assert_eq!(node_options(Some("  "), flag), flag);
        assert_eq!(
            node_options(Some("--max-old-space-size=4096"), flag),
            format!("--max-old-space-size=4096 {flag}")
        );
        let already = format!("--enable-source-maps {flag}");
        assert_eq!(node_options(Some(&already), flag), already);
    }

    #[test]
    fn paths_that_need_quoting_are_refused() {
        assert!(flag_for(Path::new("/Users/a b/preload.cjs")).is_none());
        assert_eq!(
            flag_for(Path::new("/tmp/fyolod-501/node-integration/preload.cjs")).as_deref(),
            Some("--require=/tmp/fyolod-501/node-integration/preload.cjs")
        );
    }

    #[test]
    fn files_are_installed_and_kept_current() {
        let dir = std::env::temp_dir().join(format!("fyolod-node-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        install(&dir, &FILES, Family::Node).expect("install");
        std::fs::write(dir.join("hooks.mjs"), "stale").expect("stale write");
        install(&dir, &FILES, Family::Node).expect("reinstall");
        for (name, contents) in FILES {
            assert_eq!(
                std::fs::read_to_string(dir.join(name)).expect("read"),
                contents,
                "{name}"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
