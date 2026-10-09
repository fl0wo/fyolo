import XCTest
@testable import fyolo

/// The diff header's file menu promises the set the overlay walks with ← / →, so a file the menu
/// offers has to be one the arrows can reach, and a preview-only sibling has to be in neither. The
/// menu is built from `walkableSiblings` and every jump goes through `aimed(at:)`, so those two are
/// where the promise lives.
final class DiffFileWalkTests: XCTestCase {
    private func change(_ path: String, additions: Int = 1, deletions: Int = 0) -> GitChange {
        GitChange(path: path, status: .modified, isUntracked: false,
                  additions: additions, deletions: deletions)
    }

    private func diffRequest(_ paths: [String], current: String,
                         commit: String? = nil, range: String? = nil) -> GitDiffRequest {
        GitDiffRequest(repoRoot: "/tmp/repo", change: change(current),
                       commit: commit, range: range, siblings: paths.map { change($0) })
    }

    func testWalkableSiblingsKeepTheDiffableFilesInTheListOrder() {
        let request = diffRequest(["a.swift", "b.png", "c.md", "d.pdf", "e.txt"], current: "a.swift")
        XCTAssertEqual(request.walkableSiblings.map(\.path), ["a.swift", "c.md", "e.txt"])
    }

    /// SVG is preview-only here although it is text, and HTML is not: both decisions belong to
    /// `FileActivation`, and the menu has to inherit them rather than invent its own rule.
    func testWalkableSiblingsFollowTheActivationsOwnRule() {
        let request = diffRequest(["a.svg", "b.html", "c.swift"], current: "b.html")
        XCTAssertEqual(request.walkableSiblings.map(\.path), ["b.html", "c.swift"])
    }

    func testAimedAtKeepsTheSetAndTheDiffIdentityAndSwapsTheFile() {
        let request = diffRequest(["a.swift", "b.swift"], current: "a.swift",
                              commit: "abc1234", range: "main...feature")
        let moved = request.aimed(at: change("b.swift"))
        XCTAssertEqual(moved.change.path, "b.swift")
        XCTAssertEqual(moved.repoRoot, request.repoRoot)
        XCTAssertEqual(moved.commit, request.commit)
        XCTAssertEqual(moved.range, request.range)
        XCTAssertEqual(moved.siblings.map(\.path), ["a.swift", "b.swift"])
    }

    /// The walk steps over a preview-only sibling rather than stopping on it, and reads the same
    /// set the menu lists — one jump either way from the middle of a mixed list.
    func testTheWalkStepsOverPreviewOnlySiblings() {
        let request = diffRequest(["a.swift", "b.png", "c.swift"], current: "a.swift")
        XCTAssertEqual(request.neighbor(1)?.change.path, "c.swift")

        let backwards = diffRequest(["a.swift", "b.png", "c.swift"], current: "c.swift")
        XCTAssertEqual(backwards.neighbor(-1)?.change.path, "a.swift")
    }

    func testTheWalkStopsAtTheEnds() {
        let request = diffRequest(["a.swift", "b.png"], current: "a.swift")
        XCTAssertNil(request.neighbor(1))
        XCTAssertNil(request.neighbor(-1))
    }
}
