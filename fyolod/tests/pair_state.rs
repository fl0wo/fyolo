//! `fyolod pair` runs in its own process, usually before the upgraded daemon
//! restarts, so the files an older build kept beside the socket may not have
//! been adopted yet. These tests pin the three CLI paths that used to bypass
//! that: `--rotate` left the legacy token valid, `--wss-off` left a legacy
//! bind for the next startup adoption to re-arm, and `--json` refused an
//! invite whose origin only existed beside the socket.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const BIN: &str = env!("CARGO_BIN_EXE_fyolod");

/// A sandboxed home + runtime dir pair, mirroring the daemon's own
/// derivations: the legacy dir is `$XDG_RUNTIME_DIR/fyolod`, the durable dir
/// is the platform state dir under `$HOME` (`durable_state_base` in
/// `src/paths.rs`).
struct Sandbox {
    root: PathBuf,
}

impl Sandbox {
    fn new(tag: &str) -> Self {
        let root = std::env::temp_dir().join(format!("fyolod-pair-state-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let sandbox = Self { root };
        fs::create_dir_all(sandbox.legacy_dir()).expect("legacy dir");
        fs::create_dir_all(sandbox.home()).expect("home dir");
        sandbox
    }

    fn home(&self) -> PathBuf {
        self.root.join("home")
    }

    fn runtime(&self) -> PathBuf {
        self.root.join("run")
    }

    fn legacy_dir(&self) -> PathBuf {
        self.runtime().join("fyolod")
    }

    fn durable_dir(&self) -> PathBuf {
        if cfg!(target_os = "macos") {
            self.home().join("Library").join("Application Support").join("fyolo")
        } else {
            self.home().join(".local").join("state").join("fyolo")
        }
    }

    fn seed_legacy(&self, name: &str, contents: &str) {
        fs::write(self.legacy_dir().join(name), contents).expect("seeding legacy file");
    }

    fn pair(&self, args: &[&str]) -> std::process::Output {
        Command::new(BIN)
            .arg("pair")
            .args(args)
            .env_clear()
            .env("HOME", self.home())
            .env("XDG_RUNTIME_DIR", self.runtime())
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .output()
            .expect("running fyolod pair")
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default().trim().to_string()
}

/// Rotation is revocation: after `--rotate`, no copy of the old secret may
/// remain anywhere a daemon reads — including beside the socket, where a
/// pre-split daemon still answers handshakes from.
#[test]
fn rotate_revokes_the_legacy_token() {
    let sandbox = Sandbox::new("rotate");
    sandbox.seed_legacy("pair.token", "old-secret");

    let output = sandbox.pair(&["--rotate"]);
    assert!(output.status.success(), "pair --rotate failed: {output:?}");

    let durable = read(&sandbox.durable_dir().join("pair.token"));
    assert!(!durable.is_empty(), "rotation must mint a durable token");
    assert_ne!(durable, "old-secret", "rotation must replace the old secret");
    assert!(
        !sandbox.legacy_dir().join("pair.token").exists(),
        "the legacy copy is a live credential and must go with the rotation"
    );
}

/// `--wss-off` must silence the listener durably: leaving the legacy bind
/// behind meant the next daemon start adopted it and re-armed WSS.
#[test]
fn wss_off_removes_the_legacy_bind_too() {
    let sandbox = Sandbox::new("wssoff");
    sandbox.seed_legacy("wss.bind", "127.0.0.1:8790");

    let output = sandbox.pair(&["--wss-off"]);
    assert!(output.status.success(), "pair --wss-off failed: {output:?}");

    assert!(
        !sandbox.durable_dir().join("wss.bind").exists(),
        "no durable bind may survive --wss-off"
    );
    assert!(
        !sandbox.legacy_dir().join("wss.bind").exists(),
        "a legacy bind left behind re-arms WSS on the next daemon start"
    );
}

/// An invite must find an origin that so far only exists beside the socket:
/// `pair --json` often runs right after an upgrade, before any daemon restart
/// has adopted the legacy files.
#[test]
fn invite_adopts_the_legacy_origin() {
    let sandbox = Sandbox::new("invite");
    sandbox.seed_legacy("wss.origin", "https://box.example.ts.net");

    let output = sandbox.pair(&["--json"]);
    assert!(output.status.success(), "pair --json failed: {output:?}");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("box.example.ts.net"),
        "the invite must carry the adopted origin, got: {stdout}"
    );
    assert_eq!(
        read(&sandbox.durable_dir().join("wss.origin")),
        "https://box.example.ts.net",
        "the origin must have moved into durable state"
    );
}

/// The resurrection race: an adopter that read the legacy bind before
/// `--wss-off` deleted it must not publish it afterwards. Both sides hold the
/// adoption flock, so however the two processes interleave, off means off.
/// (Probabilistic by nature — the unlocked code only loses this race in a
/// narrow window — but it exercises the lock path on every round.)
#[test]
fn wss_off_wins_against_a_concurrent_adopter() {
    let sandbox = Sandbox::new("race");
    for round in 0..12 {
        sandbox.seed_legacy("wss.bind", "127.0.0.1:8790");
        let _ = fs::remove_file(sandbox.durable_dir().join("wss.bind"));

        let adopter = {
            let home = sandbox.home();
            let runtime = sandbox.runtime();
            std::thread::spawn(move || {
                Command::new(BIN)
                    .arg("pair")
                    .env_clear()
                    .env("HOME", home)
                    .env("XDG_RUNTIME_DIR", runtime)
                    .env("PATH", std::env::var_os("PATH").unwrap_or_default())
                    .output()
                    .expect("running the adopting pair")
            })
        };
        let off = sandbox.pair(&["--wss-off"]);
        assert!(off.status.success(), "round {round}: --wss-off failed: {off:?}");
        let _ = adopter.join().expect("adopter thread");

        assert!(
            !sandbox.durable_dir().join("wss.bind").exists()
                && !sandbox.legacy_dir().join("wss.bind").exists(),
            "round {round}: wss.bind resurrected after --wss-off"
        );
    }
}
