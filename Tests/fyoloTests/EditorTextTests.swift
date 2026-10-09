import XCTest
@testable import fyolo

/// The editor's pure text logic: line/offset mapping and bracket pairing. These are the pieces
/// where a silent off-by-one becomes "revealed the wrong line" — cheap to pin down.
final class TextPositionsTests: XCTestCase {
    func testOffsetOfLineWalksAndClamps() {
        let text = "one\ntwo\nthree\n" as NSString
        XCTAssertEqual(TextPositions.offset(ofLine: 1, in: text), 0)
        XCTAssertEqual(TextPositions.offset(ofLine: 2, in: text), 4)
        XCTAssertEqual(TextPositions.offset(ofLine: 3, in: text), 8)
        // Past the end: clamps into the document instead of running off it.
        XCTAssertLessThan(TextPositions.offset(ofLine: 99, in: text), text.length)
    }

    /// Multi-byte content doesn't shift the mapping: `offset(ofLine:)` counts UTF-16 units, the
    /// same unit `NSTextView` selections use.
    func testOffsetOfLineCountsUTF16Units() {
        let text = "alpha\nβeta 🙂\ngamma" as NSString
        XCTAssertEqual(TextPositions.offset(ofLine: 2, in: text), 6)
        // "🙂" is a surrogate pair, so line 3 starts 8 units after line 2, not 7.
        XCTAssertEqual(TextPositions.offset(ofLine: 3, in: text), 14)
    }
}

/// The indent rules the editor's Return, Tab and Shift-Tab keys run on. Every case here is a
/// keystroke someone would notice getting wrong: a caret landing at column zero, a Tab wiping a
/// selection, an outdent eating a line's first character.
final class EditorIndentationTests: XCTestCase {
    private let fourSpaces = EditorIndentation.Unit(usesTabs: false, width: 4)

    // MARK: Detection

    func testDetectsWidthFromExistingIndentation() {
        let twoSpace = "class A {\n  func b() {\n    return\n  }\n}\n" as NSString
        XCTAssertEqual(EditorIndentation.detected(in: twoSpace), EditorIndentation.Unit(usesTabs: false, width: 2))

        let fourSpace = "def a():\n    if b:\n        return\n    return\n" as NSString
        XCTAssertEqual(EditorIndentation.detected(in: fourSpace), EditorIndentation.Unit(usesTabs: false, width: 4))
    }

    func testDetectsTabIndentation() {
        let tabbed = "func main() {\n\tif x {\n\t\treturn\n\t}\n}\n" as NSString
        XCTAssertEqual(EditorIndentation.detected(in: tabbed), EditorIndentation.Unit(usesTabs: true, width: 4))
        XCTAssertEqual(EditorIndentation.detected(in: tabbed).text, "\t")
    }

    /// Nothing to learn from: a flat file, an empty one, and blank lines that must not read as a
    /// jump back to column zero.
    func testDetectionFallsBackToFourSpaces() {
        XCTAssertEqual(EditorIndentation.detected(in: "" as NSString).width, EditorIndentation.fallbackWidth)
        XCTAssertEqual(EditorIndentation.detected(in: "one\ntwo\n" as NSString).width, EditorIndentation.fallbackWidth)
        XCTAssertFalse(EditorIndentation.detected(in: "one\ntwo\n" as NSString).usesTabs)

        let blankSeparated = "a:\n  b\n\n  c\n\n  d\n" as NSString
        XCTAssertEqual(EditorIndentation.detected(in: blankSeparated).width, 2)
    }

    // MARK: Return

    func testNewlineKeepsThePreviousIndentation() {
        let text = "    let x = 1\n" as NSString
        let insertion = EditorIndentation.newlineInsertion(
            at: NSRange(location: 13, length: 0), in: text, unit: fourSpaces
        )
        XCTAssertEqual(insertion, "\n    ")
    }

    func testNewlineAfterAnOpeningBraceAddsOneLevel() {
        let text = "  if x {" as NSString
        let twoSpaces = EditorIndentation.Unit(usesTabs: false, width: 2)
        XCTAssertEqual(
            EditorIndentation.newlineInsertion(at: NSRange(location: 8, length: 0), in: text, unit: twoSpaces),
            "\n    "
        )
        // Trailing whitespace after the brace doesn't hide it.
        let spaced = "func a() {  " as NSString
        XCTAssertEqual(
            EditorIndentation.newlineInsertion(at: NSRange(location: 12, length: 0), in: spaced, unit: fourSpaces),
            "\n    "
        )
    }

    /// Only the text left of the caret opens a block — Return placed before the brace stays at
    /// the line's own level.
    func testNewlineBeforeTheBraceDoesNotIndent() {
        let text = "    func a() {" as NSString
        XCTAssertEqual(
            EditorIndentation.newlineInsertion(at: NSRange(location: 13, length: 0), in: text, unit: fourSpaces),
            "\n    "
        )
    }

    func testNewlineInsideLeadingWhitespaceCarriesOnlyWhatIsBehindTheCaret() {
        let text = "        deep\n" as NSString
        XCTAssertEqual(
            EditorIndentation.newlineInsertion(at: NSRange(location: 4, length: 0), in: text, unit: fourSpaces),
            "\n    "
        )
        XCTAssertEqual(
            EditorIndentation.newlineInsertion(at: NSRange(location: 0, length: 0), in: "" as NSString, unit: fourSpaces),
            "\n"
        )
    }

    /// Return over a selection indents from the line the selection starts on.
    func testNewlineOverASelectionUsesTheStartingLine() {
        let text = "    one\n    two\n" as NSString
        XCTAssertEqual(
            EditorIndentation.newlineInsertion(at: NSRange(location: 7, length: 4), in: text, unit: fourSpaces),
            "\n    "
        )
    }

    // MARK: Tab

    func testSpansLinesOnlyWhenTheSelectionCrossesABreak() {
        let text = "one\ntwo\nthree\n" as NSString
        XCTAssertFalse(EditorIndentation.spansLines(NSRange(location: 0, length: 0), in: text))
        XCTAssertFalse(EditorIndentation.spansLines(NSRange(location: 0, length: 3), in: text))
        XCTAssertTrue(EditorIndentation.spansLines(NSRange(location: 0, length: 4), in: text))
        XCTAssertTrue(EditorIndentation.spansLines(NSRange(location: 2, length: 4), in: text))
    }

    func testIndentShiftsEveryTouchedLineAndCarriesTheSelection() {
        let text = "one\ntwo\nthree\n" as NSString
        let edit = EditorIndentation.indent(NSRange(location: 0, length: 7), in: text, unit: fourSpaces)
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 8))
        XCTAssertEqual(edit.replacement, "    one\n    two\n")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 15))
    }

    /// A selection ending exactly at a line start belongs to the line above it — the untouched
    /// line below full-line selections must not move.
    func testIndentIgnoresTheLineAfterATrailingNewline() {
        let text = "one\ntwo\nthree\n" as NSString
        let edit = EditorIndentation.indent(NSRange(location: 0, length: 4), in: text, unit: fourSpaces)
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(edit.replacement, "    one\n")
    }

    func testIndentLeavesBlankLinesEmpty() {
        let text = "one\n\ntwo\n" as NSString
        let edit = EditorIndentation.indent(NSRange(location: 0, length: 8), in: text, unit: fourSpaces)
        XCTAssertEqual(edit.replacement, "    one\n\n    two\n")
    }

    func testIndentUsesTabsWhenTheFileDoes() {
        let text = "\tone\n\ttwo\n" as NSString
        let edit = EditorIndentation.indent(
            NSRange(location: 0, length: text.length), in: text, unit: EditorIndentation.detected(in: text)
        )
        XCTAssertEqual(edit.replacement, "\t\tone\n\t\ttwo\n")
    }

    // MARK: Shift-Tab

    func testOutdentStripsOneLevelPerLine() {
        let text = "    one\n    two\n" as NSString
        let edit = EditorIndentation.outdent(NSRange(location: 0, length: 16), in: text, unit: fourSpaces)
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 16))
        XCTAssertEqual(edit.replacement, "one\ntwo\n")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 8))
    }

    /// Shift-Tab with no selection outdents the caret's own line, and the caret rides along.
    func testOutdentWithoutASelectionMovesTheCaret() {
        let text = "        deep\n" as NSString
        let edit = EditorIndentation.outdent(NSRange(location: 9, length: 0), in: text, unit: fourSpaces)
        XCTAssertEqual(edit.replacement, "    deep\n")
        XCTAssertEqual(edit.selection, NSRange(location: 5, length: 0))
    }

    /// A caret inside the whitespace being removed lands at the line's start, never before it.
    func testOutdentClampsACaretInsideTheRemovedWhitespace() {
        let text = "    x\n" as NSString
        let edit = EditorIndentation.outdent(NSRange(location: 2, length: 0), in: text, unit: fourSpaces)
        XCTAssertEqual(edit.replacement, "x\n")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 0))
    }

    func testOutdentNeverEatsContent() {
        let text = "one\ntwo\n" as NSString
        let edit = EditorIndentation.outdent(NSRange(location: 0, length: 8), in: text, unit: fourSpaces)
        XCTAssertEqual(edit.replacement, "one\ntwo\n")

        // A half-indented line snaps to column zero rather than staying odd.
        let partial = "  x\n" as NSString
        XCTAssertEqual(
            EditorIndentation.outdent(NSRange(location: 0, length: 4), in: partial, unit: fourSpaces).replacement,
            "x\n"
        )
    }

    func testOutdentTakesOneTabWhateverTheWidth() {
        let text = "\t\tx\n" as NSString
        let edit = EditorIndentation.outdent(
            NSRange(location: 0, length: 4), in: text, unit: EditorIndentation.Unit(usesTabs: true, width: 4)
        )
        XCTAssertEqual(edit.replacement, "\tx\n")
    }

    /// Indent then outdent is the identity — a Tab the user immediately regrets leaves no trace.
    func testIndentThenOutdentRoundTrips() {
        let text = "def a():\n    if b:\n        return\n" as NSString
        let unit = EditorIndentation.detected(in: text)
        let indented = EditorIndentation.indent(NSRange(location: 0, length: text.length), in: text, unit: unit)
        let rewritten = indented.replacement as NSString
        let outdented = EditorIndentation.outdent(
            NSRange(location: 0, length: rewritten.length), in: rewritten, unit: unit
        )
        XCTAssertEqual(outdented.replacement, text as String)
    }
}

final class BracketMatcherTests: XCTestCase {
    func testSimplePair() {
        let text = "f(x)" as NSString
        XCTAssertEqual(BracketMatcher.match(at: 1, in: text), 3)
        XCTAssertEqual(BracketMatcher.match(at: 3, in: text), 1)
    }

    func testNestedPairsSkipInnerLevels() {
        let text = "{ a: [1, (2)], b: {} }" as NSString
        XCTAssertEqual(BracketMatcher.match(at: 0, in: text), 21)
        XCTAssertEqual(BracketMatcher.match(at: 5, in: text), 12) // [ … ]
        XCTAssertEqual(BracketMatcher.match(at: 9, in: text), 11) // ( … )
    }

    func testEachKindCountsOnlyItself() {
        // Interleaved kinds: the scanner tracks one pair-kind at a time (the standard
        // lightweight-editor behavior — strict cross-kind nesting would need a full parser
        // and get fooled by brackets in strings far more often than this does).
        let text = "([)]" as NSString
        XCTAssertEqual(BracketMatcher.match(at: 0, in: text), 2) // ( … )
        XCTAssertEqual(BracketMatcher.match(at: 1, in: text), 3) // [ … ]
    }

    func testUnbalancedReturnsNil() {
        let text = "((a)" as NSString
        XCTAssertNil(BracketMatcher.match(at: 0, in: text))
        XCTAssertEqual(BracketMatcher.match(at: 1, in: text), 3)
    }

    func testNonBracketAndOutOfBounds() {
        let text = "abc" as NSString
        XCTAssertNil(BracketMatcher.match(at: 1, in: text))
        XCTAssertNil(BracketMatcher.match(at: -1, in: text))
        XCTAssertNil(BracketMatcher.match(at: 3, in: text))
    }
}

/// Which selections the occurrence wash chases. The wash itself needs a laid-out text view, but
/// what it decides to look for is pure — and every rule here is one that, wrong, paints the
/// document at rest.
final class OccurrenceTargetTests: XCTestCase {
    private let source = "let total = count + total\nlet other = total" as NSString

    private func target(_ selection: NSRange) -> OccurrenceTarget? {
        OccurrenceTarget.resolve(selection: selection, in: source)
    }

    /// A double-click selects the word, and the whole word is what gets chased.
    func testSelectedWordIsChasedWholeWord() {
        let selected = target(NSRange(location: 4, length: 5)) // "total"
        XCTAssertEqual(selected?.text, "total")
        XCTAssertEqual(selected?.range, NSRange(location: 4, length: 5))
        XCTAssertEqual(selected?.wholeWord, true)
    }

    /// Placing the caret is not asking a question. Without a language service there is nothing that
    /// knows the symbol under it, and washing the document on a click was noise.
    func testBareCaretHasNoTarget() {
        XCTAssertNil(target(NSRange(location: 6, length: 0))) // inside "total"
        XCTAssertNil(target(NSRange(location: 4, length: 0))) // at its leading edge
        XCTAssertNil(target(NSRange(location: 9, length: 0))) // at its trailing edge
        XCTAssertNil(target(NSRange(location: 10, length: 0))) // on "="
    }

    func testSelectionSpanningLinesIsSkipped() {
        XCTAssertNil(target(NSRange(location: 20, length: 10)))
    }

    func testWhitespaceOnlySelectionIsSkipped() {
        XCTAssertNil(target(NSRange(location: 3, length: 1)))
    }

    func testOversizedSelectionIsSkipped() {
        let long = String(repeating: "a", count: OccurrenceTarget.maximumSelectionLength + 1) as NSString
        XCTAssertNil(OccurrenceTarget.resolve(
            selection: NSRange(location: 0, length: long.length), in: long))
    }

    /// A partial selection matches literally: selecting `tot` must not light up every `total`.
    func testPartialSelectionDropsTheWordBound() {
        let partial = target(NSRange(location: 4, length: 3))
        XCTAssertEqual(partial?.text, "tot")
        XCTAssertEqual(partial?.wholeWord, false)
    }

    /// Word scanning walks UTF-16 units, the unit `NSTextView` selections speak — a caret past an
    /// astral character must not read a surrogate half as a letter and swallow the neighbors.
    func testSurrogatePairsBoundAWord() {
        let text = "a🙂name" as NSString
        XCTAssertEqual(OccurrenceTarget.wordRange(at: 5, in: text), NSRange(location: 3, length: 4))
    }
}
