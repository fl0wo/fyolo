//! What a resize does to a full-screen TUI's canvas, as opposed to flowing text.
//!
//! The resize policy was chosen by asking what the foreground process was
//! called: a shell got a truncating resize to protect its prompt redisplay,
//! everything else got rewrapped, on the reasoning that "an agent TUI, an
//! editor, a pager all repaint from their own model". These tests exist because
//! that reasoning is wrong. Repainting from your own model *is* width-relative
//! arithmetic the moment you walk the cursor back over the rows you drew, and
//! every full-screen TUI does exactly that.

use fyolod_vt::VtTerminal;

/// A TUI's input box, drawn the way an agent draws one: a rule, a prompt row, a
/// rule, each explicitly positioned. Not flowing text.
fn draw_box(vt: &mut VtTerminal, cols: usize) {
    let rule: String = "─".repeat(cols);
    vt.vt_write(b"\x1b[2J\x1b[H");
    vt.vt_write(format!("\x1b[1;1H{rule}").as_bytes());
    vt.vt_write(b"\x1b[2;1H\xe2\x9d\xaf ");
    vt.vt_write(format!("\x1b[3;1H{rule}").as_bytes());
}

/// What a full-screen TUI does when it answers SIGWINCH: walk the cursor back
/// up over the rows it believes it drew, erase from there down, redraw. The row
/// count comes from the app's own model of the screen — a model of the width it
/// drew at, not of what the terminal has done to those rows since.
fn child_winch_redraw(vt: &mut VtTerminal, own_rows: usize, cols: usize) {
    vt.vt_write(format!("\x1b[{own_rows}A").as_bytes());
    vt.vt_write(b"\r\x1b[J");
    let rule: String = "─".repeat(cols);
    vt.vt_write(format!("{rule}\r\n").as_bytes());
    vt.vt_write(b"\xe2\x9d\xaf \r\n");
    vt.vt_write(rule.as_bytes());
}

/// Resizing alone does not damage the canvas, at any granularity. Both a coarse
/// jump and a real drag's one-column-at-a-time walk come back whole.
///
/// Worth pinning because it bounds the blame: whatever the artifact is, it is
/// not the reflow arithmetic on its own.
#[test]
fn resizing_alone_leaves_the_canvas_whole() {
    for steps in [vec![63u16, 55, 62, 72, 74], {
        let mut walk: Vec<u16> = (55..74).rev().collect();
        walk.extend(56..=74);
        walk
    }] {
        let mut vt = VtTerminal::new(24, 74).expect("new");
        draw_box(&mut vt, 74);
        for cols in steps {
            vt.resize_reflowing(24, cols).expect("resize");
        }
        let text = vt.screen_text().expect("text");
        let rules: Vec<usize> = text
            .lines()
            .filter(|line| line.starts_with('─'))
            .map(|line| line.chars().count())
            .collect();
        assert_eq!(rules, vec![74, 74], "got rows: {:?}", text.lines().take(4).collect::<Vec<_>>());
    }
}

/// The damage needs the child. Reflow rewraps a 74-column rule at 55 into two
/// physical rows, so the box now occupies more rows than the app drew. The app
/// walks back up by *its* count, erases from there, and the rows above that
/// anchor survive — it never knew it had them.
///
/// On screen: a stray rule stub and an orphaned prompt glyph above a correctly
/// drawn box. That is the ⌘D duplicate-prompt bug arriving through the door the
/// shell check left open for everything that is not a shell.
#[test]
#[ignore = "documents the open defect: reflow strands rows the child cannot erase"]
fn a_reflowing_resize_strands_the_rows_the_child_does_not_know_it_has() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    vt.vt_write(b"\x1b[?7h");
    draw_box(&mut vt, 74);
    vt.resize_reflowing(24, 55).expect("resize");
    child_winch_redraw(&mut vt, 2, 55);
    let text = vt.screen_text().expect("text");
    let rules = text.lines().filter(|line| line.starts_with('─')).count();
    assert_eq!(rules, 2, "expected the two rules the child drew, got: {text}");
}

/// The control, and the shape of the answer: with no reflow the rows stay where
/// the app left them, so its walk back up lands where it meant to. This passes
/// today, which is what makes the test above a policy question rather than an
/// engine bug.
#[test]
fn a_truncating_resize_leaves_the_child_s_arithmetic_intact() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    vt.vt_write(b"\x1b[?7h");
    draw_box(&mut vt, 74);
    vt.resize(24, 55).expect("resize");
    child_winch_redraw(&mut vt, 2, 55);
    let text = vt.screen_text().expect("text");
    let rules = text.lines().filter(|line| line.starts_with('─')).count();
    assert_eq!(rules, 2, "expected the two rules the child drew, got: {text}");
}
