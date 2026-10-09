//! Acceptance for `fyolod serve --wss`: a client speaking the framed protocol
//! over a WebSocket gets byte-identical results to a Unix-socket client, and
//! every refusal in §"Auth" actually refuses.
//!
//! Mirrors `stdio_bridge.rs` — spawn the real binary, drive it with hand-written
//! frames — with one addition the WebSocket makes possible: a protocol frame is
//! deliberately split across two binary messages, because the splice must
//! concatenate chunks rather than treat one message as one frame.

use futures_util::{SinkExt, StreamExt};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;

const BIN: &str = env!("CARGO_BIN_EXE_fyolod");
const TOKEN: &str = "test-pairing-token-0123456789ab";

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

struct Daemon {
    child: Option<Child>,
    dir: PathBuf,
    socket: PathBuf,
    port: u16,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A private state dir per test: `pair.token`, `wss.bind` and `host.id` all
/// hang off the socket's parent, so sharing one would make the tests race.
fn state_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("fyolod-wss-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("state dir");
    dir
}

fn write_token(dir: &std::path::Path, token: &str) {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(dir.join("pair.token"))
        .expect("pair.token");
    file.write_all(token.as_bytes()).expect("pair.token write");
}

fn free_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("probe port");
    let port = listener.local_addr().expect("probe addr").port();
    drop(listener);
    port
}

fn wait_for_socket(socket: &std::path::Path) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
}

fn wait_for_port(port: u16) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return;
        }
        assert!(Instant::now() < deadline, "wss never bound :{port}");
        std::thread::sleep(Duration::from_millis(30));
    }
}

/// Start `fyolod serve` with a WSS bind. `token` absent means no `pair.token`.
fn start_daemon(tag: &str, token: Option<&str>, inherited: bool) -> Daemon {
    let dir = state_dir(tag);
    let socket = dir.join("fyolod.sock");
    let port = free_port();
    if let Some(token) = token {
        write_token(&dir, token);
    }
    let mut command = Command::new(BIN);
    command.arg("serve").env("FYOLOD_SOCK", &socket);
    command.env("FYOLOD_KEEP_AWAKE", "off");
    if inherited {
        command.env("FYOLOD_WSS", format!("127.0.0.1:{port}"));
    } else {
        command.args(["--wss", &format!("127.0.0.1:{port}")]);
    }
    let child = command
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    wait_for_socket(&socket);
    Daemon {
        child: Some(child),
        dir,
        socket,
        port,
    }
}

fn create_session(daemon: &Daemon, name: &str, script: &str) {
    let created = Command::new(BIN)
        .args([
            "create", "--name", name, "--", "bash", "--norc", "-c", script,
        ])
        .env("FYOLOD_SOCK", &daemon.socket)
        .output()
        .expect("create");
    assert!(
        created.status.success(),
        "create failed: {}",
        String::from_utf8_lossy(&created.stderr)
    );
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.push(kind);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn split_frame(buffer: &mut Vec<u8>) -> Option<(u8, Vec<u8>)> {
    if buffer.len() < 5 {
        return None;
    }
    let len = u32::from_be_bytes([buffer[1], buffer[2], buffer[3], buffer[4]]) as usize;
    if buffer.len() < 5 + len {
        return None;
    }
    let payload = buffer[5..5 + len].to_vec();
    let kind = buffer[0];
    buffer.drain(..5 + len);
    Some((kind, payload))
}

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A framed reader over either transport. Both sides buffer and re-split, which
/// is the point: the WebSocket carries chunks of one stream, not one frame per
/// message.
enum Client {
    Web(Box<Socket>, Vec<u8>),
    Unix(tokio::net::UnixStream, Vec<u8>),
}

impl Client {
    async fn write(&mut self, bytes: &[u8]) {
        match self {
            Client::Web(socket, _) => socket
                .send(Message::Binary(bytes.to_vec().into()))
                .await
                .expect("ws send"),
            Client::Unix(stream, _) => stream.write_all(bytes).await.expect("unix write"),
        }
    }

    async fn read_frame(&mut self) -> (u8, Vec<u8>) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
        loop {
            let buffered = match self {
                Client::Web(_, buffer) => split_frame(buffer),
                Client::Unix(_, buffer) => split_frame(buffer),
            };
            if let Some(frame) = buffered {
                return frame;
            }
            let read = tokio::time::timeout_at(deadline, self.fill()).await;
            assert!(read.is_ok(), "timed out waiting for a frame");
        }
    }

    async fn fill(&mut self) {
        match self {
            Client::Web(socket, buffer) => match socket.next().await {
                Some(Ok(Message::Binary(bytes))) => buffer.extend_from_slice(&bytes),
                Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                other => panic!("websocket ended early: {other:?}"),
            },
            Client::Unix(stream, buffer) => {
                let mut chunk = [0u8; 16 * 1024];
                match stream.read(&mut chunk).await {
                    Ok(0) => panic!("unix socket closed early"),
                    Ok(count) => buffer.extend_from_slice(&chunk[..count]),
                    Err(error) => panic!("unix read failed: {error}"),
                }
            }
        }
    }
}

async fn dial_websocket(
    port: u16,
    path: &str,
    origin: Option<&str>,
    subprotocol: Option<&str>,
) -> Result<Socket, tokio_tungstenite::tungstenite::Error> {
    let mut request = format!("ws://127.0.0.1:{port}{path}")
        .into_client_request()
        .expect("client request");
    if let Some(origin) = origin {
        request.headers_mut().insert(
            "origin",
            HeaderValue::from_str(origin).expect("origin header"),
        );
    }
    if let Some(subprotocol) = subprotocol {
        request.headers_mut().insert(
            "sec-websocket-protocol",
            HeaderValue::from_str(subprotocol).expect("subprotocol header"),
        );
    }
    tokio_tungstenite::connect_async(request)
        .await
        .map(|(socket, _)| socket)
}

async fn attached_web_client(daemon: &Daemon) -> Client {
    let socket = dial_websocket(
        daemon.port,
        "/ws",
        Some(&format!("http://127.0.0.1:{}", daemon.port)),
        Some(&format!("fyolod.{TOKEN}")),
    )
    .await
    .expect("websocket upgrade");
    Client::Web(Box::new(socket), Vec::new())
}

async fn unix_client(daemon: &Daemon) -> Client {
    let stream = tokio::net::UnixStream::connect(&daemon.socket)
        .await
        .expect("unix connect");
    Client::Unix(stream, Vec::new())
}

const HELLO: &[u8] =
    br#"{"op":"hello","proto":1,"min_proto":1,"role":"attach","caps":["events","snapshot"],"client":"wss-test"}"#;

/// hello → hello_ok, attach → attached, S, ready. Returns the frames after the
/// handshake so two transports can be compared.
async fn handshake_and_attach(client: &mut Client, target: &str) -> Vec<(u8, Vec<u8>)> {
    client.write(&frame(b'C', HELLO)).await;
    let (kind, payload) = client.read_frame().await;
    assert_eq!(kind, b'C');
    assert!(
        String::from_utf8_lossy(&payload).contains("\"op\":\"hello_ok\""),
        "expected hello_ok, got {}",
        String::from_utf8_lossy(&payload)
    );

    let attach =
        format!(r#"{{"op":"attach","target":"{target}","rows":24,"cols":80,"mode":"observe"}}"#);
    client.write(&frame(b'C', attach.as_bytes())).await;

    let mut frames = Vec::new();
    loop {
        let (kind, payload) = client.read_frame().await;
        let is_ready =
            kind == b'E' && String::from_utf8_lossy(&payload).contains("\"ev\":\"ready\"");
        frames.push((kind, payload));
        if is_ready {
            return frames;
        }
    }
}

// ---------------------------------------------------------------------------
// Acceptance
// ---------------------------------------------------------------------------

/// §C.9 over the WebSocket: the same transcript, the same bytes back.
#[tokio::test]
async fn framed_protocol_is_byte_identical_over_the_websocket() {
    let daemon = start_daemon("accept", Some(TOKEN), false);
    wait_for_port(daemon.port);
    create_session(
        &daemon,
        "wsssession",
        "printf 'WSS_ACCEPTANCE_MARK\\r\\n'; sleep 30",
    );
    // Let the screen settle so both observers snapshot the same grid.
    tokio::time::sleep(Duration::from_millis(800)).await;

    let mut over_unix = unix_client(&daemon).await;
    let unix_frames = handshake_and_attach(&mut over_unix, "wsssession").await;

    let mut over_web = attached_web_client(&daemon).await;
    let web_frames = handshake_and_attach(&mut over_web, "wsssession").await;

    let kinds = |frames: &[(u8, Vec<u8>)]| frames.iter().map(|(kind, _)| *kind).collect::<Vec<_>>();
    assert_eq!(
        kinds(&unix_frames),
        kinds(&web_frames),
        "the two transports produced different frame sequences"
    );
    assert_eq!(unix_frames, web_frames, "frames differed byte for byte");

    let snapshot = unix_frames
        .iter()
        .find(|(kind, _)| *kind == b'S')
        .expect("no S snapshot");
    assert!(
        snapshot
            .1
            .windows(b"WSS_ACCEPTANCE_MARK".len())
            .any(|window| window == b"WSS_ACCEPTANCE_MARK"),
        "the snapshot did not carry the session's screen"
    );

    // Live bytes after the barrier reach both attachments identically.
    let sent = Command::new(BIN)
        .args(["send", "wsssession", "echo", "LIVE_MARK"])
        .env("FYOLOD_SOCK", &daemon.socket)
        .output()
        .expect("send");
    assert!(sent.status.success(), "send failed");

    let unix_live = read_until_mark(&mut over_unix, b"LIVE_MARK").await;
    let web_live = read_until_mark(&mut over_web, b"LIVE_MARK").await;
    assert_eq!(
        unix_live, web_live,
        "live D bytes differed between transports"
    );
}

async fn read_until_mark(client: &mut Client, mark: &[u8]) -> Vec<u8> {
    let mut collected = Vec::new();
    for _ in 0..200 {
        let (kind, payload) = client.read_frame().await;
        if kind != b'D' {
            continue;
        }
        collected.extend_from_slice(&payload);
        if collected.windows(mark.len()).any(|window| window == mark) {
            return collected;
        }
    }
    panic!("never saw {}", String::from_utf8_lossy(mark));
}

/// One WebSocket message is *not* one protocol frame. A frame split across two
/// binary messages must still arrive, or a recorded Unix transcript would not
/// replay over this transport.
#[tokio::test]
async fn a_frame_split_across_two_messages_still_arrives() {
    let daemon = start_daemon("chunked", Some(TOKEN), false);
    wait_for_port(daemon.port);
    let mut client = attached_web_client(&daemon).await;

    let hello = frame(b'C', HELLO);
    let (head, tail) = hello.split_at(3);
    client.write(head).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    client.write(tail).await;

    let (kind, payload) = client.read_frame().await;
    assert_eq!(kind, b'C');
    assert!(
        String::from_utf8_lossy(&payload).contains("\"op\":\"hello_ok\""),
        "a split frame was not reassembled: {}",
        String::from_utf8_lossy(&payload)
    );
}

// ---------------------------------------------------------------------------
// Refusals — the security surface
// ---------------------------------------------------------------------------

#[test]
fn an_off_loopback_bind_is_refused_at_flag_parse() {
    for address in ["0.0.0.0:8790", "[::]:8790", "192.168.1.10:8790"] {
        let dir = state_dir(&format!("offloopback-{}", address.len()));
        write_token(&dir, TOKEN);
        let output = Command::new(BIN)
            .args(["serve", "--wss", address])
            .env("FYOLOD_SOCK", dir.join("fyolod.sock"))
            .output()
            .expect("serve");
        assert!(!output.status.success(), "{address} was accepted");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("not loopback"),
            "{address}: unexpected refusal: {stderr}"
        );
        assert!(
            !dir.join("wss.bind").exists(),
            "{address} wrote a durable bind"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[test]
fn an_explicit_bind_without_a_token_refuses_the_whole_start() {
    let dir = state_dir("no-token-explicit");
    let socket = dir.join("fyolod.sock");
    let output = Command::new(BIN)
        .args(["serve", "--wss", &format!("127.0.0.1:{}", free_port())])
        .env("FYOLOD_SOCK", &socket)
        .output()
        .expect("serve");
    assert!(!output.status.success(), "serve started without a token");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("fyolod pair"),
        "the refusal did not point at pairing: {stderr}"
    );
    assert!(
        !dir.join("wss.bind").exists(),
        "a refused start still wrote wss.bind"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_inherited_bind_without_a_token_still_serves_the_unix_socket() {
    let daemon = start_daemon("no-token-inherited", None, true);
    assert!(daemon.socket.exists(), "the Unix socket was not bound");
    assert!(
        std::net::TcpStream::connect(("127.0.0.1", daemon.port)).is_err(),
        "the listener bound TCP with no pair.token"
    );
}

#[tokio::test]
async fn a_missing_or_wrong_token_is_refused() {
    let daemon = start_daemon("token", Some(TOKEN), false);
    wait_for_port(daemon.port);
    let origin = format!("http://127.0.0.1:{}", daemon.port);

    for subprotocol in [None, Some("fyolod.wrong"), Some("fyolod.")] {
        let result = dial_websocket(daemon.port, "/ws", Some(&origin), subprotocol).await;
        assert!(
            result.is_err(),
            "an Upgrade with {subprotocol:?} was accepted"
        );
    }

    // The token in the query string is not an alternative placement.
    let result = dial_websocket(daemon.port, &format!("/ws?t={TOKEN}"), Some(&origin), None).await;
    assert!(result.is_err(), "?t= authenticated an Upgrade");
}

#[tokio::test]
async fn a_disallowed_origin_is_refused() {
    let daemon = start_daemon("origin", Some(TOKEN), false);
    wait_for_port(daemon.port);
    let subprotocol = format!("fyolod.{TOKEN}");

    for origin in [None, Some("null"), Some("https://evil.example")] {
        let result = dial_websocket(daemon.port, "/ws", origin, Some(&subprotocol)).await;
        assert!(result.is_err(), "Origin {origin:?} was accepted");
    }
}

#[tokio::test]
async fn the_fyolo_prefix_is_optional_but_not_repeatable() {
    let daemon = start_daemon("paths", Some(TOKEN), false);
    wait_for_port(daemon.port);
    let origin = format!("http://127.0.0.1:{}", daemon.port);
    let subprotocol = format!("fyolod.{TOKEN}");

    for path in ["/ws", "/fyolo/ws"] {
        let result = dial_websocket(daemon.port, path, Some(&origin), Some(&subprotocol)).await;
        assert!(result.is_ok(), "{path} did not upgrade");
    }
    for path in ["/fyolo/fyolo/ws", "/", "/fyolo/"] {
        let result = dial_websocket(daemon.port, path, Some(&origin), Some(&subprotocol)).await;
        assert!(result.is_err(), "{path} upgraded");
    }
}

#[tokio::test]
async fn a_text_message_closes_the_socket() {
    let daemon = start_daemon("text", Some(TOKEN), false);
    wait_for_port(daemon.port);
    let Client::Web(mut socket, _) = attached_web_client(&daemon).await else {
        panic!("expected a websocket client");
    };

    socket
        .send(Message::text("{\"op\":\"hello\"}"))
        .await
        .expect("send text");

    match tokio::time::timeout(Duration::from_secs(5), socket.next()).await {
        Ok(None) | Ok(Some(Err(_))) | Ok(Some(Ok(Message::Close(_)))) => {}
        Ok(Some(Ok(message))) => panic!("the socket stayed open: {message:?}"),
        Err(_) => panic!("the socket neither closed nor answered"),
    }
}

/// Rotation is the only revocation there is, so it has to reach sockets that
/// are already spliced — and it is a detach, not a kill.
#[tokio::test]
async fn rotating_the_token_drops_a_live_splice_without_killing_the_session() {
    let daemon = start_daemon("rotate", Some(TOKEN), false);
    wait_for_port(daemon.port);
    create_session(&daemon, "rotatesession", "sleep 30");

    let mut client = attached_web_client(&daemon).await;
    client.write(&frame(b'C', HELLO)).await;
    let (kind, _) = client.read_frame().await;
    assert_eq!(kind, b'C', "no hello_ok before rotating");

    let rotated = Command::new(BIN)
        .args(["pair", "--rotate"])
        .env("FYOLOD_SOCK", &daemon.socket)
        .output()
        .expect("pair --rotate");
    assert!(rotated.status.success(), "pair --rotate failed");

    let Client::Web(mut socket, _) = client else {
        panic!("expected a websocket client");
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let closed = loop {
        match tokio::time::timeout_at(deadline, socket.next()).await {
            Err(_) => break false,
            Ok(None) | Ok(Some(Err(_))) | Ok(Some(Ok(Message::Close(_)))) => break true,
            Ok(Some(Ok(_))) => {}
        }
    };
    assert!(closed, "the splice survived a token rotation");

    let listed = Command::new(BIN)
        .args(["list", "--json"])
        .env("FYOLOD_SOCK", &daemon.socket)
        .output()
        .expect("list");
    assert!(
        String::from_utf8_lossy(&listed.stdout).contains("rotatesession"),
        "rotation killed the session instead of detaching the client"
    );
}

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

#[test]
fn pair_mints_once_and_rotate_replaces() {
    let dir = state_dir("pair");
    let socket = dir.join("fyolod.sock");

    let run = |args: &[&str]| {
        Command::new(BIN)
            .arg("pair")
            .args(args)
            .env("FYOLOD_SOCK", &socket)
            .output()
            .expect("pair")
    };

    let first = run(&[]);
    assert!(first.status.success(), "pair failed");
    let token = String::from_utf8_lossy(&first.stdout).trim().to_string();
    assert_eq!(
        token.len(),
        32,
        "expected 24 base64url bytes, got {token:?}"
    );
    assert!(token
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));

    let again = run(&[]);
    assert_eq!(
        String::from_utf8_lossy(&again.stdout).trim(),
        token,
        "pair minted a second token"
    );

    let mode = std::fs::metadata(dir.join("pair.token"))
        .expect("pair.token")
        .permissions();
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(mode.mode() & 0o777, 0o600, "pair.token is not 0600");

    let rotated = run(&["--rotate"]);
    let rotated_token = String::from_utf8_lossy(&rotated.stdout).trim().to_string();
    assert_ne!(rotated_token, token, "--rotate reused the token");

    let _ = std::fs::remove_dir_all(&dir);
}

/// D4: the reachable name cannot be derived from a loopback bind, so an invite
/// with nowhere to point is refused rather than printed.
#[test]
fn pair_refuses_a_qr_with_no_reachable_url() {
    let dir = state_dir("pair-no-url");
    let socket = dir.join("fyolod.sock");

    for flag in ["--qr", "--json"] {
        let output = Command::new(BIN)
            .args(["pair", flag])
            .env("FYOLOD_SOCK", &socket)
            .env_remove("FYOLOD_WSS_ORIGIN")
            .output()
            .expect("pair");
        assert!(!output.status.success(), "pair {flag} printed to nowhere");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("no reachable URL"), "pair {flag}: {stderr}");
    }

    let output = Command::new(BIN)
        .args(["pair", "--json", "--url", "https://box.example/fyolo/"])
        .env("FYOLOD_SOCK", &socket)
        .output()
        .expect("pair");
    assert!(output.status.success(), "pair --json --url failed");
    let invite = String::from_utf8_lossy(&output.stdout);
    for field in ["\"url\"", "\"token\"", "\"host_id\"", "\"proto\""] {
        assert!(
            invite.contains(field),
            "invite is missing {field}: {invite}"
        );
    }

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn wss_off_removes_the_durable_bind() {
    let daemon = start_daemon("wss-off", Some(TOKEN), false);
    // The unix socket is bound before the wss listener is, and the bind file is
    // written with the listener — so asserting straight off `start_daemon` races
    // the daemon under a loaded machine. Every other test here waits for the
    // port first; this one did not, and failed roughly one full `cargo test` in
    // two while passing alone every time.
    wait_for_port(daemon.port);
    let bind_file = daemon.dir.join("wss.bind");
    assert!(
        bind_file.exists(),
        "an explicit --wss with a token did not persist the bind"
    );

    let output = Command::new(BIN)
        .args(["pair", "--wss-off"])
        .env("FYOLOD_SOCK", &daemon.socket)
        .output()
        .expect("pair --wss-off");
    assert!(output.status.success(), "pair --wss-off failed");
    assert!(!bind_file.exists(), "wss.bind survived --wss-off");
}
