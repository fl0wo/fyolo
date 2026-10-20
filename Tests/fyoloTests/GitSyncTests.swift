import Foundation
import XCTest
@testable import fyolo

/// The toolbar git capsule and the Inspect tab read one `git status` and two range
/// diffs. The parse is pinned against real `git` in throwaway repositories with a real
/// upstream, since a wrong count is a claim about somebody's unpushed work.
final class GitSyncTests: XCTestCase {
    // MARK: Status

    func testPorcelainHeadersAndEntries() {
        let porcelain = """
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head feat/x
        # branch.upstream origin/feat/x
        # branch.ab +3 -2
        1 .M N... 100644 100644 100644 aaa bbb Sources/a.swift
        2 R. N... 100644 100644 100644 aaa bbb R100 new name.swift\told.swift
        u UU N... 100644 100644 100644 100644 a b c conflict.txt
        ? untracked/
        ! ignored.log
        """
        let status = GitSyncStatus(porcelain: porcelain, repositoryRoot: "/r")
        XCTAssertEqual(status.head, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(status.branch, "feat/x")
        XCTAssertEqual(status.upstream, "origin/feat/x")
        XCTAssertEqual(status.ahead, 3)
        XCTAssertEqual(status.behind, 2)
        XCTAssertEqual(status.changedFiles, 4, "ignored entries are not changes")
        XCTAssertEqual(status.addedFiles, 1, "the untracked folder")
        XCTAssertEqual(status.deletedFiles, 0)
        XCTAssertEqual(status.sync, .diverged(pull: 2, push: 3))
    }

    func testNewAndRemovedFilesAreCountedApart() {
        let porcelain = """
        1 A. N... 000000 100644 100644 000 bbb staged-new.swift
        1 .D N... 100644 100644 000000 aaa aaa gone.swift
        1 D. N... 100644 000000 000000 aaa 000 staged-gone.swift
        1 MM N... 100644 100644 100644 aaa bbb edited.swift
        """
        let status = GitSyncStatus(porcelain: porcelain, repositoryRoot: "/r")
        XCTAssertEqual(status.changedFiles, 4)
        XCTAssertEqual(status.addedFiles, 1)
        XCTAssertEqual(status.deletedFiles, 2)
    }

    func testAnUnbornBranchHasNoHead() {
        let status = GitSyncStatus(porcelain: "# branch.oid (initial)\n# branch.head main\n", repositoryRoot: "/r")
        XCTAssertNil(status.head)
        XCTAssertEqual(status.branch, "main")
    }

    func testDetachedHeadHasNothingToSync() {
        let status = GitSyncStatus(porcelain: "# branch.head (detached)\n", repositoryRoot: "/r")
        XCTAssertNil(status.branch)
        XCTAssertNil(status.sync)
    }

    func testSyncStates() {
        var status = GitSyncStatus(repositoryRoot: "/r", branch: "main", upstream: "origin/main")
        XCTAssertEqual(status.sync, .upToDate)
        status.behind = 4
        XCTAssertEqual(status.sync, .pull(4))
        status.behind = 0
        status.ahead = 1
        XCTAssertEqual(status.sync, .push(1))
        status.upstream = nil
        XCTAssertNil(status.sync, "no upstream and no remote: nothing to publish to")
        status.publishRemote = "origin"
        XCTAssertEqual(status.sync, .publish(remote: "origin"))
    }

    func testPublishRemotePrefersOriginThenTheOnlyRemote() {
        XCTAssertEqual(GitSyncStatus.publishRemote(from: ["upstream", "origin"]), "origin")
        XCTAssertEqual(GitSyncStatus.publishRemote(from: ["fork"]), "fork")
        XCTAssertNil(GitSyncStatus.publishRemote(from: ["a", "b"]), "two remotes, neither origin: ask the user")
        XCTAssertNil(GitSyncStatus.publishRemote(from: []))
    }

    /// The outside judge for the parse: real git, a real upstream, real counts.
    func testRealRepositoryAheadBehindAndDirty() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitsync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = base.appendingPathComponent("remote.git").path
        let one = base.appendingPathComponent("one").path
        let two = base.appendingPathComponent("two").path
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        try git(["init", "--bare", "-b", "main", remote], in: base.path)
        try git(["clone", remote, one], in: base.path)
        try commit("a.txt", "first", in: one)
        try git(["push", "-u", "origin", "main"], in: one)
        try git(["clone", remote, two], in: base.path)
        // `one` moves on twice; `two` once, and fetches — two behind, one ahead.
        try commit("b.txt", "second", in: one)
        try commit("c.txt", "third", in: one)
        try git(["push"], in: one)
        try commit("d.txt", "local", in: two)
        try git(["fetch"], in: two)
        try "dirty".write(toFile: two + "/a.txt", atomically: true, encoding: .utf8)
        try "new".write(toFile: two + "/e.txt", atomically: true, encoding: .utf8)

        let topLevel = await GitService.topLevel(of: two)
        let resolved = try XCTUnwrap(topLevel)
        let read = await GitService.syncStatus(in: resolved)
        let status = try XCTUnwrap(read)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.sync, .diverged(pull: 2, push: 1))
        XCTAssertEqual(status.changedFiles, 2)
        XCTAssertEqual(status.addedFiles, 1)

        let incoming = await GitService.syncRange(.incoming, against: "origin/main", in: resolved)
        XCTAssertEqual(incoming.files.map(\.path), ["b.txt", "c.txt"])
        XCTAssertEqual(incoming.commits.map(\.subject), ["third", "second"])
        let outgoing = await GitService.syncRange(.outgoing, against: "origin/main", in: resolved)
        XCTAssertEqual(outgoing.files.map(\.path), ["d.txt"])
        XCTAssertEqual(outgoing.commits.map(\.subject), ["local"])
        XCTAssertTrue(GitInspect.overlap(incoming: incoming.files, local: outgoing.files).isEmpty)

        // Upstream touches a file `two` has uncommitted edits to: the pull would refuse.
        try "upstream".write(toFile: one + "/a.txt", atomically: true, encoding: .utf8)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-am", "edit a"], in: one)
        try git(["push"], in: one)
        try git(["fetch"], in: two)
        let refetched = await GitService.syncRange(.incoming, against: "origin/main", in: resolved)
        let uncommitted = await GitService.changes(in: resolved)
        XCTAssertEqual(GitInspect.overlap(incoming: refetched.files, local: uncommitted), ["a.txt"])
    }

    func testOverlapCountsEitherSideOfARename() {
        let incoming = [GitChange(path: "new.swift", status: .renamed, isUntracked: false, originalPath: "old.swift")]
        let local = [GitChange(path: "old.swift", status: .modified, isUntracked: false)]
        XCTAssertEqual(GitInspect.overlap(incoming: incoming, local: local), ["old.swift"])
        XCTAssertTrue(GitInspect.overlap(incoming: [], local: local).isEmpty)
    }

    // MARK: Tree

    private func change(_ path: String, _ status: GitFileStatus = .modified) -> GitChange {
        GitChange(path: path, status: status, isUntracked: false)
    }

    func testTreeFoldsSingleFolderChainsAndOrdersFoldersFirst() {
        let tree = GitReviewTree.build([
            change("README.md"),
            change("Sources/fyolo/Git/Sync/A.swift"),
            change("Sources/fyolo/Git/Sync/B.swift"),
            change("Sources/fyolo/App/App.swift"),
            change("Tests/T.swift"),
        ])
        XCTAssertEqual(tree.map(\.name), ["Sources/fyolo", "Tests", "README.md"])
        let sources = tree[0]
        XCTAssertEqual(sources.id, "Sources/fyolo")
        XCTAssertEqual(sources.children.map(\.name), ["App", "Git/Sync"])
        XCTAssertEqual(sources.children[1].id, "Sources/fyolo/Git/Sync")
        XCTAssertEqual(Set(sources.filePaths), [
            "Sources/fyolo/Git/Sync/A.swift", "Sources/fyolo/Git/Sync/B.swift", "Sources/fyolo/App/App.swift",
        ])
    }

    func testVisibleRowsHideCollapsedFolders() {
        let tree = GitReviewTree.build([change("a/x.swift"), change("a/y.swift"), change("z.swift")])
        XCTAssertEqual(GitReviewTree.visibleRows(tree, collapsed: []).map(\.node.id),
                       ["a", "a/x.swift", "a/y.swift", "z.swift"])
        XCTAssertEqual(GitReviewTree.visibleRows(tree, collapsed: []).map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(GitReviewTree.visibleRows(tree, collapsed: ["a"]).map(\.node.id), ["a", "z.swift"])
    }

    // MARK: Helpers

    private func commit(_ file: String, _ message: String, in directory: String) throws {
        try message.write(toFile: directory + "/" + file, atomically: true, encoding: .utf8)
        try git(["add", file], in: directory)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", message], in: directory)
    }

    private func git(_ arguments: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
