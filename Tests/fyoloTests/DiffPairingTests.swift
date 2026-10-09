import FyoloShared
import AppKit
import XCTest
@testable import fyolo

/// Pairing the folded diff into side-by-side rows: which line ends up in which column, and what
/// happens where the two sides do not have the same number of lines. The rows below a change only
/// stay in step across the two panes if every pair produces exactly one row per column, so the
/// padded cases (a pure addition, a block with more deletions than additions) are the ones with
/// real failure modes — a dropped side would shift every line under it.
final class DiffPairingTests: XCTestCase {
    private let palette = DiffPalette(
        background: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1), isDark: true)

    private func pairs(_ diff: String) -> [DiffPairing.Pair] {
        DiffPairing.pairs(of: DiffParser.displayItems(lines: DiffParser.lines(from: diff),
                                                      expansion: DiffExpansion()))
    }

    /// The text of a pair's side, or nil where that side has nothing.
    private func text(_ item: DiffItem?) -> String? {
        guard case .line(let row) = item else { return nil }
        return row.text
    }

    func testReplacementPairsTheDeletedLineWithTheAddedOne() {
        let pairs = pairs("@@ -1,1 +1,1 @@\n-old\n+new\n")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(text(pairs[0].left), "old")
        XCTAssertEqual(text(pairs[0].right), "new")
    }

    /// A new file has no old side at all: every row hangs on the right, and the left column is
    /// padding.
    func testPureAdditionLeavesTheLeftColumnEmpty() {
        let pairs = pairs("@@ -0,0 +1,2 @@\n+first\n+second\n")
        XCTAssertEqual(pairs.count, 2)
        XCTAssertNil(pairs[0].left)
        XCTAssertNil(pairs[1].left)
        XCTAssertEqual(text(pairs[0].right), "first")
        XCTAssertEqual(text(pairs[1].right), "second")
    }

    func testPureDeletionLeavesTheRightColumnEmpty() {
        let pairs = pairs("@@ -1,2 +0,0 @@\n-first\n-second\n")
        XCTAssertEqual(pairs.count, 2)
        XCTAssertNil(pairs[0].right)
        XCTAssertNil(pairs[1].right)
        XCTAssertEqual(text(pairs[0].left), "first")
        XCTAssertEqual(text(pairs[1].left), "second")
    }

    /// Three lines replaced by one: the extra deletions keep their own rows with an empty right
    /// column, rather than collapsing the block to one row and shifting everything below it.
    func testUnequalBlockPadsTheShorterSide() {
        let pairs = pairs("@@ -1,3 +1,1 @@\n-old1\n-old2\n-old3\n+new1\n")
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(text(pairs[0].left), "old1")
        XCTAssertEqual(text(pairs[0].right), "new1")
        XCTAssertEqual(text(pairs[1].left), "old2")
        XCTAssertNil(pairs[1].right)
        XCTAssertEqual(text(pairs[2].left), "old3")
        XCTAssertNil(pairs[2].right)
    }

    func testOneAdditionOverThreeDeletionsPadsTheLeftSide() {
        let pairs = pairs("@@ -1,1 +1,3 @@\n-old\n+new1\n+new2\n+new3\n")
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(text(pairs[0].left), "old")
        XCTAssertEqual(text(pairs[0].right), "new1")
        XCTAssertNil(pairs[1].left)
        XCTAssertEqual(text(pairs[1].right), "new2")
        XCTAssertNil(pairs[2].left)
        XCTAssertEqual(text(pairs[2].right), "new3")
    }

    /// Two change blocks with context between them must not be paired across the context — the
    /// first block's deletion never faces the second block's addition.
    func testChangeBlocksSeparatedByContextPairWithinThemselves() {
        let pairs = pairs("""
        @@ -1,4 +1,4 @@
        -alpha
        +ALPHA
         shared
        -beta
        +BETA
        """)
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(text(pairs[0].left), "alpha")
        XCTAssertEqual(text(pairs[0].right), "ALPHA")
        XCTAssertEqual(text(pairs[1].left), "shared")
        XCTAssertEqual(text(pairs[1].right), "shared")
        XCTAssertEqual(text(pairs[2].left), "beta")
        XCTAssertEqual(text(pairs[2].right), "BETA")
    }

    func testContextOnlyHunkPairsEveryLineWithItself() {
        let pairs = pairs("@@ -1,2 +1,2 @@\n one\n two\n")
        XCTAssertEqual(pairs.count, 2)
        for pair in pairs {
            guard case .line(let left) = pair.left, case .line(let right) = pair.right else {
                return XCTFail("a context line belongs to both columns")
            }
            XCTAssertEqual(left.text, right.text)
            XCTAssertEqual(left.id, right.id)
        }
    }

    /// A folded run is unchanged on both sides, so it becomes one band on both — the same anchor
    /// and range, which is what lets a click in either column reveal the same lines in both.
    func testFoldedRunBecomesTheSameBandOnBothSides() {
        var diff = "@@ -1,1 +1,1 @@\n-old\n+new\n"
        for number in 1...30 { diff += " unchanged \(number)\n" }
        let pairs = pairs(diff)
        let bands = pairs.filter { pair in
            if case .band = pair.left { return true }
            return false
        }
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands[0].left, bands[0].right,
                       "both columns fold the same run at the same anchor")
    }

    /// Each column keeps the add/delete semantics of its own side, so a split row washes the
    /// same way the inline row beside it does: red on the old side, green on the new.
    func testEachColumnKeepsItsOwnWashRole() {
        let pair = splitPair("@@ -1,1 +1,1 @@\n-old\n+new\n")
        XCTAssertEqual(pair.left.lines[0].role, .code(.deletion))
        XCTAssertEqual(pair.right.lines[0].role, .code(.addition))
        XCTAssertNotNil(palette.wash(for: pair.left.lines[0].role))
        XCTAssertNotNil(palette.wash(for: pair.right.lines[0].role))
    }

    /// The padding a one-sided row leaves behind is an ordinary empty line: no wash, no numbers,
    /// and no sign — a filler that tinted itself would read as a change that never happened.
    func testPaddingRowsAreInert() {
        let pair = splitPair("@@ -0,0 +1,2 @@\n+first\n+second\n")
        XCTAssertEqual(pair.left.lines.count, 2)
        for line in pair.left.lines {
            XCTAssertEqual(line.role, .code(.context))
            XCTAssertNil(palette.wash(for: line.role), "a filler draws nothing")
            XCTAssertNil(palette.gutterFill(for: line.role))
            XCTAssertNil(line.oldLine)
            XCTAssertNil(line.newLine)
        }
    }

    /// The inline document is built by the same assembly with no pairing, so its paragraphs and
    /// their ranges have to come out exactly as they always did: contiguous, one per rendered
    /// element, in order.
    func testInlineDocumentLaysOutOneParagraphPerElementInOrder() {
        let diff = """
        @@ -1,2 +1,2 @@
        -gone
        +added
         kept
        """
        let inline = DiffDocument.build(
            rows: rows(diff), expansion: DiffExpansion(), palette: palette,
            codeFont: .monospacedSystemFont(ofSize: 12, weight: .regular), lineSpacing: 0)
        XCTAssertEqual(inline.lines.count, 3)
        let content = inline.attributed.string as NSString
        var location = 0
        for line in inline.lines {
            XCTAssertEqual(line.range.location, location, "paragraphs are laid down in order")
            location = NSMaxRange(line.range)
        }
        XCTAssertEqual(location, content.length)
        XCTAssertEqual(content.substring(with: inline.lines[0].range), "gone\n")
        XCTAssertEqual(content.substring(with: inline.lines[2].range), "kept\n")
        // The inline pane keeps both numbers on a line, which is what its two-column gutter shows:
        // a deletion carries only the old number, an addition only the new one, context both.
        XCTAssertEqual(inline.lines[0].oldLine, 1)
        XCTAssertNil(inline.lines[0].newLine)
        XCTAssertNil(inline.lines[1].oldLine)
        XCTAssertEqual(inline.lines[1].newLine, 1)
        XCTAssertEqual(inline.lines[2].oldLine, 2)
        XCTAssertEqual(inline.lines[2].newLine, 2)
    }

    // MARK: Documents

    private func rows(_ diff: String) -> [DiffRow] { DiffParser.lines(from: diff) }

    private func splitPair(_ diff: String) -> DiffDocument.SplitPair {
        DiffDocument.buildSplitPair(rows: rows(diff), expansion: DiffExpansion(), palette: palette,
                                    codeFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                    lineSpacing: 0)
    }

    /// The two columns are the same height or nothing lines up: every pair, including the padded
    /// ones, has to leave exactly one paragraph per column.
    func testBothColumnsCarryTheSameNumberOfParagraphs() {        let pair = splitPair("""
        @@ -1,3 +1,2 @@
        -gone
        -also gone
         kept
        +added
        +and added
        """)
        XCTAssertEqual(pair.left.lines.count, pair.right.lines.count)
        XCTAssertEqual(pair.left.lines.filter(\.isBand).count,
                       pair.right.lines.filter(\.isBand).count,
                       "a band sits at the same row in both columns")
    }

    /// Each column is numbered by the file it shows, so a column's rows carry only its own
    /// numbers — the old side the old numbers, the new side the new ones.
    func testEachColumnKeepsOnlyItsOwnLineNumbers() {
        let pair = splitPair("@@ -1,1 +1,1 @@\n-old\n+new\n")
        XCTAssertEqual(pair.left.hasOldGutter, true)
        XCTAssertEqual(pair.left.hasNewGutter, false)
        XCTAssertEqual(pair.right.hasOldGutter, false)
        XCTAssertEqual(pair.right.hasNewGutter, true)
        XCTAssertEqual(pair.left.lines[0].oldLine, 1)
        XCTAssertNil(pair.left.lines[0].newLine)
        XCTAssertNil(pair.right.lines[0].oldLine)
        XCTAssertEqual(pair.right.lines[0].newLine, 1)
    }

    /// The old column always gets a slot of its own even when it has no numbers to put in it,
    /// and both slots are the same width — otherwise a new file's old column would collapse and
    /// the two code columns would start at different x.
    func testBothGuttersReserveTheSameWidth() {
        let pair = splitPair("@@ -0,0 +1,2 @@\n+first\n+second\n")
        XCTAssertFalse(pair.left.hasOldGutter, "a new file has no old numbers to show")
        XCTAssertTrue(pair.right.hasNewGutter)
        XCTAssertEqual(pair.left.maxLineNumber, pair.right.maxLineNumber)
        XCTAssertEqual(pair.lineNumberDigits, 2, "the shared width still reserves the two-digit floor")
        XCTAssertEqual(DiffGutterMetrics.side(true, digits: pair.lineNumberDigits).digits,
                       DiffGutterMetrics.side(false, digits: pair.lineNumberDigits).digits)
        XCTAssertFalse(DiffGutterMetrics.side(true, digits: 2).showsNewColumn,
                       "the old column does not repeat the new numbers beside them")
    }

    /// Delete and add blocks keep their intraline emphasis through pairing: the spans stay on the
    /// row they were word-diffed against, which is the row now facing it.
    func testEmphasisSurvivesIntoTheColumnBesideIt() {
        let pair = splitPair("@@ -1,1 +1,1 @@\n-let value = 1\n+let value = 2\n")
        XCTAssertFalse(emphasisSpans(of: pair.left).isEmpty,
                       "the changed word is marked on the old side")
        XCTAssertFalse(emphasisSpans(of: pair.right).isEmpty,
                       "and on the new side")
    }

    /// The emphasized character ranges in a document's attributed string.
    private func emphasisSpans(of document: DiffDocument) -> [NSRange] {
        var spans: [NSRange] = []
        document.attributed.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: document.attributed.length)
        ) { value, range, _ in
            if value != nil { spans.append(range) }
        }
        return spans
    }
}
