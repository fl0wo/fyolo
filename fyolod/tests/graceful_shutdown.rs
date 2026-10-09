use serde_json::Value;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const BIN: &str = env!("CARGO_BIN_EXE_fyolod");

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> TestDir {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos();
        // Unix-domain socket paths are short on macOS; the per-user temporary
        // directory can consume most of that limit before the test adds a name.
        let path = PathBuf::from(format!("/tmp/tgs-{}-{nonce:x}", std::process::id()));
        std::fs::create_dir(&path).expect("create isolated daemon state directory");
        TestDir(path)
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Daemon {
    child: Child,
    socket: PathBuf,
}

impl Daemon {
    fn start(socket: &Path) -> Daemon {
        let mut child = Command::new(BIN)
            .arg("serve")
            .env("FYOLOD_SOCK", socket)
            .env("FYOLOD_KEEP_AWAKE", "off")
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn isolated daemon");
        let deadline = Instant::now() + Duration::from_secs(5);
        while !socket.exists() {
            if let Some(status) = child.try_wait().expect("poll daemon startup") {
                let mut stderr = String::new();
                if let Some(mut stream) = child.stderr.take() {
                    let _ = stream.read_to_string(&mut stderr);
                }
                panic!("daemon exited {status} before binding its socket: {stderr}");
            }
            assert!(Instant::now() < deadline, "daemon never bound its socket");
            std::thread::sleep(Duration::from_millis(20));
        }
        Daemon {
            child,
            socket: socket.to_path_buf(),
        }
    }

    fn terminate(&mut self) -> ExitStatus {
        let result = unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        assert_eq!(result, 0, "send SIGTERM to isolated daemon");

        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match self.child.try_wait().expect("poll isolated daemon") {
                Some(status) => return status,
                None if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                None => {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    let mut stderr = String::new();
                    if let Some(mut stream) = self.child.stderr.take() {
                        let _ = stream.read_to_string(&mut stderr);
                    }
                    panic!("daemon did not finish its shutdown drain: {stderr}");
                }
            }
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        let _ = std::fs::remove_file(&self.socket);
    }
}

fn read_array(path: &Path) -> Vec<Value> {
    let bytes = std::fs::read(path).unwrap_or_else(|error| {
        panic!("read {}: {error}", path.display());
    });
    serde_json::from_slice(&bytes).unwrap_or_else(|error| {
        panic!("parse {}: {error}", path.display());
    })
}

#[test]
fn sigterm_buries_sessions_as_deliberately_stopped_before_the_next_daemon_starts() {
    let state = TestDir::new();
    let socket = state.0.join("fyolod.sock");
    let roster = state.0.join("roster.json");
    let graves = state.0.join("tombstones.json");
    let mut first = Daemon::start(&socket);

    let created = Command::new(BIN)
        .args([
            "create",
            "--name",
            "shutdown-proof",
            "--",
            "/bin/sh",
            "-c",
            "sleep 30",
        ])
        .env("FYOLOD_SOCK", &socket)
        .output()
        .expect("create session through isolated daemon");
    assert!(
        created.status.success(),
        "create failed: {}",
        String::from_utf8_lossy(&created.stderr)
    );
    let id = String::from_utf8(created.stdout)
        .expect("session id is UTF-8")
        .trim()
        .to_string();
    assert!(!id.is_empty(), "create returned no session id");
    assert_eq!(read_array(&roster).len(), 1, "session was not rostered");

    let first_status = first.terminate();
    assert!(first_status.success(), "first daemon exited {first_status}");
    assert!(!socket.exists(), "shutdown left the socket behind");

    let stopped = read_array(&graves);
    assert_eq!(stopped.len(), 1, "expected one grave after shutdown");
    assert_eq!(stopped[0]["id"], id);
    assert_eq!(stopped[0]["reason"], "daemon_stopped");
    assert!(
        read_array(&roster).is_empty(),
        "shutdown left a live roster"
    );

    let mut second = Daemon::start(&socket);
    let ready = Command::new(BIN)
        .args(["list", "--json"])
        .env("FYOLOD_SOCK", &socket)
        .output()
        .expect("query replacement daemon");
    assert!(
        ready.status.success(),
        "replacement daemon was not ready: {}",
        String::from_utf8_lossy(&ready.stderr)
    );
    let adopted = read_array(&graves);
    assert_eq!(adopted.len(), 1, "the next daemon added another grave");
    assert_eq!(adopted[0]["id"], id);
    assert_eq!(adopted[0]["reason"], "daemon_stopped");
    assert!(
        adopted.iter().all(|grave| grave["reason"] != "daemon_lost"),
        "the next daemon relabeled a deliberate stop as a crash"
    );

    let second_status = second.terminate();
    assert!(
        second_status.success(),
        "second daemon exited {second_status}"
    );
}
