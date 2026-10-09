import XCTest
@testable import fyolo

/// What the automatic reconcile does to a repository, against a real one.
///
/// The answer has to be *nothing*: it is a background pass, triggered by a
/// branch-watcher event or the app coming forward, with no user behind it.
/// `git worktree remove` on a path that is missing deletes that worktree's HEAD,
/// index, per-worktree refs and reflogs — and a folder that is merely
/// unreachable, an unmounted share or a cloud provider that is not running,
/// looks exactly like a deleted one from here. So the pass reports a vanished
/// checkout and leaves the deregistering to the user's own Remove.
final class WorktreeReconcileGitTests: XCTestCase {
    private var root: URL!
    private var repo: URL { root.appendingPathComponent("repo") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "--quiet"])
        try git(["commit", "--quiet", "--allow-empty", "-m", "init"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Every registration survives the pass, whatever shape its checkout is in,
    /// and each unusable one is reported so its row keeps its place.
    func testTheAutomaticPassDeregistersNothing() async throws {
        for name in ["gone", "work", "empty", "locked"] {
            try git(["worktree", "add", "--quiet", "-b", name, worktree(name).path, "HEAD"])
        }
        try FileManager.default.removeItem(at: worktree("gone"))
        // Its `.git` gitfile deleted with the work still there: git calls this
        // prunable, and those files are exactly what must survive.
        try "uncommitted".write(to: worktree("work").appendingPathComponent("draft.txt"),
                                atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: worktree("work").appendingPathComponent(".git"))
        try FileManager.default.removeItem(at: worktree("empty"))
        try FileManager.default.createDirectory(at: worktree("empty"), withIntermediateDirectories: true)
        try git(["worktree", "lock", worktree("locked").path])
        try FileManager.default.removeItem(at: worktree("locked"))

        let reconciled = await WorktreeService.reconcile(in: repo.path, against: [])
        let plan = try XCTUnwrap(reconciled)

        // Compared canonically, because git prints realpaths and the temporary
        // directory these live under is reached through a symlink.
        let registered = try registeredPaths()
        for name in ["gone", "work", "empty", "locked"] {
            XCTAssertTrue(registered.contains(key(name)),
                          "\(name) must still be registered after an automatic pass")
        }
        // Nothing on disk is touched either.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: worktree("work").appendingPathComponent("draft.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree("empty").path))
        XCTAssertTrue(try branches().contains("gone"))

        // What it does instead: every one git cannot offer is reported stale, so a
        // row for it keeps its place and the user can reach the removal. None of
        // these four is usable — each had its folder deleted or its `.git` taken
        // away — so none is offered as a worktree to open.
        let stale = Set(plan.stale.map(WorktreeService.canonicalPath))
        for name in ["gone", "work", "empty", "locked"] {
            XCTAssertTrue(stale.contains(key(name)), "\(name) must be reported as stale")
        }
        XCTAssertTrue(plan.discovered.isEmpty, "\(plan.discovered)")
    }

    /// Stale is not the same question as having nowhere to work. git calls a
    /// worktree prunable the moment its `.git` gitfile goes, with every one of the
    /// user's files still sitting there — and a terminal opened in that folder is
    /// exactly how they get those files out. Marking it absent took the verbs away
    /// while the removal refused with advice that would have deleted the work.
    func testAFolderThatStillHoldsFilesIsStaleButNotAbsent() async throws {
        try git(["worktree", "add", "--quiet", "-b", "work", worktree("work").path, "HEAD"])
        try "uncommitted".write(to: worktree("work").appendingPathComponent("draft.txt"),
                                atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: worktree("work").appendingPathComponent(".git"))

        try git(["worktree", "add", "--quiet", "-b", "vanished", worktree("vanished").path, "HEAD"])
        try FileManager.default.removeItem(at: worktree("vanished"))

        let reconciled = await WorktreeService.reconcile(in: repo.path, against: [])
        let plan = try XCTUnwrap(reconciled)
        let stale = Set(plan.stale.map(WorktreeService.canonicalPath))
        let absent = Set(plan.absent.map(WorktreeService.canonicalPath))

        // Neither can be offered as a worktree to open…
        XCTAssertTrue(stale.contains(key("work")))
        XCTAssertTrue(stale.contains(key("vanished")))
        // …but only one of them has nowhere to work.
        XCTAssertFalse(absent.contains(key("work")), "its folder and the user's files are right there")
        XCTAssertTrue(absent.contains(key("vanished")))
    }

    /// A healthy worktree is offered to open and is not reported stale — the
    /// distinction the row-keeping rests on.
    func testAHealthyWorktreeIsOfferedRatherThanReportedStale() async throws {
        try git(["worktree", "add", "--quiet", "-b", "live", worktree("live").path, "HEAD"])
        let reconciled = await WorktreeService.reconcile(in: repo.path, against: [])
        let plan = try XCTUnwrap(reconciled)
        XCTAssertEqual(plan.discovered.map(WorktreeService.canonicalPath), [key("live")])
        XCTAssertTrue(plan.stale.isEmpty, "\(plan.stale)")
    }

    /// And the probe the removal leans on still fails closed: a path whose volume
    /// is not mounted answers "no such file" for everything on it, which must not
    /// read as a checkout someone deleted.
    func testAnUnmountedVolumeIsNotMistakenForADeletedCheckout() {
        XCTAssertEqual(
            WorktreeService.folderEvidence(at: "/Volumes/FyoloNoSuchVolume/repo-wt"),
            .unreadable)
    }

    // MARK: Helpers

    private func worktree(_ name: String) -> URL {
        root.appendingPathComponent("wt-\(name)")
    }

    private func key(_ name: String) -> String {
        WorktreeService.canonicalPath(worktree(name).path)
    }

    private func registeredPaths() throws -> [String] {
        (WorktreeService.records(in: repo.path) ?? []).map { WorktreeService.canonicalPath($0.path) }
    }

    private func branches() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "branch", "--format=%(refname:short)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }
}
