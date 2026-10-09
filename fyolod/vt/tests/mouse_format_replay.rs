//! A snapshot payload must leave a replaying client in the host's actual
//! mouse format. The formatter re-emits mode bits in enum order — SGR
//! (`?1006h`) before urxvt (`?1015h`) — so a host that enabled urxvt then
//! SGR (crossterm's `EnableMouseCapture`) replayed into urxvt, an encoding
//! crossterm TUIs don't parse. That was #441: herdr's mouse went dead after
//! every attach, resize, or resync.

use fyolod_vt::VtTerminal;

/// crossterm 0.29 `EnableMouseCapture`, byte for byte.
const CROSSTERM_ENABLE_MOUSE: &[u8] = b"\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1015h\x1b[?1006h";

fn last(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .rposition(|window| window == needle)
}

fn count(haystack: &[u8], needle: &[u8]) -> usize {
    haystack
        .windows(needle.len())
        .filter(|window| *window == needle)
        .count()
}

#[test]
fn sgr_wins_the_replay_when_the_host_set_it_last() {
    let mut host = VtTerminal::new(15, 50).expect("host terminal");
    host.vt_write(b"\x1b[?1049h");
    host.vt_write(CROSSTERM_ENABLE_MOUSE);
    host.vt_write(b"herdr screen");

    let payload = host.format_vt().expect("format_vt");
    let sgr = last(&payload, b"\x1b[?1006h").expect("payload restates SGR");
    let urxvt = last(&payload, b"\x1b[?1015h").expect("payload restates urxvt");
    assert!(
        sgr > urxvt,
        "SGR must land after urxvt or the replaying client reports in urxvt; payload: {}",
        String::from_utf8_lossy(&payload).replace('\x1b', "<ESC>")
    );
}

/// A second hop — a handoff, or a resize after an attach — must not regress.
#[test]
fn replayed_client_payload_keeps_sgr_winning() {
    let mut host = VtTerminal::new(15, 50).expect("host terminal");
    host.vt_write(b"\x1b[?1049h");
    host.vt_write(CROSSTERM_ENABLE_MOUSE);

    let payload = host.format_vt().expect("host format_vt");
    let mut client = VtTerminal::new(15, 50).expect("client terminal");
    client.vt_write(&payload);

    let second_hop = client.format_vt().expect("client format_vt");
    let sgr = last(&second_hop, b"\x1b[?1006h").expect("second hop restates SGR");
    let urxvt = last(&second_hop, b"\x1b[?1015h").expect("second hop restates urxvt");
    assert!(sgr > urxvt, "SGR must keep winning across hops");
}

/// A host that only ever set SGR needs no repair.
#[test]
fn payload_without_urxvt_is_untouched() {
    let mut host = VtTerminal::new(15, 50).expect("host terminal");
    host.vt_write(b"\x1b[?1002h\x1b[?1006h");

    let payload = host.format_vt().expect("format_vt");
    assert_eq!(count(&payload, b"\x1b[?1006h"), 1, "no redundant re-assert");
    assert_eq!(count(&payload, b"\x1b[?1015h"), 0);
}
