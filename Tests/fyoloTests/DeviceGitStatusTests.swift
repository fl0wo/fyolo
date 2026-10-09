import FyoloShared
import XCTest
@testable import fyolo

/// The device's `git_changed` batch, decoded into the rows the Changes pane
/// draws.
///
/// This is the seam where a remote pane could silently lie: the wire carries the
/// two-axis porcelain-v2 status, and the row shows one letter, a `+N −M`, and a
/// staged dot. Get the collapse wrong and the pane looks plausible and says the
/// wrong thing about someone's working tree. The fixtures below are what
/// `fyolod/src/git.rs` actually serializes.
final class DeviceGitStatusTests: XCTestCase {
    private func batch(_ json: String) throws -> Fyolod.GitChangedPayload {
        try Fyolod.decodeGitChanged(Data(json.utf8))
    }

    func testATrackedWorktreeEditReadsAsModified() throws {
        let payload = try batch("""
        {"ev":"git_changed","resource":"git:/repo","seq":3,"updated_statuses":[
          {"path":"src/main.rs",
           "status":{"tracked":{"index_status":"unmodified","worktree_status":"modified"}},
           "additions":12,"deletions":3}
        ]}
        """)
        let change = try XCTUnwrap(GitChange(device: payload.updatedStatuses[0]))
        XCTAssertEqual(change.path, "src/main.rs")
        XCTAssertEqual(change.status, .modified)
        XCTAssertEqual(change.additions, 12)
        XCTAssertEqual(change.deletions, 3)
        XCTAssertFalse(change.isStaged, "the worktree still holds the edit")
        XCTAssertFalse(change.isUntracked)
    }

    /// The dot on the row means "a `git commit` in the terminal would take this
    /// file". That is exactly index-moved and worktree-clean, and nothing else.
    func testOnlyAnIndexOnlyChangeCountsAsStaged() throws {
        let payload = try batch("""
        {"ev":"git_changed","seq":1,"updated_statuses":[
          {"path":"staged.rs",
           "status":{"tracked":{"index_status":"modified","worktree_status":"unmodified"}}},
          {"path":"both.rs",
           "status":{"tracked":{"index_status":"modified","worktree_status":"modified"}}}
        ]}
        """)
        let staged = try XCTUnwrap(GitChange(device: payload.updatedStatuses[0]))
        let both = try XCTUnwrap(GitChange(device: payload.updatedStatuses[1]))
        XCTAssertTrue(staged.isStaged)
        XCTAssertFalse(both.isStaged, "a file with more in the worktree is not staged")
    }

    /// The worktree axis wins when it moved — a file added to the index and then
    /// deleted on disk is a deletion, which is what the letter has to say.
    func testTheWorktreeAxisWinsWhenItMoved() throws {
        let payload = try batch("""
        {"ev":"git_changed","seq":1,"updated_statuses":[
          {"path":"gone.rs",
           "status":{"tracked":{"index_status":"added","worktree_status":"deleted"}}}
        ]}
        """)
        let change = try XCTUnwrap(GitChange(device: payload.updatedStatuses[0]))
        XCTAssertEqual(change.status, .deleted)
    }

    func testUntrackedAndConflictedAndRenamedSurvive() throws {
        let payload = try batch("""
        {"ev":"git_changed","seq":1,"updated_statuses":[
          {"path":"fresh.txt","status":"untracked","additions":4},
          {"path":"clash.rs","status":{"unmerged":{"first_head":"updated","second_head":"updated"}}},
          {"path":"new-name.rs","original_path":"old-name.rs",
           "status":{"tracked":{"index_status":"renamed","worktree_status":"unmodified"}}}
        ]}
        """)
        let fresh = try XCTUnwrap(GitChange(device: payload.updatedStatuses[0]))
        XCTAssertEqual(fresh.status, .untracked)
        XCTAssertTrue(fresh.isUntracked)
        XCTAssertEqual(fresh.additions, 4)

        let clash = try XCTUnwrap(GitChange(device: payload.updatedStatuses[1]))
        XCTAssertEqual(clash.status, .conflicted)

        let renamed = try XCTUnwrap(GitChange(device: payload.updatedStatuses[2]))
        XCTAssertEqual(renamed.status, .renamed)
        XCTAssertEqual(renamed.originalPath, "old-name.rs",
                       "the row's `old → new` tooltip needs where it came from")
    }

    /// An ignored file is not a row — the local parser drops `!` records for the
    /// same reason — and neither is a status this build has never heard of. A
    /// guess would be drawn as fact.
    func testIgnoredAndUnknownStatusesAreNotRows() throws {
        let payload = try batch("""
        {"ev":"git_changed","seq":1,"updated_statuses":[
          {"path":"target/debug","status":"ignored"},
          {"path":"future.rs","status":"teleported"}
        ]}
        """)
        XCTAssertNil(GitChange(device: payload.updatedStatuses[0]))
        XCTAssertNil(GitChange(device: payload.updatedStatuses[1]))
    }

    /// One unreadable row must not sink the batch: the rest of the list, the
    /// branch, and the removals still have to arrive.
    func testTheRestOfABatchSurvivesAnUnreadableRow() throws {
        let payload = try batch("""
        {"ev":"git_changed","seq":9,"updated_statuses":[
          {"path":"future.rs","status":"teleported"},
          {"path":"real.rs","status":{"tracked":{"index_status":"unmodified","worktree_status":"modified"}}}
        ],"removed_paths":["fixed.rs"],"branch":"main","head":"abc123","ahead_behind":[2,1],
        "conflicts":["clash.rs"]}
        """)
        XCTAssertEqual(payload.seq, 9)
        XCTAssertEqual(payload.branch, "main")
        XCTAssertEqual(payload.ahead, 2)
        XCTAssertEqual(payload.behind, 1)
        XCTAssertEqual(payload.removedPaths, ["fixed.rs"])
        XCTAssertEqual(payload.conflicts, ["clash.rs"])
        XCTAssertNotNil(GitChange(device: payload.updatedStatuses[1]))
    }

    /// Counts are left off the wire when they are zero, and a binary file has no
    /// numbers at all rather than `+0 −0`.
    func testAbsentCountsAreZeroAndBinaryIsCarried() throws {
        let payload = try batch("""
        {"ev":"git_changed","seq":1,"updated_statuses":[
          {"path":"blob.bin","status":"untracked","binary":true}
        ]}
        """)
        let change = try XCTUnwrap(GitChange(device: payload.updatedStatuses[0]))
        XCTAssertTrue(change.isBinary)
        XCTAssertEqual(change.additions, 0)
        XCTAssertEqual(change.deletions, 0)
    }
}
