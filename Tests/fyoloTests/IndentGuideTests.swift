import AppKit
import XCTest
@testable import fyolo

/// How far past the viewport the walk has to reach so a blank run still carries its block's
/// rules. Silent when wrong — the blank line just drops the rules — so it's pinned here rather
/// than judged on screen. (The indent width itself is `EditorIndentation.detected`, tested with
/// the Return/Tab behavior that shares it.)
@MainActor
final class IndentGuideScanRangeTests: XCTestCase {
    private let source = "a\n    b\n\n\n    c\n    d\n" as NSString

    /// A viewport landing on the blank run alone still reaches the indented lines bracketing it,
    /// which is where the run's rules come from.
    func testBlankRunReachesBothNeighbours() {
        let blanks = NSRange(location: 8, length: 2) // the two empty lines
        let scan = IndentGuideRenderer.scanRange(around: blanks, in: source)
        XCTAssertLessThanOrEqual(scan.location, 2)             // includes "    b"
        XCTAssertGreaterThanOrEqual(NSMaxRange(scan), 15)      // includes "    c"
    }

    /// A viewport already sitting on real code is not grown — the walk only pays for blank runs.
    func testNonBlankEdgesAreNotGrown() {
        let body = NSRange(location: 2, length: 5) // "    b"
        let scan = IndentGuideRenderer.scanRange(around: body, in: source)
        XCTAssertEqual(scan.location, 2)
        XCTAssertEqual(NSMaxRange(scan), 8)
    }

    /// The document's first and last lines have nothing beyond them; the walk must stop rather
    /// than index past either end.
    func testWholeDocumentIsClamped() {
        let scan = IndentGuideRenderer.scanRange(
            around: NSRange(location: 0, length: source.length), in: source
        )
        XCTAssertEqual(scan.location, 0)
        XCTAssertEqual(NSMaxRange(scan), source.length)
    }

    func testEmptyDocumentDoesNotRunOffTheEnd() {
        let empty = "" as NSString
        let scan = IndentGuideRenderer.scanRange(around: NSRange(location: 0, length: 0), in: empty)
        XCTAssertEqual(scan.length, 0)
    }
}

/// The rules themselves, measured off a real laid-out text view rather than judged by eye: which
/// lines get how many, where each one lands, and that a wrapped line stays one set of rules.
@MainActor
final class IndentGuideGeometryTests: XCTestCase {
    /// A monospaced text view wide enough not to wrap, laid out and scrolled to the top.
    private func textView(_ source: String, width: CGFloat = 800) -> NSTextView {
        let storage = NSTextStorage(string: source)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600),
                              textContainer: container)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        storage.addAttributes([.font: view.font ?? .systemFont(ofSize: 12)],
                              range: NSRange(location: 0, length: storage.length))
        layoutManager.ensureLayout(for: container)
        return view
    }

    /// The x each rule sits at, deduplicated and sorted — the set of indent columns on screen.
    private func columns(_ rules: [NSRect]) -> [CGFloat] {
        Array(Set(rules.map(\.minX))).sorted()
    }

    func testOneRulePerEnclosingLevel() {
        let view = textView("""
        func outer() {
            if condition {
                body()
            }
        }
        """)
        let rules = IndentGuideRenderer().rules(in: view)
        // Indents 0, 4, 8, 4, 0 → 0 + 1 + 2 + 1 + 0 rules.
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(columns(rules).count, 2)
    }

    /// The rules land on the indent columns, not between them: the second sits exactly one level
    /// to the right of the first.
    func testRulesLandOnTheIndentColumns() {
        let view = textView("""
        a:
            b:
                c()
        """)
        let columns = self.columns(IndentGuideRenderer().rules(in: view))
        XCTAssertEqual(columns.count, 2)
        guard columns.count == 2 else { return }
        let advance = ("    " as NSString)
            .size(withAttributes: [.font: view.font ?? .systemFont(ofSize: 12)]).width
        XCTAssertEqual(columns[1] - columns[0], advance, accuracy: 1)
    }

    /// The width comes from the file, not a house constant: the same nesting drawn from a
    /// two-space file puts its rules half as far apart as a four-space one.
    func testWidthFollowsTheFile() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let advance = ("  " as NSString).size(withAttributes: [.font: font]).width

        let twoSpace = columns(IndentGuideRenderer().rules(in: textView("""
        a:
          b:
            c()
        """)))
        XCTAssertEqual(twoSpace.count, 2)
        guard twoSpace.count == 2 else { return }
        XCTAssertEqual(twoSpace[1] - twoSpace[0], advance, accuracy: 1)

        // Same shape at four spaces — one level, so twice the gap.
        let fourSpace = columns(IndentGuideRenderer().rules(in: textView("""
        a:
            b:
                c()
        """)))
        XCTAssertEqual(fourSpace.count, 2)
        guard fourSpace.count == 2 else { return }
        XCTAssertEqual(fourSpace[1] - fourSpace[0], advance * 2, accuracy: 1)
    }

    /// A tab-indented file is one level per tab character, whatever width the view renders it at.
    func testTabIndentedFile() {
        let rules = IndentGuideRenderer().rules(in: textView("a:\n\tb:\n\t\tc()\n"))
        XCTAssertEqual(rules.count, 3) // one on "\tb:", two on "\t\tc()"
        XCTAssertEqual(columns(rules).count, 2)
    }

    /// A blank line inside a block keeps the block's rules; one past the end of the code does not
    /// invent any.
    func testBlankLineInsideABlockCarriesTheGuides() {
        let inside = IndentGuideRenderer().rules(in: textView("""
        a:
            b()

            c()
        """))
        XCTAssertEqual(inside.count, 3) // b(), the blank, c()

        let trailing = IndentGuideRenderer().rules(in: textView("a:\n    b()\n\n"))
        XCTAssertEqual(trailing.count, 1) // only b(); nothing past the last line of code
    }

    /// A soft-wrapped line is one logical line: its rules span every row it occupies, and no
    /// continuation row contributes rules of its own.
    func testWrappedLineDrawsOneSetOfRules() {
        let long = String(repeating: "word ", count: 60)
        let view = textView("a:\n    \(long)\n    b()\n", width: 220)
        let rules = IndentGuideRenderer().rules(in: view)
        XCTAssertEqual(rules.count, 2) // one for the wrapped line, one for b()
        guard let wrapped = rules.max(by: { $0.height < $1.height }) else { return XCTFail("no rules") }
        // The wrapped line's rule is taller than a single row, i.e. it runs down the whole block.
        XCTAssertGreaterThan(wrapped.height, view.layoutManager.map {
            $0.defaultLineHeight(for: view.font ?? .systemFont(ofSize: 12)) * 1.5
        } ?? 0)
    }

    /// Every rule is a whole number of device pixels wide and starts on a pixel boundary — the
    /// difference between a crisp hairline and a smear that shimmers while scrolling.
    func testRulesAreSnappedToDevicePixels() {
        let view = textView("""
        a:
            b:
                c()
        """)
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for rule in IndentGuideRenderer().rules(in: view) {
            XCTAssertEqual((rule.minX * scale).rounded(), rule.minX * scale, accuracy: 0.001)
            XCTAssertEqual((rule.width * scale).rounded(), rule.width * scale, accuracy: 0.001)
            XCTAssertGreaterThan(rule.width, 0)
        }
    }

    /// The indent guides and the occurrence highlight land on the same view without cancelling
    /// each other: the guides are filled in `drawBackground`, the wash is a layout-manager
    /// temporary attribute drawn over it, so neither reads or clears the other's state.
    func testCoexistsWithTheOccurrenceHighlight() {
        let view = textView("""
        a:
            value = value
                value()
        """)
        let renderer = IndentGuideRenderer()
        let before = renderer.rules(in: view)
        XCTAssertFalse(before.isEmpty)

        let text = view.string as NSString
        var occurrences: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while true {
            let hit = text.range(of: "value", options: [], range: search)
            guard hit.location != NSNotFound else { break }
            occurrences.append(hit)
            let next = NSMaxRange(hit)
            guard next < text.length else { break }
            search = NSRange(location: next, length: text.length - next)
        }
        XCTAssertGreaterThan(occurrences.count, 1)
        TextFindEngine.addHighlight(occurrences, color: .systemGray, in: view)

        // The wash is on the layout manager...
        var washed = 0
        for range in occurrences where view.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: range.location, effectiveRange: nil) != nil {
            washed += 1
        }
        XCTAssertEqual(washed, occurrences.count)
        // ...and the guides are untouched by it, in count and in position.
        XCTAssertEqual(renderer.rules(in: view), before)

        // Lifting the wash likewise leaves the guides alone.
        TextFindEngine.removeHighlight(occurrences, in: view)
        XCTAssertEqual(renderer.rules(in: view), before)
    }

    /// A file with no indentation draws nothing rather than guessing a width.
    func testFlatFileDrawsNothing() {
        XCTAssertTrue(IndentGuideRenderer().rules(in: textView("one\ntwo\nthree\n")).isEmpty)
        XCTAssertTrue(IndentGuideRenderer().rules(in: textView("")).isEmpty)
    }
}
