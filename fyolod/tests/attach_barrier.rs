//! A resize that changes nothing must not repaint anybody.
//!
//! A resize is a barrier (§C.5): the session quiesces, resizes, and hands a
//! fresh keyframe to *every* snapshot-capable attachment, not just the client
//! that asked. `run_attach` asks for the client's size on every attach, so
//! without a no-op guard each attach repaints every other viewer of that
//! session — a phone mirroring it, a second window, the split beside it — for a
//! size change that never happened. A keyframe landing mid-frame is exactly
//! what mangles an incrementally redrawing TUI's composer box, and an idle TUI
//! never repairs it.
//!
//! The session runs `cat`, so nothing but the protocol writes to the screen and
//! a keyframe can only come from an attach or a resize.

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_fyolod");
/// Long enough for a barrier to cross the sidecar and come back; every drain
/// ends on this timeout, so it is also most of the test's runtime.
const QUIET: Duration = Duration::from_millis(600);

fn write_frame(w: &mut impl Write, kind: u8, payload: &[u8]) {
    let mut header = [0u8; 5];
    header[0] = kind;
    header[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    w.write_all(&header).unwrap();
    w.write_all(payload).unwrap();
    w.flush().unwrap();
}

fn read_frame(r: &mut impl Read) -> Option<(u8, Vec<u8>)> {
    let mut header = [0u8; 5];
    r.read_exact(&mut header).ok()?;
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).ok()?;
    Some((header[0], payload))
}

struct Daemon {
    child: Child,
    socket: String,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = std::fs::remove_file(&self.socket);
    }
}

fn start_daemon(tag: &str) -> Daemon {
    let socket = format!("/tmp/fyolod-attach-barrier-{tag}.sock");
    let _ = std::fs::remove_file(&socket);
    let child = Command::new(BIN)
        .arg("serve")
        .env("FYOLOD_SOCK", &socket)
        .env("FYOLOD_KEEP_AWAKE", "off")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !std::path::Path::new(&socket).exists() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
    Daemon { child, socket }
}

/// One attached client, held open so later barriers can be observed on it.
struct Client {
    bridge: Child,
    _stdin: std::process::ChildStdin,
    frames: mpsc::Receiver<(u8, Vec<u8>)>,
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.bridge.kill();
        let _ = self.bridge.wait();
    }
}

/// Attaches as an interactive, snapshot-capable client at `rows`x`cols`.
fn attach(socket: &str, session: &str, rows: u16, cols: u16) -> Client {
    let mut bridge = Command::new(BIN)
        .arg("stdio")
        .env("FYOLOD_SOCK", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn stdio bridge");
    let mut to_bridge = bridge.stdin.take().expect("bridge stdin");
    let mut from_bridge = bridge.stdout.take().expect("bridge stdout");

    let hello = r#"{"op":"hello","proto":1,"min_proto":1,"role":"attach","caps":["snapshot","events"],"client":"attach-barrier"}"#;
    write_frame(&mut to_bridge, b'C', hello.as_bytes());
    let (kind, payload) = read_frame(&mut from_bridge).expect("hello reply");
    assert_eq!(kind, b'C');
    assert!(
        String::from_utf8_lossy(&payload).contains("\"op\":\"hello_ok\""),
        "expected hello_ok, got {}",
        String::from_utf8_lossy(&payload)
    );

    let attach = format!(
        r#"{{"op":"attach","target":"{session}","rows":{rows},"cols":{cols},"mode":"interact"}}"#
    );
    write_frame(&mut to_bridge, b'C', attach.as_bytes());

    let (frames, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        while let Some(frame) = read_frame(&mut from_bridge) {
            if frames.send(frame).is_err() {
                return;
            }
        }
    });

    Client {
        bridge,
        _stdin: to_bridge,
        frames: receiver,
    }
}

/// The grid of every keyframe that arrives before this client's stream goes
/// quiet.
fn keyframe_grids(client: &Client) -> Vec<(u16, u16)> {
    let mut grids = Vec::new();
    while let Ok((kind, payload)) = client.frames.recv_timeout(QUIET) {
        if kind != b'S' {
            continue;
        }
        assert!(payload.len() >= 5, "malformed snapshot header");
        grids.push((
            u16::from_be_bytes([payload[1], payload[2]]),
            u16::from_be_bytes([payload[3], payload[4]]),
        ));
    }
    grids
}

#[test]
fn attaching_at_the_session_size_repaints_nobody() {
    let daemon = start_daemon("sizes");
    let created = Command::new(BIN)
        .arg("create")
        .arg("--name")
        .arg("barrier")
        .arg("--")
        .arg("/bin/cat")
        .env("FYOLOD_SOCK", &daemon.socket)
        .output()
        .expect("create session");
    assert!(created.status.success(), "create failed: {created:?}");

    // A size the session does not have, so this attach really does resize it.
    // One keyframe, and it describes the size asked for — the pending attach
    // capture is superseded by the barrier rather than delivered alongside it.
    let watcher = attach(&daemon.socket, "barrier", 30, 100);
    assert_eq!(
        keyframe_grids(&watcher),
        vec![(30, 100)],
        "an attach that resizes the session owes exactly one keyframe, at the new size"
    );

    // A second window onto the same session, at the size it already is. It gets
    // its own attach keyframe...
    let second = attach(&daemon.socket, "barrier", 30, 100);
    assert_eq!(
        keyframe_grids(&second),
        vec![(30, 100)],
        "an attaching client is always owed its own keyframe"
    );

    // ...and the client already watching is owed nothing: the size did not move.
    assert!(
        keyframe_grids(&watcher).is_empty(),
        "a no-op resize repainted an unrelated viewer"
    );
}
