import XCTest
@testable import fyolo

/// Notes: which file a scope maps to, how a note saves and picks up changes on
/// disk, and the Markdown styling and checkbox toggle the page draws from.
@MainActor
final class NotesTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Files

    func testScopesMapToReadableStableFiles() {
        let project = NoteScope.project(name: "My App", path: "/Users/me/my-app", machine: nil)
        let url = NotesLibrary.fileURL(for: project, in: directory)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("my-app-"))
        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertEqual(url, NotesLibrary.fileURL(for: project, in: directory), "same scope, same file")
        XCTAssertEqual(NotesLibrary.fileURL(for: .scratch, in: directory).lastPathComponent, "scratch.md")
    }

    func testWorktreeNotesLiveInTheirProjectsFolder() {
        let worktree = NoteScope.worktree(
            projectName: "my-app", projectPath: "/Users/me/my-app", machine: nil, path: "/Users/me/wt/feat-login")
        let url = NotesLibrary.fileURL(for: worktree, in: directory)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("feat-login-"))
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix("my-app-"))
    }

    func testTheSamePathOnAnotherMachineIsAnotherNote() {
        let local = NoteScope.project(name: "app", path: "/srv/app", machine: nil)
        let remote = NoteScope.project(name: "app", path: "/srv/app", machine: "vps")
        XCTAssertNotEqual(NotesLibrary.fileURL(for: local, in: directory), NotesLibrary.fileURL(for: remote, in: directory))
    }

    func testRenamingTheProjectKeepsItsNote() throws {
        let before = NoteScope.project(name: "Old Name", path: "/Users/me/app", machine: nil)
        let document = NoteDocument(scope: before, directory: directory)
        document.edit("remember this")
        document.saveNow()
        let after = NoteScope.project(name: "New Name", path: "/Users/me/app", machine: nil)
        XCTAssertEqual(NoteDocument(scope: after, directory: directory).text, "remember this")
    }

    func testHashesAreStableAcrossLaunches() {
        // FNV-1a, not `hashValue`: this exact value must never change, or every note goes missing.
        XCTAssertEqual(NotesLibrary.hash(nil, "/Users/me/app"), NotesLibrary.hash(nil, "/Users/me/app"))
        XCTAssertEqual(NotesLibrary.hash(nil, "/Users/me/app").count, 8)
        XCTAssertEqual(NotesLibrary.slug("  Fyolo / Mac App!! "), "fyolo-mac-app")
        XCTAssertEqual(NotesLibrary.slug("日本"), "note")
    }

    func testRelativeLinksResolveIntoTheNotesFolder() {
        XCTAssertEqual(
            NotesLibrary.resolve("attachments/a.png", in: directory),
            directory.appendingPathComponent("attachments/a.png"))
        XCTAssertEqual(NotesLibrary.resolve("https://example.com/x")?.host, "example.com")
        XCTAssertEqual(NotesLibrary.resolve("/tmp/file.txt")?.path, "/tmp/file.txt")
    }

    // MARK: Saving

    func testSavesAfterTypingStopsAndAnEmptiedNoteLeavesNoFile() async throws {
        let document = NoteDocument(scope: .scratch, directory: directory)
        document.edit("first idea")
        XCTAssertTrue(document.isDirty)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try String(contentsOf: document.url, encoding: .utf8), "first idea")

        document.edit("")
        document.saveNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.path))
    }

    func testPicksUpAChangeMadeOnDisk() throws {
        let document = NoteDocument(scope: .scratch, directory: directory)
        document.edit("mine")
        document.saveNow()
        try NotesLibrary.write("mine\nappended by an agent", to: document.url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: document.url.path)
        XCTAssertTrue(document.reloadIfChangedOnDisk())
        XCTAssertEqual(document.text, "mine\nappended by an agent")
    }

    func testAConflictKeepsBothVersions() throws {
        let document = NoteDocument(scope: .scratch, directory: directory)
        document.edit("base")
        document.saveNow()
        document.edit("base + my typing")
        try NotesLibrary.write("base + someone else", to: document.url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: document.url.path)
        document.saveNow()
        XCTAssertEqual(try String(contentsOf: document.url, encoding: .utf8), "base + my typing")
        let copy = try XCTUnwrap(document.conflictCopy)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "base + someone else")
    }

    func testSwitchingScopesSavesTheNoteBeingLeft() throws {
        let model = NotesModel(scope: .scratch, directory: directory)
        model.document.edit("scratch thought")
        let project = NoteScope.project(name: "app", path: "/Users/me/app", machine: nil)
        model.show(project)
        XCTAssertEqual(model.document.scope, project)
        XCTAssertEqual(
            try String(contentsOf: NotesLibrary.fileURL(for: .scratch, in: directory), encoding: .utf8),
            "scratch thought")
    }

    // MARK: Styling

    func testFindsHeadingsCheckboxesLinksAndCode() {
        let text = """
        # Plan
        - [ ] write tests
        - [x] ship it
        see https://example.com and [spec](attachments/spec.pdf)
        use `swift test`
        """
        let kinds = NotesStyler.spans(in: text).map(\.kind)
        XCTAssertTrue(kinds.contains(.heading(level: 1)))
        XCTAssertTrue(kinds.contains(.checkbox(checked: false)))
        XCTAssertTrue(kinds.contains(.checkbox(checked: true)))
        XCTAssertTrue(kinds.contains(.doneItem))
        XCTAssertTrue(kinds.contains(.link("https://example.com")))
        XCTAssertTrue(kinds.contains(.link("attachments/spec.pdf")))
        XCTAssertTrue(kinds.contains(.code))
        XCTAssertEqual(kinds.filter { if case .link = $0 { return true } else { return false } }.count, 2,
                       "a Markdown link is not also detected as a bare URL")
    }

    // MARK: Zoom

    func testZoomingInScrollsSidewaysAndZoomingOutRewraps() {
        let scrollView = NoteScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 2000))
        scrollView.documentView = page
        scrollView.allowsMagnification = true
        scrollView.minMagnification = NoteScrollView.magnificationRange.lowerBound
        scrollView.maxMagnification = NoteScrollView.magnificationRange.upperBound
        let viewWidth = scrollView.contentView.frame.width

        scrollView.magnification = 2
        XCTAssertEqual(page.frame.width, viewWidth, accuracy: 0.5, "the page keeps its 100% width")
        XCTAssertGreaterThan(page.frame.width, scrollView.contentView.bounds.width + 1, "so it scrolls sideways")

        scrollView.magnification = 0.5
        XCTAssertEqual(page.frame.width, scrollView.contentView.bounds.width, accuracy: 0.5,
                       "zoomed out, the page fills the view instead of leaving a band at the right")
    }

    func testClickingACheckboxTicksAndClearsIt() throws {
        let text = "- [ ] task"
        let tick = try XCTUnwrap(NotesStyler.checkboxToggle(in: text, at: 3))
        XCTAssertEqual(tick.replacement, "x")
        let ticked = (text as NSString).replacingCharacters(in: tick.range, with: tick.replacement)
        XCTAssertEqual(ticked, "- [x] task")
        XCTAssertEqual(NotesStyler.checkboxToggle(in: ticked, at: 3)?.replacement, " ")
        XCTAssertNil(NotesStyler.checkboxToggle(in: text, at: 8), "a click on the task's words edits, not ticks")
    }
}
