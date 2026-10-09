import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import fyolo

/// The PDF reader against a real document: the table of contents PDFKit hands back, the
/// marks that have to survive closing the file, and — when `FYOLO_DUMP_DIR` is set — a
/// PNG of the assembled reader, since layout and spacing only show up on screen.
@MainActor
final class PDFReaderTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var document: URL!

    private static let sections = ["Introduction", "The Session Protocol", "Results"]

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "pdf-reader-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        document = directory.appendingPathComponent("sample.pdf")
        try writeSampleDocument(to: document)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: PDFHighlightStore.directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Contents

    func testOutlineCarriesEveryEntryAndItsPage() throws {
        let pdf = try XCTUnwrap(PDFDocument(url: document))
        let outline = PDFOutlineNode.tree(from: pdf.outlineRoot, in: pdf)
        XCTAssertEqual(outline.map(\.label), Self.sections)
        XCTAssertEqual(outline.compactMap(\.page), [0, 1, 2])
    }

    /// The contents list keeps the section you are *in* selected, not the last one you
    /// clicked — so a scroll two pages on moves the highlight with you.
    func testCurrentSectionFollowsThePage() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        XCTAssertTrue(model.opened)
        model.go(toPage: 2)
        let node = try XCTUnwrap(model.currentSectionID.flatMap(model.node(withID:)))
        XCTAssertEqual(node.label, "Results")
    }

    // MARK: - Highlights

    /// A mark is kept in a sidecar, never written into the user's PDF: highlighting a
    /// paper checked into a repo must leave `git status` clean.
    func testHighlightPersistsWithoutTouchingTheDocument() throws {
        let before = try Data(contentsOf: document)
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        let selection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.pdfView.currentSelection = selection
        model.highlightSelection()

        XCTAssertEqual(model.highlights.count, 1)
        let mark = try XCTUnwrap(model.highlights.first)
        XCTAssertFalse(mark.text.isEmpty, "a mark carries the passage it quotes")
        XCTAssertFalse(mark.rects.isEmpty)
        XCTAssertEqual(try Data(contentsOf: document), before, "the PDF itself must not be rewritten")

        // Reopening the same document paints the marks back onto the page.
        let reopened = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        XCTAssertEqual(reopened.highlights.map(\.id), [mark.id])
        let annotations = try XCTUnwrap(reopened.pdfView.document?.page(at: 0)?.annotations)
        XCTAssertEqual(annotations.filter { $0.userName == mark.id.uuidString }.count, mark.rects.count)

        reopened.remove(mark.id)
        XCTAssertTrue(reopened.highlights.isEmpty)
        XCTAssertTrue(try XCTUnwrap(reopened.pdfView.document?.page(at: 0)?.annotations).isEmpty,
                      "removing a mark takes every rect of it off the page")
        XCTAssertTrue(PDFHighlightStore.load(for: document).isEmpty)
    }

    /// The document changed on disk but the pages didn't move — a table of contents added,
    /// a re-export from the same source. The marks are filed under the file's hash, so
    /// without adoption every one of them would vanish silently.
    func testMarksSurviveTheDocumentBeingRewritten() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.highlightSelection(color: .purple)
        let before = try XCTUnwrap(model.highlights.first)

        // Rewrite the file the way adding an outline does: same pages, different bytes.
        let rewritten = try XCTUnwrap(PDFDocument(url: document))
        let root = PDFOutline()
        let entry = PDFOutline()
        entry.label = "Added later"
        entry.destination = PDFDestination(page: try XCTUnwrap(rewritten.page(at: 0)), at: .zero)
        root.insertChild(entry, at: 0)
        rewritten.outlineRoot = root
        XCTAssertTrue(rewritten.write(to: document))
        XCTAssertNotEqual(PDFHighlightStore.fingerprint(for: document), nil)

        let reopened = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        XCTAssertEqual(reopened.highlights.map(\.placement), [before.placement],
                       "marks must survive the document being rewritten in place")
        XCTAssertEqual(reopened.highlights.first?.ink, .purple)
    }

    /// Marks follow the document's bytes, so a renamed or moved file keeps them.
    func testMarksFollowTheFileToANewPath() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        let selection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 20))
        model.pdfView.currentSelection = selection
        model.highlightSelection()

        let moved = directory.appendingPathComponent("renamed.pdf")
        try FileManager.default.copyItem(at: document, to: moved)
        XCTAssertEqual(PDFHighlightStore.load(for: moved).count, 1)
    }

    /// A mark remembers which marker made it, and the annotation on the page is drawn in
    /// that color rather than a single house ink.
    func testHighlightKeepsItsColor() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 30))
        model.highlightSelection(color: .green)

        XCTAssertEqual(model.highlights.first?.ink, .green)
        let annotation = try XCTUnwrap(page.annotations.first)
        XCTAssertTrue(sameInk(annotation.color, PDFHighlightColor.green.annotationColor))
        XCTAssertEqual(PDFHighlightStore.load(for: document).first?.ink, .green)
    }

    /// "Save Highlights into PDF" puts the marks in the file itself, and a second save adds
    /// nothing — the page must not end up with two coats of ink.
    func testSavingMarksIntoTheDocumentIsIdempotent() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 60))
        model.highlightSelection(color: .blue)
        let marks = model.highlights
        XCTAssertEqual(marks.count, 1)

        XCTAssertTrue(PDFHighlightStore.apply(.init(added: marks), to: document).written)
        let written = try XCTUnwrap(PDFDocument(url: document))
        let inFile = try XCTUnwrap(written.page(at: 0)?.annotations)
        let mark = try XCTUnwrap(marks.first)
        // One passage is one annotation carrying a quad per line, the shape Preview writes,
        // so what has to match is the lines it covers rather than a count of annotations.
        let own = inFile.filter { $0.userName == mark.id.uuidString }
        XCTAssertFalse(own.isEmpty)
        XCTAssertEqual(Set(own.flatMap { PDFHighlightStore.markedRectangles(of: $0).map(\.rounded) }),
                       Set(mark.rects.map(\.rounded)))
        XCTAssertTrue(sameInk(try XCTUnwrap(inFile.first?.color), PDFHighlightColor.blue.annotationColor),
                      "the marker color has to survive the round trip through the file")

        XCTAssertTrue(PDFHighlightStore.apply(.init(added: marks), to: document).written)
        let again = try XCTUnwrap(PDFDocument(url: document)?.page(at: 0)?.annotations)
        XCTAssertEqual(again.count, inFile.count, "a second save must not re-ink the page")

        // And a reader opening the marked file draws nothing extra on top of it.
        let reopened = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let onScreen = try XCTUnwrap(reopened.pdfView.document?.page(at: 0)?.annotations)
        XCTAssertEqual(onScreen.count, inFile.count)
        XCTAssertFalse(reopened.hasUnsavedHighlights)
    }

    /// A document inside a repo files its marks with the repo, as reviewable JSON — the
    /// point being that a highlight shows up in `git diff` as a line, not as a new
    /// multi-megabyte PDF.
    func testMarksInARepoAreFiledWithTheRepo() throws {
        let repo = directory.appendingPathComponent("checkout", isDirectory: true)
        let papers = repo.appendingPathComponent("papers", isDirectory: true)
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        let inRepo = papers.appendingPathComponent("sample.pdf")
        try FileManager.default.copyItem(at: document, to: inRepo)

        let model = PDFReaderModel(url: inRepo, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.highlightSelection(color: .green)

        let sidecar = repo.appendingPathComponent(".fyolo/pdf/papers/sample.pdf.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path),
                      "marks belong beside the repo they were made in, at \(sidecar.path)")
        let json = try XCTUnwrap(String(data: try Data(contentsOf: sidecar), encoding: .utf8))
        XCTAssertTrue(json.contains("\"green\""), "the sidecar is readable JSON, not an opaque blob")

        // The PDF itself is untouched, which is the whole reason for the sidecar.
        XCTAssertEqual(try Data(contentsOf: inRepo), try Data(contentsOf: document))
        XCTAssertEqual(PDFReaderModel(url: inRepo, addToChat: nil, canAddToChat: nil)
            .highlights.first?.ink, .green)
    }

    /// Re-exporting the PDF in place — the case that makes path keying worth it — keeps the
    /// marks, because the sidecar is filed by path rather than by the file's bytes.
    func testRepoMarksSurviveTheDocumentBeingReplaced() throws {
        let repo = directory.appendingPathComponent("checkout2", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        let inRepo = repo.appendingPathComponent("book.pdf")
        try FileManager.default.copyItem(at: document, to: inRepo)

        let model = PDFReaderModel(url: inRepo, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.highlightSelection(color: .blue)

        let rewritten = try XCTUnwrap(PDFDocument(url: inRepo))
        let root = PDFOutline()
        let entry = PDFOutline()
        entry.label = "Added later"
        entry.destination = PDFDestination(page: try XCTUnwrap(rewritten.page(at: 0)), at: .zero)
        root.insertChild(entry, at: 0)
        rewritten.outlineRoot = root
        XCTAssertTrue(rewritten.write(to: inRepo))

        XCTAssertEqual(PDFReaderModel(url: inRepo, addToChat: nil, canAddToChat: nil)
            .highlights.first?.ink, .blue)
    }

    /// The case geometry alone cannot survive: the document is re-exported from its source
    /// and the words land somewhere else on the page. Preview's highlights end up over the
    /// wrong lines; a mark that also carries its quote can walk back onto its own words.
    func testMarksReanchorWhenThePageIsRelaidOut() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 70))
        model.highlightSelection(color: .yellow)
        let before = try XCTUnwrap(model.highlights.first)
        let quoted = PDFSelectionText.squashed(before.text)
        XCTAssertFalse(quoted.isEmpty)

        // Same source, re-exported with the text 120pt further down the page.
        try writeSampleDocument(to: document, shiftedBy: 120)

        let reopened = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let after = try XCTUnwrap(reopened.highlights.first)
        XCTAssertNotEqual(after.rects.first?.y, before.rects.first?.y,
                          "the mark has to move with its words, not sit at the old coordinates")
        let words = try XCTUnwrap(reopened.pdfView.document?.page(at: after.page)?
            .selection(for: try XCTUnwrap(after.rects.first).cgRect)?.string)
        XCTAssertTrue(quoted.contains(PDFSelectionText.squashed(words))
                        || PDFSelectionText.squashed(words).contains(quoted.prefix(20)),
                      "the mark must land on the words it quotes, got “\(words)”")
    }

    /// A document renamed keeps its marks, because the sidecar is keyed on the PDF's own
    /// identifier rather than on where the file happens to sit.
    func testMarksFollowARenameThroughTheFileIdentifier() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.highlightSelection(color: .pink)

        let renamed = directory.appendingPathComponent("renamed-book.pdf")
        try FileManager.default.moveItem(at: document, to: renamed)
        XCTAssertEqual(PDFHighlightStore.fingerprint(for: renamed),
                       PDFHighlightStore.fingerprint(for: renamed),
                       "the identifier is stable for one file")

        let reopened = PDFReaderModel(url: renamed, addToChat: nil, canAddToChat: nil)
        XCTAssertEqual(reopened.highlights.count, 1)
        XCTAssertEqual(reopened.highlights.first?.ink, .pink)
    }

    // MARK: - What the review found

    /// A save used to treat a mark as present when any one of its lines was, so the rest of
    /// a multi-line passage was never written — and the model then cleared its sidecar.
    func testSavingWritesEveryLineOfAPartlyPresentMark() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 200))
        model.highlightSelection(color: .yellow)
        let mark = try XCTUnwrap(model.highlights.first)
        XCTAssertGreaterThan(mark.rects.count, 1, "the fixture needs a multi-line passage")

        // Put only the first line in the file, the way a partial save would have.
        let partial = PDFHighlight(page: mark.page, rects: [try XCTUnwrap(mark.rects.first)],
                                   text: mark.text, color: .yellow)
        XCTAssertTrue(PDFHighlightStore.apply(.init(added: [partial]), to: document).written)
        XCTAssertTrue(PDFHighlightStore.apply(.init(added: [mark]), to: document).written)

        let written = try XCTUnwrap(PDFDocument(url: document)?.page(at: 0)?.annotations)
        let covered = Set(written.filter { $0.type == "Highlight" }
            .flatMap { PDFHighlightStore.markedRectangles(of: $0).map(\.rounded) })
        XCTAssertEqual(covered, Set(mark.rects.map(\.rounded)),
                       "every line of the passage has to reach the file")
    }

    /// A mark whose page is gone cannot be written. Reporting it saved dropped it from the
    /// sidecar as well, which lost it for good.
    func testAMarkWhosePageIsGoneIsReportedUnapplied() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.highlightSelection(color: .blue)
        var mark = try XCTUnwrap(model.highlights.first)
        mark.page = 99

        let result = PDFHighlightStore.apply(.init(added: [mark]), to: document)
        XCTAssertEqual(result.unapplied.map(\.id), [mark.id],
                       "a mark that could not be written must be reported, not assumed saved")
    }

    /// Saving one mark must not disturb a highlight another application added, nor a link
    /// that happens to share a passage's bounds.
    func testSavingLeavesForeignAnnotationsAlone() throws {
        let bounds = CGRect(x: 72, y: 600, width: 200, height: 14)
        let foreign = try XCTUnwrap(PDFDocument(url: document))
        let page = try XCTUnwrap(foreign.page(at: 0))
        let theirs = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        theirs.color = NSColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        page.addAnnotation(theirs)
        let link = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        page.addAnnotation(link)
        XCTAssertTrue(foreign.write(to: document))

        let mine = PDFHighlight(page: 0, rects: [.init(CGRect(x: 72, y: 500, width: 100, height: 12))],
                                text: "mine", color: .green)
        XCTAssertTrue(PDFHighlightStore.apply(.init(added: [mine]), to: document).written)

        let after = try XCTUnwrap(PDFDocument(url: document)?.page(at: 0)?.annotations)
        XCTAssertEqual(after.filter { $0.type == "Link" }.count, 1, "a link is not a mark")
        let red = try XCTUnwrap(after.first { $0.type == "Highlight" && $0.bounds == bounds })
        XCTAssertTrue(sameInk(try XCTUnwrap(red.color),
                              NSColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1)),
                      "a foreign mark keeps its own colour")
    }

    /// Removing a mark the book itself carries has to outlive the reader: the annotation is
    /// gone from the page, and reopening must not bring it back.
    func testRemovingAnEmbeddedMarkSurvivesReopening() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.highlightSelection(color: .purple)
        let mark = try XCTUnwrap(model.highlights.first)
        XCTAssertTrue(PDFHighlightStore.apply(.init(added: [mark]), to: document).written)

        let reopened = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        XCTAssertEqual(reopened.highlights.count, 1)
        reopened.remove(try XCTUnwrap(reopened.highlights.first?.id))
        XCTAssertTrue(reopened.hasUnsavedHighlights, "the book still has it, so there is work to do")

        let again = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        XCTAssertTrue(again.highlights.isEmpty, "a removed mark must not come back on reopen")
        XCTAssertTrue(again.hasUnsavedHighlights, "and the book still needs the removal written")
    }

    /// Re-inking a mark the book carries also has to outlive the reader.
    func testRecolouringAnEmbeddedMarkSurvivesReopening() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.highlightSelection(color: .yellow)
        let mark = try XCTUnwrap(model.highlights.first)
        XCTAssertTrue(PDFHighlightStore.apply(.init(added: [mark]), to: document).written)

        let reopened = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        reopened.recolor(try XCTUnwrap(reopened.highlights.first?.id), to: .green)

        let again = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        XCTAssertEqual(again.highlights.first?.ink, .green)
        XCTAssertTrue(again.hasUnsavedHighlights)
    }

    /// An unwritable destination used to take the marks with it: the original sidecar was
    /// deleted whether or not its replacement had been written.
    func testAdoptionKeepsTheOriginalWhenReFilingFails() throws {
        let outside = directory.appendingPathComponent("loose.pdf")
        try FileManager.default.copyItem(at: document, to: outside)
        let model = PDFReaderModel(url: outside, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.highlightSelection(color: .pink)

        let before = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: PDFHighlightStore.directory, includingPropertiesForKeys: nil).first)

        // Rewrite the document so its identity moves, then make the new sidecar unwritable.
        let rewritten = try XCTUnwrap(PDFDocument(url: outside))
        XCTAssertTrue(rewritten.write(to: outside))
        let store = try XCTUnwrap(PDFHighlightStore.store(for: outside))
        let blocked = PDFHighlightStore.fileURL(for: store)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

        XCTAssertEqual(PDFHighlightStore.load(for: outside).count, 1, "the marks still load")
        XCTAssertTrue(FileManager.default.fileExists(atPath: before.path),
                      "the only copy of the marks must not be deleted when re-filing fails")
    }

    // MARK: - Context menu

    /// The reader's own menu, not PDFKit's: copy and mark the passage, hand it to the
    /// agent, and the file verbs. A plain-shell session shows no "Add to Chat" at all.
    func testMenuOffersTheReaderVerbsForASelection() throws {
        var runsAgent = true
        let model = PDFReaderModel(url: document, addToChat: { _ in }, canAddToChat: { runsAgent })
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 30))

        // The swatch row is a view item and carries no title — its empty slot at the top is
        // the assertion that the colors lead the menu.
        let titles = try menuTitles(of: model)
        XCTAssertEqual(titles, ["", "", "Copy", "", "Add to Chat", "", "Reveal in Finder", "Close"])
        let menu = try menu(of: model)
        XCTAssertTrue(menu.items.first?.view is PDFHighlightSwatchRow,
                      "a selection's menu opens with the marker colors")

        runsAgent = false
        XCTAssertFalse(try menuTitles(of: model).contains("Add to Chat"),
                       "a plain shell has nothing to add a passage to")
    }

    private func menuTitles(of model: PDFReaderModel) throws -> [String] {
        try menu(of: model).items.map(\.title)
    }

    private func menu(of model: PDFReaderModel) throws -> NSMenu {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return try XCTUnwrap(model.pdfView.menu(for: event))
    }

    /// A book marked up somewhere else — Preview, Books — opens with its marks listed,
    /// rather than looking untouched because fyolo didn't write them.
    func testMarksMadeElsewhereAreListed() throws {
        let foreign = try XCTUnwrap(PDFDocument(url: document))
        let page = try XCTUnwrap(foreign.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 200, height: 14),
                                       forType: .highlight, withProperties: nil)
        annotation.color = PDFHighlightColor.pink.annotationColor
        page.addAnnotation(annotation)
        XCTAssertTrue(foreign.write(to: document))

        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        XCTAssertEqual(model.highlights.count, 1)
        XCTAssertEqual(model.highlights.first?.ink, .pink, "a foreign mark's color maps onto the palette")
        XCTAssertFalse(model.hasUnsavedHighlights, "the book already has it; nothing to save")

        // And removing it is a change the file needs, not a no-op.
        let mark = try XCTUnwrap(model.highlights.first)
        model.remove(mark.id)
        XCTAssertTrue(model.hasUnsavedHighlights)
        XCTAssertTrue(PDFHighlightStore.apply(.init(removed: [mark.placement]), to: document).written)
        let after = try XCTUnwrap(PDFDocument(url: document)?.page(at: 0)?.annotations)
        XCTAssertTrue(after.isEmpty, "a mark removed on screen is removed from the book")
    }

    /// Re-inking a mark keeps it in place — the ask being "make that one green", not
    /// "remove it and select the passage again".
    func testRecoloringAMarkKeepsIt() throws {
        let model = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let page = try XCTUnwrap(model.pdfView.document?.page(at: 0))
        model.pdfView.currentSelection = try XCTUnwrap(model.pdfView.document?.selection(
            from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 40))
        model.highlightSelection(color: .yellow)
        let mark = try XCTUnwrap(model.highlights.first)

        model.recolor(mark.id, to: .pink)
        XCTAssertEqual(model.highlights.count, 1)
        XCTAssertEqual(model.highlights.first?.ink, .pink)
        XCTAssertTrue(sameInk(try XCTUnwrap(page.annotations.first?.color),
                              PDFHighlightColor.pink.annotationColor))
        XCTAssertEqual(PDFHighlightStore.load(for: document).first?.ink, .pink)
    }

    // MARK: - The assembled reader

    /// Renders the reader into PNGs so its layout can actually be looked at:
    ///
    ///     FYOLO_DUMP_DIR=/tmp/pdf swift test --filter PDFReaderTests/testRendersForVisualReview
    ///
    /// The assembled reader, each sidebar rail on its own, and a PDFKit render of a marked
    /// page — the last because `cacheDisplay` captures the SwiftUI chrome but not `PDFView`'s
    /// tiled layers, so the document area of a chrome shot comes out blank.
    /// Skipped without the variable, and on a headless machine where AppKit can't lay out.
    func testRendersForVisualReview() throws {
        guard let dump = ProcessInfo.processInfo.environment["FYOLO_DUMP_DIR"] else {
            throw XCTSkip("set FYOLO_DUMP_DIR to render the reader")
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        guard CGSessionCopyCurrentDictionary() != nil else {
            throw XCTSkip("needs a GUI session to lay out")
        }
        let directoryURL = URL(fileURLWithPath: dump, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // A mark to look at, made before the reader opens so it is painted on load.
        let marker = PDFReaderModel(url: document, addToChat: nil, canAddToChat: nil)
        let markedPage = try XCTUnwrap(marker.pdfView.document?.page(at: 0))
        marker.pdfView.currentSelection = try XCTUnwrap(marker.pdfView.document?.selection(
            from: markedPage, atCharacterIndex: 0, to: markedPage, atCharacterIndex: 220))
        marker.highlightSelection()

        let generatedDocument: URL = document
        let sample: URL = ProcessInfo.processInfo.environment["FYOLO_SAMPLE_PDF"].map {
            URL(fileURLWithPath: $0)
        } ?? generatedDocument
        let settings = makeSettings()
        let store = FyoloStore(workspaces: [Workspace(name: "Default")], settings: settings)
        let reader = PDFReaderView(
            url: sample, settings: settings,
            addToChat: { _ in }, canAddToChat: { true }, onClose: {}
        )
        .environmentObject(store)
        .environmentObject(settings)

        let size = CGSize(width: 1100, height: 760)
        let hosting = NSHostingView(rootView: reader)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        settle()

        try capture(hosting, to: directoryURL.appendingPathComponent("reader-contents.png"))
        window.orderOut(nil)

        // The other rails on their own. Hosted directly rather than clicked into, because
        // synthetic mouse events don't reach SwiftUI's gestures from a test. A real book can
        // be pointed at with FYOLO_SAMPLE_PDF — a generated three-pager has no nesting to
        // show, and the contents rail is all about nesting.
        let generated: URL = generatedDocument
        let book: URL = sample
        for (tab, name) in [(PDFReaderModel.Sidebar.contents, "contents"),
                            (PDFReaderModel.Sidebar.thumbnails, "pages"),
                            (PDFReaderModel.Sidebar.highlights, "highlights")] {
            let model = PDFReaderModel(url: tab == .contents ? book : generated,
                                       addToChat: nil, canAddToChat: { true })
            model.sidebar = tab
            // Open a couple of chapters so the capture shows the tree, not a flat list.
            for entry in model.outline.prefix(4) { model.toggleEntry(entry.id) }
            // The rail is transparent in the app — it sits on the reader's own fill — so the
            // capture has to paint one, or dark-mode text lands on nothing.
            let rail = NSHostingView(rootView: PDFReaderSidebar(
                model: model, addToChat: { _ in }, canAddToChat: { true })
                .environmentObject(settings)
                .background(Color(nsColor: .windowBackgroundColor)))
            rail.frame = CGRect(x: 0, y: 0, width: 216, height: 760)
            let railWindow = NSWindow(contentRect: rail.frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
            railWindow.contentView = rail
            // The app is dark far more often than not; render the rail the way it is read.
            railWindow.appearance = NSAppearance(named: .darkAqua)
            railWindow.makeKeyAndOrderFront(nil)
            settle()
            try capture(rail, to: directoryURL.appendingPathComponent("sidebar-\(name).png"))
            railWindow.orderOut(nil)
        }

        // The page as PDFKit draws it, marks included.
        let reopened = try XCTUnwrap(PDFDocument(url: document))
        let page = try XCTUnwrap(reopened.page(at: 0))
        let marks = PDFHighlightStore.load(for: document)
        for mark in marks where mark.page == 0 {
            for rect in mark.rects {
                let annotation = PDFAnnotation(bounds: rect.cgRect, forType: .highlight, withProperties: nil)
                annotation.color = mark.ink.annotationColor
                page.addAnnotation(annotation)
            }
        }
        let image = page.thumbnail(of: CGSize(width: 612, height: 792), for: .cropBox)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directoryURL.appendingPathComponent("page-with-highlight.png"))
    }

    /// Lets AppKit lay out, draw, and let PDFKit finish its own work before a capture.
    private func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    /// Colors come back from a written file in the device color space, so they are compared
    /// by their components rather than by identity.
    private func sameInk(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    // MARK: - Fixtures

    private func makeSettings() -> AppSettings {
        AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
    }

    /// A three-page paper with a table of contents — the shape the reader is for.
    private func writeSampleDocument(to url: URL, shiftedBy shift: CGFloat = 0) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let body = String(repeating:
            "The session lives on the box, not in the connection. Detach is not kill: an agent "
            + "keeps working while the laptop is shut, and reattaching restores the screen. ", count: 12)
        for section in Self.sections {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            section.draw(at: CGPoint(x: 72, y: 690 - shift),
                         withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold)])
            body.draw(in: CGRect(x: 72, y: 96 - shift, width: 468, height: 560),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let root = PDFOutline()
        for (index, section) in Self.sections.enumerated() {
            let entry = PDFOutline()
            entry.label = section
            let page = try XCTUnwrap(pdf.page(at: index))
            entry.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 792))
            root.insertChild(entry, at: index)
        }
        pdf.outlineRoot = root
        XCTAssertTrue(pdf.write(to: url))
    }
}
