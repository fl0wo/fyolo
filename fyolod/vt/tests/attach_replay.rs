//! A snapshot payload must leave a replaying client on the *same* screen as
//! the host — including the scroll position. The formatter paints a scrolled
//! primary screen as one newline-joined flow that stops at the last non-blank
//! row, so without compensation the client ends up a scroll step behind the
//! host, the trailing cursor re-assert lands on the last painted line, and the
//! first live byte after the seam overwrites that line. That was the reattach
//! bug: quit the app mid-stream, reopen it, and the line written in the attach
//! second vanished from the screen.

use fyolod_vt::VtTerminal;

fn screen(vt: &mut VtTerminal) -> Vec<String> {
    let snapshot = vt.snapshot().expect("snapshot");
    let cols = usize::from(snapshot.cols);
    snapshot
        .cells
        .chunks(cols)
        .map(|row| {
            row.iter()
                .map(|cell| char::from_u32(cell.codepoint).unwrap_or(' '))
                .map(|c| if c == '\0' { ' ' } else { c })
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect()
}

fn replay(host: &mut VtTerminal, rows: u16, cols: u16) -> VtTerminal {
    let payload = host.format_vt().expect("format_vt");
    let mut client = VtTerminal::new(rows, cols).expect("client terminal");
    client.vt_write(&payload);
    client
}

/// The captured bug, end to end: a program has been streaming one line per
/// tick for long enough to scroll, the client attaches, and the next live
/// line must append below the last one — not overwrite it.
#[test]
fn replayed_stream_keeps_the_hosts_scroll_position() {
    let mut host = VtTerminal::new(15, 50).expect("host terminal");
    for i in 1..=40 {
        host.vt_write(format!("tick  {i:04}\r\n").as_bytes());
    }
    let mut client = replay(&mut host, 15, 50);
    assert_eq!(
        screen(&mut client),
        screen(&mut host),
        "replaying the payload must reproduce the host screen, scroll included"
    );

    let live = b"tick  0041\r\n";
    host.vt_write(live);
    client.vt_write(live);
    let host_screen = screen(&mut host);
    assert_eq!(screen(&mut client), host_screen);
    assert!(
        host_screen.iter().any(|row| row.contains("tick  0040")),
        "the line written just before the seam must survive the first live line"
    );
}

/// A long burst of bare newlines — more than any small fixed cap would allow —
/// still converges: the search bound is the live screen's trailing blank run,
/// not a constant.
#[test]
fn replayed_stream_recovers_a_screenful_of_dropped_scrolls() {
    let mut host = VtTerminal::new(20, 40).expect("host terminal");
    for i in 1..=30 {
        host.vt_write(format!("line {i}\r\n").as_bytes());
    }
    host.vt_write(&b"\r\n".repeat(12));
    let mut client = replay(&mut host, 20, 40);
    assert_eq!(screen(&mut client), screen(&mut host));

    host.vt_write(b"after");
    client.vt_write(b"after");
    assert_eq!(screen(&mut client), screen(&mut host));
}

/// A screen scrolled fully blank (the cursor parked below a wall of newlines)
/// is the extreme of the same case.
#[test]
fn fully_blank_scrolled_screen_replays_exactly() {
    let mut host = VtTerminal::new(10, 40).expect("host terminal");
    host.vt_write(b"only line\r\n");
    host.vt_write(&b"\r\n".repeat(15));
    let mut client = replay(&mut host, 10, 40);
    assert_eq!(screen(&mut client), screen(&mut host));

    host.vt_write(b"back");
    client.vt_write(b"back");
    assert_eq!(screen(&mut client), screen(&mut host));
}

/// A burst of bare newlines leaves several blank rows above the cursor; the
/// replay has to make up every one of those scroll steps, not just one.
#[test]
fn replayed_stream_recovers_multiple_dropped_scrolls() {
    let mut host = VtTerminal::new(10, 40).expect("host terminal");
    for i in 1..=20 {
        host.vt_write(format!("line {i}\r\n").as_bytes());
    }
    host.vt_write(b"\r\n\r\n");
    let mut client = replay(&mut host, 10, 40);
    assert_eq!(screen(&mut client), screen(&mut host));

    host.vt_write(b"after");
    client.vt_write(b"after");
    assert_eq!(screen(&mut client), screen(&mut host));
}

/// An unscrolled screen has no shortfall to make up; the payload must pass
/// through unpadded and still replay exactly.
#[test]
fn short_content_replays_without_padding() {
    let mut host = VtTerminal::new(15, 50).expect("host terminal");
    host.vt_write(b"one\r\ntwo\r\nthree\r\n");
    let mut client = replay(&mut host, 15, 50);
    assert_eq!(screen(&mut client), screen(&mut host));

    host.vt_write(b"four");
    client.vt_write(b"four");
    assert_eq!(screen(&mut client), screen(&mut host));
}

/// Pending wrap is the formatter's own restore (ghostty#13876): the payload
/// ends by reprinting the final cell, and neither the padding nor the cursor
/// re-assert may disturb it. The next character must wrap on the client
/// exactly as it does on the host.
#[test]
fn pending_wrap_restore_is_left_alone() {
    let mut host = VtTerminal::new(10, 20).expect("host terminal");
    for i in 1..=12 {
        host.vt_write(format!("row {i}\r\n").as_bytes());
    }
    host.vt_write(b"ABCDEFGHIJKLMNOPQRST"); // exactly 20 cols: cursor holds pending wrap
    let mut client = replay(&mut host, 10, 20);
    assert_eq!(screen(&mut client), screen(&mut host));

    host.vt_write(b"X");
    client.vt_write(b"X");
    assert_eq!(
        screen(&mut client),
        screen(&mut host),
        "the next character must wrap identically on both ends"
    );
}

/// An alt-screen frame (vim, top) repaints on the alternate buffer with its
/// own addressing; the replay must reproduce it and the padding must never
/// scroll it.
#[test]
fn alt_screen_replays_exactly() {
    let mut host = VtTerminal::new(10, 40).expect("host terminal");
    host.vt_write(b"shell history line\r\n");
    host.vt_write(b"\x1b[?1049h\x1b[2J\x1b[H\x1b[3;5Halt content\x1b[7;1Hstatus bar");
    let mut client = replay(&mut host, 10, 40);
    assert_eq!(screen(&mut client), screen(&mut host));
}
