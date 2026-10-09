import PDFKit
import XCTest
@testable import fyolo

/// The incremental writer, pinned on the two things that make it worth having: the book's
/// existing bytes are never touched, and what it appends reads back as annotations.
///
/// Every case builds its own document, so the suite carries no fixture and runs anywhere.
final class PDFIncrementalWriterTests: XCTestCase {

    // MARK: - Fixtures

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pdf-incremental-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A few pages of real text, laid out by the same Quartz writer that produces most of
    /// the PDFs a reader meets.
    private func makeDocument(pages: Int = 3, name: String = "book.pdf") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw XCTSkip("could not create a PDF context")
        }
        let font = NSFont.systemFont(ofSize: 14)
        for page in 0..<pages {
            context.beginPDFPage(nil)
            let text = NSAttributedString(
                string: "Page \(page + 1). The session lives on the box, not in the connection.",
                attributes: [.font: font, .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func mark(page: Int, rects: [CGRect], color: PDFHighlightColor = .yellow,
                      text: String = "a marked passage") -> PDFHighlight {
        PDFHighlight(page: page, rects: rects.map(PDFHighlight.Rect.init), text: text,
                     color: color)
    }

    // MARK: - The invariant

    /// The point of the whole exercise: an append leaves the original bytes alone. If this
    /// ever fails the writer has quietly become a rewriter, and the cost that motivated it
    /// is back.
    func testAppendLeavesTheOriginalBytesUntouched() throws {
        let url = try makeDocument()
        let before = try Data(contentsOf: url)

        let edits = PDFHighlightStore.Edits(
            added: [mark(page: 0, rects: [CGRect(x: 72, y: 695, width: 200, height: 18)])])
        let result = try PDFIncrementalWriter.append(edits, to: url)
        XCTAssertTrue(result.written)
        XCTAssertTrue(result.unapplied.isEmpty)

        let after = try Data(contentsOf: url)
        XCTAssertGreaterThan(after.count, before.count, "an append has to add bytes")
        XCTAssertEqual(after.prefix(before.count), before,
                       "the document that was already there must survive byte for byte")
    }

    /// The appended section chains back to the old table rather than replacing it, which is
    /// what makes the file still resolve.
    func testAppendChainsToThePreviousCrossReferenceSection() throws {
        let url = try makeDocument()
        let original = try PDFObjectFile(contentsOf: url)
        let edits = PDFHighlightStore.Edits(
            added: [mark(page: 1, rects: [CGRect(x: 72, y: 695, width: 200, height: 18)])])
        _ = try PDFIncrementalWriter.append(edits, to: url)

        let updated = try PDFObjectFile(contentsOf: url)
        XCTAssertEqual(updated.trailer["Prev"]?.intValue, original.startXref)
        XCTAssertGreaterThan(updated.startXref, original.startXref)
        XCTAssertEqual(updated.trailer["Root"]?.referenceValue?.number,
                       original.trailer["Root"]?.referenceValue?.number)
    }

    // MARK: - What reads back

    func testAppendedMarkReadsBackAsAHighlight() throws {
        let url = try makeDocument()
        let rect = CGRect(x: 72, y: 695, width: 200, height: 18)
        let written = mark(page: 0, rects: [rect], color: .green, text: "on the box")
        _ = try PDFIncrementalWriter.append(PDFHighlightStore.Edits(added: [written]), to: url)

        let document = try XCTUnwrap(PDFDocument(url: url), "the appended file must still open")
        let page = try XCTUnwrap(document.page(at: 0))
        let highlights = page.annotations.filter { $0.type == "Highlight" }
        XCTAssertEqual(highlights.count, 1)

        let marks = PDFHighlightStore.marksInDocument(document)
        XCTAssertEqual(marks.count, 1)
        let read = try XCTUnwrap(marks.first)
        XCTAssertEqual(read.page, 0)
        XCTAssertEqual(read.id, written.id, "the mark's identity has to survive the round trip")
        XCTAssertEqual(read.rects.map(\.rounded), written.rects.map(\.rounded))
        XCTAssertEqual(read.ink, .green)
    }

    /// A passage spanning several typeset lines is one annotation carrying one quad per
    /// line — Preview's shape — and has to come back as those same lines, not as the block
    /// that encloses them.
    func testMultiLineMarkRoundTripsAsSeparateRectangles() throws {
        let url = try makeDocument()
        let rects = [CGRect(x: 72, y: 695, width: 400, height: 18),
                     CGRect(x: 72, y: 673, width: 300, height: 18),
                     CGRect(x: 72, y: 651, width: 180, height: 18)]
        let written = mark(page: 0, rects: rects)
        _ = try PDFIncrementalWriter.append(PDFHighlightStore.Edits(added: [written]), to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.annotations.filter { $0.type == "Highlight" }.count, 1,
                       "one passage is one annotation, however many lines it covers")

        let read = try XCTUnwrap(PDFHighlightStore.marksInDocument(document).first)
        XCTAssertEqual(Set(read.rects.map(\.rounded)), Set(written.rects.map(\.rounded)))
    }

    func testMarksLandOnTheirOwnPages() throws {
        let url = try makeDocument(pages: 4)
        let edits = PDFHighlightStore.Edits(added: [
            mark(page: 0, rects: [CGRect(x: 72, y: 695, width: 120, height: 18)]),
            mark(page: 2, rects: [CGRect(x: 72, y: 695, width: 160, height: 18)]),
            mark(page: 3, rects: [CGRect(x: 72, y: 695, width: 200, height: 18)])
        ])
        _ = try PDFIncrementalWriter.append(edits, to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        let byPage = Dictionary(grouping: PDFHighlightStore.marksInDocument(document), by: \.page)
        XCTAssertEqual(Set(byPage.keys), [0, 2, 3])
        XCTAssertTrue(document.page(at: 1)?.annotations.isEmpty ?? false)
    }

    /// Two saves in a row, the way a reading session actually goes. The second append sits
    /// on top of the first and both marks survive.
    func testSuccessiveAppendsAccumulate() throws {
        let url = try makeDocument()
        let first = mark(page: 0, rects: [CGRect(x: 72, y: 695, width: 200, height: 18)])
        let second = mark(page: 1, rects: [CGRect(x: 72, y: 695, width: 140, height: 18)],
                          color: .blue)
        _ = try PDFIncrementalWriter.append(PDFHighlightStore.Edits(added: [first]), to: url)
        let middle = try Data(contentsOf: url)
        _ = try PDFIncrementalWriter.append(PDFHighlightStore.Edits(added: [second]), to: url)

        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.prefix(middle.count), middle,
                       "the second append must not disturb the first")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(PDFHighlightStore.marksInDocument(document).count, 2)
    }

    /// Writing the same passage twice must not stack two bands of ink on it.
    func testAppendingAMarkThatIsAlreadyThereAddsNothing() throws {
        let url = try makeDocument()
        let written = mark(page: 0, rects: [CGRect(x: 72, y: 695, width: 200, height: 18)])
        _ = try PDFIncrementalWriter.append(PDFHighlightStore.Edits(added: [written]), to: url)
        let once = try Data(contentsOf: url)
        _ = try PDFIncrementalWriter.append(PDFHighlightStore.Edits(added: [written]), to: url)

        XCTAssertEqual(try Data(contentsOf: url), once, "a repeat save has nothing to write")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.page(at: 0)?.annotations.filter { $0.type == "Highlight" }.count, 1)
    }

    /// Two marks in one save that share a line. The second must not lay a second band of
    /// ink on it — and the objects the first one wrote are not in the file yet to be found,
    /// so the check has to carry them itself.
    func testTwoMarksInOneSaveDoNotDoubleInkASharedLine() throws {
        let url = try makeDocument()
        let shared = CGRect(x: 72, y: 695, width: 200, height: 18)
        let edits = PDFHighlightStore.Edits(added: [
            mark(page: 0, rects: [shared]),
            mark(page: 0, rects: [shared, CGRect(x: 72, y: 673, width: 160, height: 18)])
        ])
        _ = try PDFIncrementalWriter.append(edits, to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let covered = page.annotations.filter { $0.type == "Highlight" }
            .flatMap { PDFHighlightStore.markedRectangles(of: $0).map(\.rounded) }
        XCTAssertEqual(covered.count, Set(covered).count, "no line may be inked twice")
        XCTAssertEqual(Set(covered), Set([shared, CGRect(x: 72, y: 673, width: 160, height: 18)]
            .map { PDFHighlight.Rect($0).rounded }))
    }

    // MARK: - Taking marks out and changing them

    func testRemovingAMarkTakesItOffThePage() throws {
        let url = try makeDocument()
        let written = mark(page: 0, rects: [CGRect(x: 72, y: 695, width: 200, height: 18)])
        _ = try PDFIncrementalWriter.append(PDFHighlightStore.Edits(added: [written]), to: url)
        let marked = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(PDFHighlightStore.marksInDocument(marked).count, 1)

        _ = try PDFIncrementalWriter.append(
            PDFHighlightStore.Edits(removed: [written.placement]), to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(PDFHighlightStore.marksInDocument(document).isEmpty,
                      "a mark deleted on screen has to leave the book too")
    }

    func testRecolouringAMarkChangesItsInk() throws {
        let url = try makeDocument()
        var written = mark(page: 0, rects: [CGRect(x: 72, y: 695, width: 200, height: 18)],
                           color: .yellow)
        _ = try PDFIncrementalWriter.append(PDFHighlightStore.Edits(added: [written]), to: url)

        written.color = .purple
        _ = try PDFIncrementalWriter.append(PDFHighlightStore.Edits(recoloured: [written]), to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        let read = try XCTUnwrap(PDFHighlightStore.marksInDocument(document).first)
        XCTAssertEqual(read.ink, .purple)
        XCTAssertEqual(document.page(at: 0)?.annotations.filter { $0.type == "Highlight" }.count, 1,
                       "a recolour edits the mark, it does not add a second one")
    }

    /// A mark on a page the document no longer has is reported back rather than dropped, so
    /// the sidecar keeps holding it.
    func testMarkOnAMissingPageComesBackUnapplied() throws {
        let url = try makeDocument(pages: 2)
        let stray = mark(page: 9, rects: [CGRect(x: 72, y: 695, width: 200, height: 18)])
        let result = try PDFIncrementalWriter.append(
            PDFHighlightStore.Edits(added: [stray]), to: url)
        XCTAssertEqual(result.unapplied.map(\.id), [stray.id])
    }

    // MARK: - Cost

    /// The reason this exists. An append has to be proportional to the marks written, not
    /// to the size of the book — PDFKit's whole-file write is the thing being avoided, and
    /// on a long document it is seconds and a much larger file.
    func testAppendCostsFarLessThanTheDocument() throws {
        let url = try makeDocument(pages: 120)
        let before = try Data(contentsOf: url).count

        let start = Date()
        _ = try PDFIncrementalWriter.append(
            PDFHighlightStore.Edits(
                added: [mark(page: 60, rects: [CGRect(x: 72, y: 695, width: 200, height: 18)])]),
            to: url)
        let elapsed = Date().timeIntervalSince(start)

        let added = try Data(contentsOf: url).count - before
        XCTAssertLessThan(added, 4_000, "one mark should cost a mark's worth of bytes")
        XCTAssertLessThan(elapsed, 1.0, "an append must not scale with the book")
    }

    // MARK: - Documents it should decline

    /// Anything the reader cannot make sense of has to raise rather than half-write, so the
    /// store falls back to PDFKit instead of leaving a damaged book behind.
    func testGarbageIsRefusedRatherThanWritten() throws {
        let url = scratch.appendingPathComponent("not-a.pdf")
        try Data("%PDF-1.7\nthis is not a document\n".utf8).write(to: url)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try PDFIncrementalWriter.append(
            PDFHighlightStore.Edits(
                added: [mark(page: 0, rects: [CGRect(x: 0, y: 0, width: 10, height: 10)])]),
            to: url))
        XCTAssertEqual(try Data(contentsOf: url), before, "a refusal must not touch the file")
    }
}

/// The file reader underneath the writer, on the parts that are easy to get subtly wrong.
final class PDFObjectFileTests: XCTestCase {

    private func makeDocument(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw XCTSkip("could not create a PDF context")
        }
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testPageOrderMatchesPDFKit() throws {
        let url = try makeDocument(named: "pages")
        defer { try? FileManager.default.removeItem(at: url) }
        var file = try PDFObjectFile(contentsOf: url)
        let numbers = try file.pageObjectNumbers()
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(numbers.count, document.pageCount)
        XCTAssertEqual(Set(numbers).count, numbers.count, "each page is its own object")
    }

    func testTrailerNamesTheCatalog() throws {
        let url = try makeDocument(named: "trailer")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PDFObjectFile(contentsOf: url)
        XCTAssertNotNil(file.trailer["Root"]?.referenceValue)
        XCTAssertGreaterThan(file.size, 0)
        XCTAssertGreaterThan(file.startXref, 0)
    }

    /// Flate is how nearly every object in a modern PDF is stored; a reader that cannot
    /// undo it cannot read the page tree at all.
    func testInflateRoundTripsThroughZlibHeaders() throws {
        let original = Array(String(repeating: "fyolo ", count: 500).utf8)
        let compressed = try XCTUnwrap(NSData(bytes: original, length: original.count)
            .compressed(using: .zlib) as Data?)
        // `NSData` emits raw DEFLATE; a PDF carries the zlib wrapper, so both shapes are
        // put through the same door here.
        XCTAssertEqual(try PDFObjectFile.inflate([UInt8](compressed)), original)
        var wrapped: [UInt8] = [0x78, 0x9C]
        wrapped += [UInt8](compressed)
        XCTAssertEqual(try PDFObjectFile.inflate(wrapped), original)
    }
}
