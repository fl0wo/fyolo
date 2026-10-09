//! Stamps the build version into the binary as `FYOLOD_VERSION`.
//!
//! The crate version in `Cargo.toml` never moves with the app's releases, so
//! comparing it would call every daemon current. The app is stamped from
//! `FYOLO_VERSION` and `FYOLO_BUILD` (`scripts/build-app.sh`, set by the
//! release workflow from the tag), and the daemon takes the same two so the
//! version a daemon reports is the version of the app that shipped it:
//! `0.44.0+1533`. The build number is what orders two dev builds of one
//! version, and it is also the fallback when there is no tag — a checkout
//! reports `0.0.0+<commit count>`, which compares older than any release
//! (a dev build never stages itself over a released daemon) but still
//! advances between two dev builds.

use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=FYOLO_VERSION");
    println!("cargo:rerun-if-env-changed=FYOLO_BUILD");
    // The commit-count fallback below moves with every commit, so the stamp
    // has to be recomputed when HEAD does — otherwise a checkout keeps
    // reporting the count of whatever it was first built at.
    for path in head_paths() {
        println!("cargo:rerun-if-changed={path}");
    }

    let version = std::env::var("FYOLO_VERSION")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "0.0.0".to_string());
    let build = std::env::var("FYOLO_BUILD")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(commit_count)
        .unwrap_or_else(|| "0".to_string());
    println!("cargo:rustc-env=FYOLOD_VERSION={version}+{build}");
}

/// The files that change when HEAD moves: `HEAD` itself, and the branch ref
/// it points at. Resolved through git so a worktree's private git dir is
/// found too. Empty outside a checkout.
fn head_paths() -> Vec<String> {
    let git = |args: &[&str]| -> Option<String> {
        let output = Command::new("git")
            .args(args)
            .current_dir(env!("CARGO_MANIFEST_DIR"))
            .output()
            .ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
            .filter(|text| !text.is_empty())
    };
    let mut paths = Vec::new();
    if let Some(head) = git(&["rev-parse", "--git-path", "HEAD"]) {
        paths.push(head);
    }
    if let Some(reference) = git(&["symbolic-ref", "-q", "HEAD"]) {
        if let Some(path) = git(&["rev-parse", "--git-path", &reference]) {
            paths.push(path);
        }
    }
    paths
}

/// `git rev-list --count HEAD`, the same number the release workflow stamps as
/// the app's build number. `None` outside a checkout, or without git.
fn commit_count() -> Option<String> {
    let output = Command::new("git")
        .args(["rev-list", "--count", "HEAD"])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let count = String::from_utf8(output.stdout).ok()?;
    let count = count.trim();
    count.parse::<u64>().ok().map(|_| count.to_string())
}
