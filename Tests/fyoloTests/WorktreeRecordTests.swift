import XCTest
@testable import fyolo

/// `WorktreeService.records(from:)` is what `removeWorktree` decides on: which
/// checkout git still knows, whether git itself judges it gone (`prunable`),
/// whether git refuses to let go of it (`locked`), and which branch to tidy.
/// The fixtures are verbatim `git worktree list --porcelain` output.
final class WorktreeRecordTests: XCTestCase {
    func testRecordsCarryEveryAttributeTheRemovalDecidesOn() {
        let listing = """
        worktree /Users/u/repo
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/main

        worktree /Users/u/wt-healthy
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/feature-1

        worktree /Users/u/wt-locked
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/feature-2
        locked

        worktree /Users/u/wt-gone
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/feature-3
        prunable gitdir file points to non-existent location

        worktree /Users/u/wt-detached
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        detached
        """
        let records = WorktreeService.records(from: listing)
        XCTAssertEqual(records.count, 5)
        XCTAssertEqual(records[0].path, "/Users/u/repo")
        XCTAssertEqual(records[0].branch, "main")

        XCTAssertEqual(records[1].branch, "feature-1")
        XCTAssertFalse(records[1].prunable)
        XCTAssertFalse(records[1].locked)

        XCTAssertTrue(records[2].locked)
        XCTAssertFalse(records[2].prunable)

        XCTAssertTrue(records[3].prunable)
        XCTAssertEqual(records[3].branch, "feature-3")

        // A detached HEAD has no branch to tidy — nil, not a sentinel string.
        XCTAssertNil(records[4].branch)
    }

    /// Verbatim output for a locked worktree whose folder was deleted (git 2.47):
    /// git marks it `locked` and *not* `prunable`, which is why `removeWorktree`
    /// has to test `locked` before it branches on `prunable` — inside that branch
    /// the check could never fire, and a checkout on unplugged removable media
    /// would take the deregistration path instead of the locked message.
    func testALockedWorktreeIsNeverMarkedPrunableEvenWithItsFolderGone() {
        let listing = """
        worktree /Users/u/repo
        HEAD 1a96c165970cec53355f4dc6c1b58b2fa79850ae
        branch refs/heads/main

        worktree /Users/u/w1
        HEAD 1a96c165970cec53355f4dc6c1b58b2fa79850ae
        branch refs/heads/b1
        locked
        """
        let records = WorktreeService.records(from: listing)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[1].locked)
        XCTAssertFalse(records[1].prunable)
    }

    /// The removal matches a sidebar row against git's own records by canonical
    /// path, and it has to keep matching after the folder is deleted — which is
    /// the case the whole feature exists for.
    ///
    /// A worktree under a symlinked ancestor is stored with the spelling that
    /// created it while git prints the resolved one. Canonicalizing the leaf
    /// alone worked only while the folder existed: `resolvingSymlinksInPath`
    /// returns a missing path unchanged, so the two stopped matching the moment
    /// the folder went, the record read as absent, and the row was dropped while
    /// git kept the registration for good — the branch never tidied, the row
    /// never coming back to retry, and a later `git worktree add` at that path
    /// refused as "already registered".
    func testAPathKeepsOneSpellingAfterItsFolderIsDeleted() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-canon-\(ProcessInfo.processInfo.processIdentifier)")
        try? manager.removeItem(at: root)
        try manager.createDirectory(at: root.appendingPathComponent("real/wts/w1"),
                                    withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: root.appendingPathComponent("linked"),
                                       withDestinationURL: root.appendingPathComponent("real"))
        defer { try? manager.removeItem(at: root) }

        // What the sidebar row keeps, and what `git worktree list` prints.
        let stored = root.appendingPathComponent("linked/wts/w1").path
        let git = root.appendingPathComponent("real/wts/w1").path
        XCTAssertEqual(WorktreeService.canonicalPath(stored), WorktreeService.canonicalPath(git))

        // The folder is deleted by another tool: they must still agree.
        try manager.removeItem(at: root.appendingPathComponent("real/wts/w1"))
        XCTAssertEqual(WorktreeService.canonicalPath(stored), WorktreeService.canonicalPath(git))

        // And with the directories above it gone too.
        try manager.removeItem(at: root.appendingPathComponent("real/wts"))
        XCTAssertEqual(WorktreeService.canonicalPath(stored), WorktreeService.canonicalPath(git))

        // Including when what the symlink points at is itself deleted, so the
        // link dangles. `resolvingSymlinksInPath` gives up there, which used to
        // make the row unmatchable against git's record — and an unmatchable row
        // is the one that gets dropped while git keeps its registration for good.
        try manager.removeItem(at: root.appendingPathComponent("real"))
        XCTAssertEqual(WorktreeService.canonicalPath(stored), WorktreeService.canonicalPath(git))

        // A link pointing at itself terminates rather than spinning.
        let loop = root.appendingPathComponent("loop")
        try manager.createSymbolicLink(at: loop, withDestinationURL: loop)
        XCTAssertFalse(WorktreeService.canonicalPath(loop.appendingPathComponent("w1").path).isEmpty)

        // Different worktrees still read as different ones.
        XCTAssertNotEqual(
            WorktreeService.canonicalPath(root.appendingPathComponent("real/wts/w1").path),
            WorktreeService.canonicalPath(root.appendingPathComponent("real/wts/w2").path)
        )
    }

    /// The disk is the only witness left once git cannot inspect a checkout, so
    /// this probe decides whether a worktree may be deregistered and its sessions
    /// closed. Every failure has to land on the refusing side: a folder nothing
    /// could read is not a folder known to be empty.
    func testFolderEvidenceFailsClosedOnAFolderItCannotRead() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-evidence-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unreadable = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try "uncommitted work".write(
            to: unreadable.appendingPathComponent("draft.swift"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path) }

        // Running as root defeats the permission bits, so the denial this asserts
        // on would not happen; the case is real for the user the app runs as.
        try XCTSkipIf(getuid() == 0, "root reads a 000 directory")
        XCTAssertEqual(WorktreeService.folderEvidence(at: unreadable.path), .unreadable)
    }

    func testFolderEvidenceSeparatesAnEmptyCheckoutFromOneHoldingWork() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-evidence-shapes-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Deleted out from under git: nothing to lose, and nothing to clear.
        XCTAssertEqual(
            WorktreeService.folderEvidence(at: root.appendingPathComponent("gone").path),
            .gone
        )

        // Emptied and recreated, including the one Finder leaves behind. This is
        // the shape that has to be cleared before git will deregister it.
        let emptied = root.appendingPathComponent("emptied")
        try FileManager.default.createDirectory(at: emptied, withIntermediateDirectories: true)
        XCTAssertEqual(WorktreeService.folderEvidence(at: emptied.path), .emptyFolder)
        try "".write(to: emptied.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WorktreeService.folderEvidence(at: emptied.path), .emptyFolder)

        // The `.git` gitfile deleted with the work still there: git marks this
        // prunable, and the files are exactly what must not be let go of.
        let working = root.appendingPathComponent("working")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try "uncommitted".write(
            to: working.appendingPathComponent("draft.swift"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(WorktreeService.folderEvidence(at: working.path), .mayHoldWork)

        // A path that is no longer a directory holds no checkout — but it is not
        // ours to delete either, and `rmdir` would fail `ENOTDIR` on it, so it
        // is kept apart from the shapes the removal may clear. git refuses to
        // deregister a worktree whose path exists without a `.git` in it
        // (`--force` included), so this one can only be reported with a remedy.
        let replaced = root.appendingPathComponent("replaced")
        try "not a checkout".write(to: replaced, atomically: true, encoding: .utf8)
        XCTAssertEqual(WorktreeService.folderEvidence(at: replaced.path), .occupied)

        // An unmounted volume answers "no such file" for everything on it. That
        // must not read as a deleted checkout: the worktree is still on the
        // drive, and letting go of it would deregister work that is merely
        // unplugged.
        XCTAssertEqual(
            WorktreeService.folderEvidence(at: "/Volumes/FyoloNoSuchVolume/repo-wt"),
            .unreadable
        )
        // A volume that *is* mounted still reports a genuinely deleted checkout
        // as gone — the root volume stands in for one here.
        XCTAssertEqual(
            WorktreeService.folderEvidence(at: root.appendingPathComponent("still-gone").path),
            .gone
        )

        // A symlink is `.occupied` too, and deliberately not followed: whatever
        // is on the other side was never part of the checkout, and classifying
        // it by its target would authorize clearing a directory nothing here
        // inspected.
        let linked = root.appendingPathComponent("linked")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        XCTAssertEqual(WorktreeService.folderEvidence(at: linked.path), .occupied)
    }

    func testABareEntryIsMarkedAndALockReasonStillReadsAsLocked() {
        let listing = """
        worktree /Users/u/repo.git
        bare

        worktree /Users/u/wt
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/main
        locked on an external drive
        """
        let records = WorktreeService.records(from: listing)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].bare)
        XCTAssertNil(records[0].branch)
        XCTAssertTrue(records[1].locked)
    }
}
