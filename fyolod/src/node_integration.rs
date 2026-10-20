//! Node integration: records Vitest runs in the sessions the daemon spawns.
//!
//! A session's `NODE_OPTIONS` gains `--require` of a preload that returns at
//! once unless the process is Vitest's own CLI. Inside Vitest it registers
//! module hooks that add one Vite plugin, and that plugin's `configureVitest`
//! adds a reporter *beside* the user's reporters. The reporter sends each run to
//! this daemon as `report_test_run` (`crate::test_runs`). Nothing in the user's
//! repository or Vitest config changes, and their terminal output stays
//! byte-identical. `node_integration/*.mjs` holds the mechanism and why each
//! step takes the shape it does.
//!
//! `FYOLOD_NODE_OPTIONS` carries the same flag. The zsh shim re-appends it
//! before each command, because a `.zshrc` that sets `NODE_OPTIONS` would
//! otherwise replace the session's value.

use std::path::{Path, PathBuf};

const FILES: [(&str, &str); 3] = [
    ("preload.cjs", include_str!("node_integration/preload.cjs")),
    ("hooks.mjs", include_str!("node_integration/hooks.mjs")),
    ("reporter.mjs", include_str!("node_integration/reporter.mjs")),
];

/// The `--require` flag to add to a session's `NODE_OPTIONS`, or `None` when the
/// files could not be written. `None` never fails the spawn: the session just
/// runs Vitest without recording it.
pub fn require_flag() -> Option<String> {
    let dir = match crate::paths::state_dir() {
        Ok(state) => state.join("node-integration"),
        Err(error) => {
            eprintln!("fyolod: node integration disabled, no state dir: {error}");
            return None;
        }
    };
    if let Err(error) = install(&dir) {
        eprintln!("fyolod: node integration disabled, cannot write {}: {error}", dir.display());
        return None;
    }
    // Absolute, because the flag is read from whatever directory node starts in
    // and a pinned FYOLOD_SOCK may be relative.
    match std::fs::canonicalize(&dir) {
        Ok(dir) => flag_for(&dir.join("preload.cjs")),
        Err(error) => {
            eprintln!("fyolod: node integration disabled, cannot resolve {}: {error}", dir.display());
            None
        }
    }
}

/// `NODE_OPTIONS` with `flag` appended, keeping whatever the session already had.
pub fn node_options(inherited: Option<&str>, flag: &str) -> String {
    match inherited.map(str::trim).filter(|options| !options.is_empty()) {
        Some(options) if options.split_whitespace().any(|option| option == flag) => options.to_string(),
        Some(options) => format!("{options} {flag}"),
        None => flag.to_string(),
    }
}

/// Node splits `NODE_OPTIONS` on whitespace, and the zsh shim matches the flag as
/// one word. A path that needs quoting gets no integration rather than a
/// half-quoted flag.
fn flag_for(preload: &Path) -> Option<String> {
    let path = preload.to_str()?;
    if path.chars().any(|character| character.is_whitespace() || character == '"' || character == '\'' || character == '\\') {
        eprintln!("fyolod: node integration disabled, path needs quoting: {path}");
        return None;
    }
    Some(format!("--require={path}"))
}

/// Write the files if missing or stale. Byte-compared first so steady state is
/// a read, and the files always match the daemon that wrote them.
fn install(dir: &Path) -> std::io::Result<()> {
    for (name, contents) in FILES {
        let path: PathBuf = dir.join(name);
        if std::fs::read(&path).is_ok_and(|current| current == contents.as_bytes()) {
            continue;
        }
        std::fs::create_dir_all(dir)?;
        std::fs::write(&path, contents)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
        install(&dir).expect("install");
        std::fs::write(dir.join("hooks.mjs"), "stale").expect("stale write");
        install(&dir).expect("reinstall");
        for (name, contents) in FILES {
            assert_eq!(std::fs::read_to_string(dir.join(name)).expect("read"), contents, "{name}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
