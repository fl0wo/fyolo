import XCTest
@testable import fyolo

/// Which repository the Issues pane binds a checkout to. A fork clone has more than
/// one GitHub remote, and picking the wrong one leaves the pane empty against a repo
/// whose issues are disabled (#427) — so the ordering and the slug parsing that feed
/// the choice are worth pinning down without a window.
final class IssueRepositoryBindingTests: XCTestCase {
    func testUpstreamOutranksOriginWhichOutranksEverythingElse() {
        XCTAssertEqual(
            GitService.orderedRemoteNames(["origin", "fork", "upstream"]),
            ["upstream", "origin", "fork"])
    }

    func testRemotesWithoutAConventionalNameStayAlphabetical() {
        // A stable order matters: the repository menu is rebuilt on every session
        // switch, and a set-derived order would reshuffle an unchanged repo's list.
        XCTAssertEqual(
            GitService.orderedRemoteNames(["zed", "alice", "bob"]),
            ["alice", "bob", "zed"])
    }

    func testOrderingIsUnchangedByTheOrderGitListedThem() {
        let names = ["bob", "upstream", "alice", "origin"]
        XCTAssertEqual(
            GitService.orderedRemoteNames(names),
            GitService.orderedRemoteNames(names.reversed()))
    }

    func testSlugParsesEveryTransportGitAcceptsForGitHub() {
        for remote in [
            "https://github.com/fl0wo/fyolo.git",
            "https://github.com/fl0wo/fyolo",
            "git@github.com:fl0wo/fyolo.git",
            "ssh://git@github.com/fl0wo/fyolo.git",
            "https://user@github.com/fl0wo/fyolo.git",
        ] {
            XCTAssertEqual(
                GitService.gitHubSlug(fromRemote: remote), "fl0wo/fyolo",
                "failed for \(remote)")
        }
    }

    // MARK: The resolution ladder

    private func candidate(_ slug: String, _ remote: String?) -> IssueRepositoryCandidate {
        IssueRepositoryCandidate(slug: slug, remoteName: remote)
    }

    /// A probe that fails the test if the ladder reaches it — the rungs above it are
    /// supposed to short-circuit, and a stray network round-trip per pane mount is
    /// the cost of getting that wrong.
    private func unreachableProbe(_ slug: String) async -> String? {
        XCTFail("the fork-parent probe should not have run for \(slug)")
        return nil
    }

    @MainActor
    func testUpstreamWinsWithoutProbing() async {
        let binding = await IssuesPanelModel.resolveBinding(
            remotes: [
                candidate("fl0wo/fyolo", "upstream"),
                candidate("planetf1/fyolo", "origin"),
            ],
            pick: nil, forkParent: unreachableProbe)
        XCTAssertEqual(binding?.selected.slug, "fl0wo/fyolo")
        XCTAssertEqual(binding?.candidates.count, 2)
    }

    @MainActor
    func testExplicitPickOutranksUpstream() async {
        // Having chosen the fork's own tracker, the user must keep it.
        let binding = await IssuesPanelModel.resolveBinding(
            remotes: [
                candidate("fl0wo/fyolo", "upstream"),
                candidate("planetf1/fyolo", "origin"),
            ],
            pick: "planetf1/fyolo", forkParent: unreachableProbe)
        XCTAssertEqual(binding?.selected.slug, "planetf1/fyolo")
    }

    @MainActor
    func testExplicitPickSurvivesTheRemoteItCameFrom() async {
        // The remote was renamed or dropped: the pick still binds, and stays switchable
        // rather than collapsing to a one-entry menu the pane hides.
        let binding = await IssuesPanelModel.resolveBinding(
            remotes: [candidate("planetf1/fyolo", "origin")],
            pick: "fl0wo/fyolo", forkParent: unreachableProbe)
        XCTAssertEqual(binding?.selected.slug, "fl0wo/fyolo")
        XCTAssertEqual(binding?.candidates.map(\.slug), ["planetf1/fyolo", "fl0wo/fyolo"])
    }

    @MainActor
    func testExplicitPickBindsEvenWithNoGitHubRemoteLeft() async {
        let binding = await IssuesPanelModel.resolveBinding(
            remotes: [], pick: "fl0wo/fyolo", forkParent: unreachableProbe)
        XCTAssertEqual(binding?.selected.slug, "fl0wo/fyolo")
        XCTAssertEqual(binding?.candidates.map(\.slug), ["fl0wo/fyolo"])
    }

    @MainActor
    func testForkParentIsDiscoveredAndBecomesASecondCandidate() async {
        // #427's harder half: the only remote is the user's fork, so nothing in the
        // checkout names the real tracker. The menu must appear so the user can go back.
        let binding = await IssuesPanelModel.resolveBinding(
            remotes: [candidate("planetf1/fyolo", "origin")],
            pick: nil, forkParent: { _ in "fl0wo/fyolo" })
        XCTAssertEqual(binding?.selected.slug, "fl0wo/fyolo")
        XCTAssertEqual(binding?.candidates.map(\.slug), ["planetf1/fyolo", "fl0wo/fyolo"])
    }

    @MainActor
    func testANonForkStaysOnOriginWithNoMenu() async {
        let binding = await IssuesPanelModel.resolveBinding(
            remotes: [candidate("fl0wo/fyolo", "origin")],
            pick: nil, forkParent: { _ in nil })
        XCTAssertEqual(binding?.selected.slug, "fl0wo/fyolo")
        XCTAssertEqual(binding?.candidates.count, 1, "one candidate keeps the picker hidden")
    }

    @MainActor
    func testAFailedProbeFallsBackToOriginRatherThanUnbinding() async {
        // The probe reports nothing (offline, rate-limited). The pane still shows a
        // tracker; `forkParentUnknown` is what gets the user out on Refresh.
        let binding = await IssuesPanelModel.resolveBinding(
            remotes: [candidate("planetf1/fyolo", "origin")],
            pick: nil, forkParent: { _ in nil })
        XCTAssertEqual(binding?.selected.slug, "planetf1/fyolo")
    }

    @MainActor
    func testNoRemotesAndNoPickLeavesThePaneUnbound() async {
        let binding = await IssuesPanelModel.resolveBinding(
            remotes: [], pick: nil, forkParent: unreachableProbe)
        XCTAssertNil(binding)
    }

    @MainActor
    func testADiscoveredParentAlreadyOnARemoteIsNotDuplicated() async {
        let binding = await IssuesPanelModel.resolveBinding(
            remotes: [
                candidate("planetf1/fyolo", "origin"),
                candidate("fl0wo/fyolo", "mirror"),
            ],
            pick: nil, forkParent: { _ in "fl0wo/fyolo" })
        XCTAssertEqual(binding?.selected.remoteName, "mirror")
        XCTAssertEqual(binding?.candidates.count, 2)
    }

    // MARK: Against a real checkout

    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("fyolo-issue-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }

    func testForkCheckoutOffersUpstreamFirst() async throws {
        try git(["remote", "add", "origin", "https://github.com/planetf1/fyolo.git"])
        try git(["remote", "add", "upstream", "git@github.com:fl0wo/fyolo.git"])
        try git(["remote", "add", "backup", "https://gitlab.com/planetf1/fyolo.git"])

        let remotes = await GitService.gitHubRemotes(in: repo.path)
        // The GitLab remote is dropped; upstream leads, which is what makes the pane
        // land on the project's real tracker instead of the fork's empty one.
        XCTAssertEqual(
            remotes,
            [
                GitService.GitHubRemote(name: "upstream", slug: "fl0wo/fyolo"),
                GitService.GitHubRemote(name: "origin", slug: "planetf1/fyolo"),
            ])
    }

    func testRemotesPointingAtOneRepositoryCollapse() async throws {
        // The same repo over both transports is one choice, not two — and it keeps the
        // higher-priority name.
        try git(["remote", "add", "origin", "https://github.com/fl0wo/fyolo.git"])
        try git(["remote", "add", "upstream", "git@github.com:fl0wo/fyolo.git"])

        let remotes = await GitService.gitHubRemotes(in: repo.path)
        XCTAssertEqual(
            remotes, [GitService.GitHubRemote(name: "upstream", slug: "fl0wo/fyolo")])
    }

    func testRepoWithNoGitHubRemoteResolvesToNothing() async throws {
        try git(["remote", "add", "origin", "https://gitlab.com/planetf1/fyolo.git"])
        let remotes = await GitService.gitHubRemotes(in: repo.path)
        XCTAssertTrue(remotes.isEmpty, "a non-GitHub checkout must leave the pane unbound")
    }

    func testExplicitPickRoundTripsThroughGitConfig() async throws {
        let unset = await GitService.issuesRepository(in: repo.path)
        XCTAssertNil(unset, "an untouched repo must stay on the resolution ladder")

        await GitService.setIssuesRepository("fl0wo/fyolo", in: repo.path)
        let stored = await GitService.issuesRepository(in: repo.path)
        XCTAssertEqual(stored, "fl0wo/fyolo")
    }

    func testSlugRejectsOtherForges() {
        // An HTTPS remote must never reach `ssh -G`, so a lookalike host stays nil
        // rather than binding an unrelated repo to public GitHub.
        for remote in [
            "https://gitlab.com/fl0wo/fyolo.git",
            "https://github.example.com/fl0wo/fyolo.git",
            "git@codeberg.org:fl0wo/fyolo.git",
            "not a remote",
            // Paths that aren't a plain owner/repo: each would interpolate into a URL
            // that is nil at the point of use, and the API callers force-unwrap it.
            "https://github.com/owner/%",
            "https://github.com/owner/repo/extra",
            "https://github.com/owner",
            "https://github.com/owner/re po",
        ] {
            XCTAssertNil(GitService.gitHubSlug(fromRemote: remote), "failed for \(remote)")
        }
    }

    /// A remount builds a fresh model, and its first frame draws before `start()` has
    /// read anything — that frame must be covered, not a Connect screen.
    @MainActor
    func testFreshModelIsUnsettledUntilItHasCheckedAnything() {
        let model = IssuesPanelModel(repoRoot: "/nonexistent")
        XCTAssertEqual(model.phase, .resolving)
        XCTAssertFalse(model.isSettled)
    }
}
