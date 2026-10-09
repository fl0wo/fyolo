import AppKit
import XCTest
@testable import fyolo

/// The editor's line commands: ⌘/ and the Option-arrow line moves and copies. Each case here is a
/// keystroke someone would notice getting wrong — a marker that breaks a block's shape, a move
/// that swallows the last line's newline, a copy that leaves the caret behind.
final class EditorLineCommandTests: XCTestCase {
    // MARK: Keys

    private let upArrow = String(utf16CodeUnits: [unichar(NSUpArrowFunctionKey)], count: 1)
    private let downArrow = String(utf16CodeUnits: [unichar(NSDownArrowFunctionKey)], count: 1)

    /// Arrow events carry `.function` and `.numericPad` on top of what the user is holding — the
    /// whole reason the match strips them. Reading the raw flags would leave Option-Up dead.
    func testArrowKeysMatchThroughTheirOwnModifierFlags() {
        let carried: NSEvent.ModifierFlags = [.function, .numericPad]
        XCTAssertEqual(
            EditorLineCommands.command(for: carried.union(.option), key: upArrow), .move(.up)
        )
        XCTAssertEqual(
            EditorLineCommands.command(for: carried.union(.option), key: downArrow), .move(.down)
        )
        XCTAssertEqual(
            EditorLineCommands.command(for: carried.union([.option, .shift]), key: upArrow), .copy(.up)
        )
        XCTAssertEqual(
            EditorLineCommands.command(for: carried.union([.option, .shift]), key: downArrow), .copy(.down)
        )
    }

    func testCommandSlashTogglesTheComment() {
        XCTAssertEqual(EditorLineCommands.command(for: .command, key: "/"), .toggleComment)
        // Caps Lock never changes which command was asked for.
        XCTAssertEqual(EditorLineCommands.command(for: [.command, .capsLock], key: "/"), .toggleComment)
    }

    /// Everything else falls through to AppKit: a bare arrow still navigates, and ⌃⌥ combinations
    /// are somebody else's keystroke.
    func testOtherKeystrokesAreNotLineCommands() {
        XCTAssertNil(EditorLineCommands.command(for: [.function, .numericPad], key: upArrow))
        XCTAssertNil(EditorLineCommands.command(for: [.control, .option, .function, .numericPad], key: upArrow))
        XCTAssertNil(EditorLineCommands.command(for: [.command, .shift], key: "/"))
        XCTAssertNil(EditorLineCommands.command(for: .command, key: "s"))
    }

    // MARK: Comment markers

    func testCommentMarkerComesFromTheGrammar() {
        XCTAssertEqual(EditorLineCommands.commentMarker(for: "swift"), "//")
        XCTAssertEqual(EditorLineCommands.commentMarker(for: "python"), "#")
        XCTAssertEqual(EditorLineCommands.commentMarker(for: "lua"), "--")
        XCTAssertEqual(EditorLineCommands.commentMarker(for: "clojure"), ";")
    }

    /// A language with no line comment gets no ⌘/ rather than a guessed marker: `//` in a JSON
    /// file is a syntax error, not a comment.
    func testLanguagesWithoutALineCommentHaveNoMarker() {
        XCTAssertNil(EditorLineCommands.commentMarker(for: "json"))
        XCTAssertNil(EditorLineCommands.commentMarker(for: "markdown"))
        XCTAssertNil(EditorLineCommands.commentMarker(for: "xml"))
        XCTAssertNil(EditorLineCommands.commentMarker(for: nil))
        XCTAssertNil(EditorLineCommands.commentMarker(for: "not-a-grammar"))
    }

    // MARK: Comment toggling

    func testCommentsTheCaretsOwnLineAtItsIndent() {
        let text = "    let x = 1\n" as NSString
        let edit = EditorLineCommands.toggleComment(NSRange(location: 8, length: 0), in: text, marker: "//")
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 14))
        XCTAssertEqual(edit?.replacement, "    // let x = 1\n")
        // The caret keeps its place in the code, three units further along.
        XCTAssertEqual(edit?.selection, NSRange(location: 11, length: 0))
    }

    /// The marker goes at the shallowest indent among the touched lines, not at column zero, so
    /// the block keeps the shape it had.
    func testCommentAlignsToTheShallowestIndent() {
        let text = "    one\n        two\n" as NSString
        let edit = EditorLineCommands.toggleComment(NSRange(location: 0, length: 20), in: text, marker: "//")
        XCTAssertEqual(edit?.replacement, "    // one\n    //     two\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 0, length: 26))
    }

    func testUncommentsWhenEveryTouchedLineIsCommented() {
        let text = "// one\n// two\n" as NSString
        let edit = EditorLineCommands.toggleComment(NSRange(location: 0, length: 14), in: text, marker: "//")
        XCTAssertEqual(edit?.replacement, "one\ntwo\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 0, length: 8))
    }

    /// A partly commented block finishes the job rather than flipping line by line — VS Code's
    /// rule, and the only one where two presses return the block to where it started.
    func testPartlyCommentedBlockCommentsEveryLine() {
        let text = "// one\ntwo\n" as NSString
        let edit = EditorLineCommands.toggleComment(NSRange(location: 0, length: 11), in: text, marker: "//")
        XCTAssertEqual(edit?.replacement, "// // one\n// two\n")
    }

    func testCommentSkipsBlankLinesInsideTheBlock() {
        let text = "one\n\ntwo\n" as NSString
        let edit = EditorLineCommands.toggleComment(NSRange(location: 0, length: 9), in: text, marker: "#")
        XCTAssertEqual(edit?.replacement, "# one\n\n# two\n")
    }

    /// Nothing but blank lines is the one case where they are commented: the keystroke has to do
    /// something, and this is how VS Code opens a comment on an empty line.
    func testCommentOnAnEmptyLineInsertsTheMarker() {
        let text = "\n" as NSString
        let edit = EditorLineCommands.toggleComment(NSRange(location: 0, length: 0), in: text, marker: "//")
        XCTAssertEqual(edit?.replacement, "// \n")
        XCTAssertEqual(edit?.selection, NSRange(location: 3, length: 0))
    }

    /// Commenting and uncommenting returns the buffer to exactly what it was, indentation and all.
    func testCommentRoundTrips() {
        let original = "func a() {\n    if b {\n        return\n    }\n}\n"
        let text = original as NSString
        let whole = NSRange(location: 0, length: text.length)
        guard let commented = EditorLineCommands.toggleComment(whole, in: text, marker: "//") else {
            return XCTFail("commenting produced no edit")
        }
        XCTAssertEqual(commented.replacement, "// func a() {\n//     if b {\n//         return\n//     }\n// }\n")

        let recommented = commented.replacement as NSString
        let back = EditorLineCommands.toggleComment(
            NSRange(location: 0, length: recommented.length), in: recommented, marker: "//"
        )
        XCTAssertEqual(back?.replacement, original)
    }

    /// A marker typed without its space still uncomments — the space is a courtesy on the way in,
    /// not a requirement on the way out.
    func testUncommentsAMarkerWithNoFollowingSpace() {
        let text = "#one\n#  two\n" as NSString
        let edit = EditorLineCommands.toggleComment(NSRange(location: 0, length: 12), in: text, marker: "#")
        XCTAssertEqual(edit?.replacement, "one\n two\n")
    }

    /// A selection ending exactly at a line start belongs to the line above it — the untouched
    /// line below whole-line selections must not gain a marker.
    func testCommentIgnoresTheLineAfterATrailingNewline() {
        let text = "one\ntwo\n" as NSString
        let edit = EditorLineCommands.toggleComment(NSRange(location: 0, length: 4), in: text, marker: "//")
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(edit?.replacement, "// one\n")
    }

    func testCommentOnAnEmptyBufferDoesNothing() {
        XCTAssertNil(EditorLineCommands.toggleComment(NSRange(location: 0, length: 0), in: "" as NSString, marker: "//"))
    }

    // MARK: Moving lines

    func testMoveLineDownSwapsWithTheLineBelow() {
        let text = "one\ntwo\nthree\n" as NSString
        let edit = EditorLineCommands.moveLines(NSRange(location: 1, length: 0), in: text, direction: .down)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 8))
        XCTAssertEqual(edit?.replacement, "two\none\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 5, length: 0))
    }

    func testMoveLineUpSwapsWithTheLineAbove() {
        let text = "one\ntwo\nthree\n" as NSString
        let edit = EditorLineCommands.moveLines(NSRange(location: 5, length: 0), in: text, direction: .up)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 8))
        XCTAssertEqual(edit?.replacement, "two\none\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 1, length: 0))
    }

    /// A multi-line selection travels as one block and keeps covering the same text.
    func testMoveCarriesAWholeSelection() {
        let text = "one\ntwo\nthree\n" as NSString
        let edit = EditorLineCommands.moveLines(NSRange(location: 0, length: 8), in: text, direction: .down)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 14))
        XCTAssertEqual(edit?.replacement, "three\none\ntwo\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 6, length: 8))
    }

    func testMoveStopsAtTheEndsOfTheBuffer() {
        let text = "one\ntwo\n" as NSString
        XCTAssertNil(EditorLineCommands.moveLines(NSRange(location: 0, length: 0), in: text, direction: .up))
        XCTAssertNil(EditorLineCommands.moveLines(NSRange(location: 4, length: 0), in: text, direction: .down))
        XCTAssertNil(EditorLineCommands.moveLines(NSRange(location: 0, length: 0), in: "" as NSString, direction: .down))
    }

    /// Moving past a last line that ends without a newline hands the terminator over instead of
    /// gluing the two lines together.
    func testMoveKeepsALastLineWithoutATerminator() {
        let text = "one\ntwo" as NSString
        let up = EditorLineCommands.moveLines(NSRange(location: 4, length: 0), in: text, direction: .up)
        XCTAssertEqual(up?.range, NSRange(location: 0, length: 7))
        XCTAssertEqual(up?.replacement, "two\none")
        XCTAssertEqual(up?.selection, NSRange(location: 0, length: 0))

        let down = EditorLineCommands.moveLines(NSRange(location: 0, length: 0), in: text, direction: .down)
        XCTAssertEqual(down?.range, NSRange(location: 0, length: 7))
        XCTAssertEqual(down?.replacement, "two\none")
        XCTAssertEqual(down?.selection, NSRange(location: 4, length: 0))
    }

    /// A CRLF file stays a CRLF file: the terminators travel with their lines rather than being
    /// normalized on the way through.
    func testMoveKeepsWindowsLineEndings() {
        let text = "one\r\ntwo\r\n" as NSString
        let edit = EditorLineCommands.moveLines(NSRange(location: 0, length: 0), in: text, direction: .down)
        XCTAssertEqual(edit?.replacement, "two\r\none\r\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 5, length: 0))
    }

    // MARK: Copying lines

    func testCopyLineDownLandsTheCaretOnTheNewCopy() {
        let text = "one\ntwo\n" as NSString
        let edit = EditorLineCommands.copyLines(NSRange(location: 1, length: 0), in: text, direction: .down)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(edit?.replacement, "one\none\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 5, length: 0))
    }

    /// Copying up leaves the caret where it already sits — on the upper copy — so holding the
    /// keystroke stacks copies instead of running away from them.
    func testCopyLineUpLeavesTheCaretOnTheUpperCopy() {
        let text = "one\ntwo\n" as NSString
        let edit = EditorLineCommands.copyLines(NSRange(location: 1, length: 0), in: text, direction: .up)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(edit?.replacement, "one\none\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 1, length: 0))
    }

    func testCopyDuplicatesEveryTouchedLine() {
        let text = "one\ntwo\nthree\n" as NSString
        let edit = EditorLineCommands.copyLines(NSRange(location: 0, length: 8), in: text, direction: .down)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 8))
        XCTAssertEqual(edit?.replacement, "one\ntwo\none\ntwo\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 8, length: 8))
    }

    /// Copying a last line that ends without a newline needs one between the two copies — taken
    /// from the buffer's own endings, so a CRLF file doesn't gain a lone `\n`.
    func testCopyOfALastLineWithoutATerminatorBorrowsOne() {
        let text = "one\r\ntwo" as NSString
        let edit = EditorLineCommands.copyLines(NSRange(location: 5, length: 0), in: text, direction: .down)
        XCTAssertEqual(edit?.range, NSRange(location: 5, length: 3))
        XCTAssertEqual(edit?.replacement, "two\r\ntwo")
        XCTAssertEqual(edit?.selection, NSRange(location: 10, length: 0))

        // A single-line buffer has no ending to borrow, so it gets a plain newline.
        let single = "one" as NSString
        let only = EditorLineCommands.copyLines(NSRange(location: 0, length: 0), in: single, direction: .down)
        XCTAssertEqual(only?.replacement, "one\none")
        XCTAssertEqual(only?.selection, NSRange(location: 4, length: 0))
    }

    func testCopyOnAnEmptyBufferDoesNothing() {
        XCTAssertNil(EditorLineCommands.copyLines(NSRange(location: 0, length: 0), in: "" as NSString, direction: .down))
    }
}
