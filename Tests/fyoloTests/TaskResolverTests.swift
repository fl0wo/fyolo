import XCTest
@testable import fyolo

/// Group by Task's grouping rules (`TaskResolver`): what joins a task, what
/// never does, and that a row stays put as its task learns more about itself.
final class TaskResolverTests: XCTestCase {
    private typealias Member = TaskResolver.Member

    private func member(_ id: Session.ID = Session.ID(), folder: String? = nil, branch: String? = nil,
                        origin: Session.ID? = nil, splitGroup: Int? = nil,
                        mentions: [String] = [], override: TaskOverride? = nil) -> Member {
        Member(id: id, folder: folder, branch: branch, origin: origin, splitGroup: splitGroup,
               mentionedTickets: mentions, override: override)
    }

    func testSessionsOnOneBranchShareATask() {
        let agent = member(branch: "flo/eng-412-rate-limit")
        let shell = member(branch: "flo/eng-412-rate-limit")
        let layout = TaskResolver.layout(members: [agent, shell])
        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.groups.first?.sessionIDs, [agent.id, shell.id])
        XCTAssertEqual(layout.groups.first?.tickets, ["ENG-412"])
        XCTAssertEqual(layout.groups.first?.headline, "flo/eng-412-rate-limit")
        XCTAssertEqual(layout.groups.first?.ticketPrefix, "ENG-412")
        XCTAssertTrue(layout.loose.isEmpty)
    }

    /// Everything done on main would otherwise collapse into one task.
    func testTrunkNeverGroups() {
        let first = member(branch: "main")
        let second = member(branch: "main")
        let layout = TaskResolver.layout(members: [first, second])
        XCTAssertTrue(layout.groups.isEmpty)
        XCTAssertEqual(layout.loose, [first.id, second.id])
    }

    func testNoEvidenceStaysLoose() {
        let shell = member()
        XCTAssertEqual(TaskResolver.layout(members: [shell]).loose, [shell.id])
    }

    func testDifferentBranchesAreDifferentTasks() {
        let layout = TaskResolver.layout(members: [
            member(branch: "flo/eng-1-a"), member(branch: "chore/upgrade-node"),
        ])
        XCTAssertEqual(layout.groups.map(\.headline), ["flo/eng-1-a", "chore/upgrade-node"])
        XCTAssertEqual(layout.groups.last?.tickets, [], "chore/upgrade-node names no ticket")
    }

    /// Two branches naming one ticket are one piece of work.
    func testBranchesNamingOneTicketMerge() {
        let api = member(branch: "flo/eng-7-api")
        let ui = member(branch: "flo/eng-7-ui")
        let layout = TaskResolver.layout(members: [api, ui])
        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.groups.first?.branches, ["flo/eng-7-api", "flo/eng-7-ui"])
    }

    func testDetachedWorktreeGroupsByFolder() {
        let first = member(folder: "/repo-worktrees/spike")
        let second = member(folder: "/repo-worktrees/spike")
        let layout = TaskResolver.layout(members: [first, second])
        XCTAssertEqual(layout.groups.first?.headline, "spike")
        XCTAssertEqual(layout.groups.first?.sessionIDs.count, 2)
    }

    /// A shell split off an agent belongs with the agent, even when its own
    /// checkout (the main one, on trunk) says nothing.
    func testSplitFollowsItsOrigin() {
        let agent = member(folder: "/wt/a", branch: "feat/a")
        let shell = member(branch: "main", origin: agent.id)
        let layout = TaskResolver.layout(members: [agent, shell])
        XCTAssertEqual(layout.groups.first?.sessionIDs, [agent.id, shell.id])
    }

    func testClosedOriginFallsBackToOwnEvidence() {
        let shell = member(branch: "feat/b", origin: Session.ID())
        XCTAssertEqual(TaskResolver.layout(members: [shell]).groups.first?.headline, "feat/b")
    }

    func testSplitGroupMateJoins() {
        let agent = member(branch: "feat/a", splitGroup: 0)
        let shell = member(splitGroup: 0)
        let layout = TaskResolver.layout(members: [agent, shell])
        XCTAssertEqual(layout.groups.first?.sessionIDs, [agent.id, shell.id])
    }

    /// A chat on main whose prompt named a ticket joins that ticket's task.
    func testMentionPlacesAChatOnMain() {
        let worktree = member(folder: "/wt/412", branch: "flo/eng-412-x")
        let chat = member(branch: "main", mentions: ["ENG-412"])
        let layout = TaskResolver.layout(members: [worktree, chat])
        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.groups.first?.sessionIDs, [worktree.id, chat.id])
    }

    /// A weak mention places a session; it never fuses two tasks.
    func testMentionNeverMergesTasks() {
        let a = member(branch: "flo/eng-1-a")
        let b = member(branch: "flo/eng-2-b", mentions: ["ENG-1"])
        let layout = TaskResolver.layout(members: [a, b])
        XCTAssertEqual(layout.groups.count, 2)
        XCTAssertEqual(layout.group(containing: b.id)?.tickets, ["ENG-2"])
    }

    func testMentionWithoutATaskStartsOne() {
        let first = member(mentions: ["ENG-9"])
        let second = member(mentions: ["ENG-9"])
        let layout = TaskResolver.layout(members: [first, second])
        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.groups.first?.headline, "ENG-9")
        XCTAssertNil(layout.groups.first?.ticketPrefix)
    }

    func testOverrideWinsOverOwnBranch() {
        let target = member(branch: "feat/target")
        let moved = member(branch: "feat/other", override: .task("branch:feat/target"))
        let layout = TaskResolver.layout(members: [target, moved])
        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.groups.first?.sessionIDs, [target.id, moved.id])
    }

    /// Moving an old session into a task files it there without lifting the
    /// task above the ones listed before it.
    func testMovedSessionDoesNotReorderTasks() {
        let old = member(branch: "main", override: .task("branch:feat/b"))
        let a = member(branch: "feat/a")
        let b = member(branch: "feat/b")
        let layout = TaskResolver.layout(members: [old, a, b])
        XCTAssertEqual(layout.groups.map(\.headline), ["feat/a", "feat/b"])
        XCTAssertEqual(layout.group(containing: old.id)?.headline, "feat/b")
    }

    func testExcludedStaysLoose() {
        let excluded = member(branch: "feat/a", override: .excluded)
        let shell = member(branch: "main", origin: excluded.id)
        let layout = TaskResolver.layout(members: [excluded, shell])
        XCTAssertTrue(layout.groups.isEmpty)
        XCTAssertEqual(layout.loose, [excluded.id, shell.id])
    }

    /// Learning the pull request and ticket relabels the task; it doesn't move
    /// the row or change the task's identity.
    func testFactsRelabelWithoutMoving() {
        let agent = member(folder: "/wt/billing", branch: "flo/billing")
        let before = TaskResolver.layout(members: [agent])
        let facts = TaskFacts(
            pullRequests: [.init(number: 91, branch: "flo/billing",
                                 title: "ENG-430 ENG-431 billing export", isFinished: false)],
            tickets: [.init(identifier: "ENG-430", title: "Billing export",
                            branchName: nil, isFinished: false)])
        let after = TaskResolver.layout(members: [agent], facts: facts,
                                        pattern: TaskTicketPattern(teamKeys: ["ENG"]))
        XCTAssertEqual(before.groups.first?.id, after.groups.first?.id)
        XCTAssertEqual(after.groups.first?.tickets, ["ENG-430", "ENG-431"])
        XCTAssertEqual(after.groups.first?.title, "Billing export")
        XCTAssertEqual(after.groups.first?.pullRequests, [91])
    }

    /// The tracker's branch for a ticket ties a branch that never names it.
    func testTicketBranchNameLinks() {
        let a = member(branch: "flo/login")
        let b = member(branch: "flo/eng-5-login")
        let facts = TaskFacts(tickets: [.init(identifier: "ENG-5", title: "Login",
                                              branchName: "flo/login", isFinished: false)])
        XCTAssertEqual(TaskResolver.layout(members: [a, b], facts: facts).groups.count, 1)
    }

    func testFinishedTasksSink() {
        let done = member(branch: "flo/eng-1-done")
        let open = member(branch: "flo/eng-2-open")
        let facts = TaskFacts(pullRequests: [.init(number: 1, branch: "flo/eng-1-done",
                                                   title: "ENG-1", isFinished: true)])
        let layout = TaskResolver.layout(members: [done, open], facts: facts)
        XCTAssertEqual(layout.groups.map(\.isFinished), [false, true])
    }

    func testHeuristicPatternRefusesLookAlikes() {
        let pattern = TaskTicketPattern()
        XCTAssertEqual(pattern.identifiers(inBranch: "flo/eng-412-rate-limit"), ["ENG-412"])
        XCTAssertEqual(pattern.identifiers(inBranch: "ENG-7"), ["ENG-7"])
        XCTAssertEqual(pattern.identifiers(inBranch: "fix/utf-8-decoding"), [])
        XCTAssertEqual(pattern.identifiers(inBranch: "fix-123-crash"), [])
        XCTAssertEqual(pattern.identifiers(inBranch: "feat/upgrade-react-18"), [])
        XCTAssertEqual(pattern.identifiers(inText: "please fix ENG-412, see UTF-8 notes"), ["ENG-412"])
        XCTAssertEqual(pattern.identifiers(inText: "lowercase eng-412 isn't a ticket"), [])
        XCTAssertEqual(pattern.identifiers(inText: "https://linear.app/acme/issue/eng-12/title"),
                       ["ENG-12"])
    }
}
