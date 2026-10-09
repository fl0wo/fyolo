import FyoloShared
import XCTest

/// The daemon holds sessions and has never heard of a project, so the tree a
/// viewer draws is the *client's* to build. Three things have to hold for a list
/// that is pushed rather than polled: a session lands in the container it
/// actually belongs to, the ids that produces survive a second push unchanged —
/// a row whose id churns loses its place, its selection, and its open terminal
/// every time the device says anything — and `cwd` never decides anything.
final class FyolodRosterSynthesisTests: XCTestCase {
    private static let home = "/home/dev"

    private func session(
        id: String,
        cwd: String = "",
        project: String? = nil,
        agentID: String? = nil,
        createdUnix: UInt64 = 0
    ) throws -> Fyolod.SessionInformation {
        var fields: [String] = [
            #""id":"\#(id)""#,
            #""name":"\#(id)""#,
            #""cwd":"\#(cwd)""#,
            #""created_unix":\#(createdUnix)"#,
        ]
        if let project { fields.append(#""project":"\#(project)""#) }
        if let agentID { fields.append(#""agent_id":"\#(agentID)""#) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            Fyolod.SessionInformation.self,
            from: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    private func projects(
        _ sessions: [Fyolod.SessionInformation]
    ) -> [FyolodRoster.Project] {
        FyolodRoster.projects(from: sessions, homeDirectory: Self.home)
    }

    // MARK: - Classification

    /// P0.3's field is what makes this possible: the workstream's project is the
    /// only thing on the wire that says which checkout a session belongs to.
    func testTheWorkstreamProjectDecidesTheFolder() throws {
        let tree = projects([
            try session(id: "a", cwd: "/srv/repo/sub", project: "/srv/repo"),
            try session(id: "b", cwd: "/elsewhere", project: "/srv/repo"),
        ])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree.first?.kind, .folder)
        XCTAssertEqual(tree.first?.path, "/srv/repo")
        XCTAssertEqual(tree.first?.name, "repo")
        XCTAssertEqual(tree.first?.sessions.map(\.id), ["a", "b"])
    }

    /// A project files the session as a folder's whether or not an agent is
    /// running in it — `project` alone decides folder-vs-loose.
    func testAProjectWinsEvenForAnAgentSession() throws {
        let tree = projects([
            try session(id: "a", cwd: "/srv/repo", project: "/srv/repo", agentID: "claude"),
        ])
        XCTAssertEqual(tree.map(\.kind), [.folder])
        XCTAssertEqual(tree.first?.id, FyolodRoster.projectID(forRoot: "/srv/repo"))
    }

    /// No project, an agent: the workspace's Chats container, whose root is the
    /// scoped scratch directory an autonomous agent belongs in — never `$HOME`.
    func testALooseAgentSessionLandsInChats() throws {
        let tree = projects([try session(id: "a", cwd: "/home/dev", agentID: "claude")])
        XCTAssertEqual(tree.map(\.kind), [.chats])
        XCTAssertEqual(tree.first?.id, FyolodRoster.chatsProjectID)
        XCTAssertEqual(tree.first?.path, "/home/dev/.fyolo/chats")
    }

    /// **The regression this rule exists for.** A loose shell spawns at `$HOME`
    /// and then carries its own cwd wherever the user walks it, so a rule that
    /// fell back to `cwd` would file this one under a folder project named
    /// `fyolo` that nobody opened — and the Terminals tab would sit empty on a
    /// box full of shells. Every other test here passes under that wrong rule;
    /// this is the one that catches it.
    func testALooseShellStaysInTerminalsEvenAfterCdIntoARepo() throws {
        let tree = projects([
            try session(id: "a", cwd: "/Users/dev/code/fyolo"),
        ])
        XCTAssertEqual(tree.map(\.kind), [.terminals])
        XCTAssertEqual(tree.first?.id, FyolodRoster.terminalsProjectID)
        XCTAssertEqual(tree.first?.path, Self.home)
        XCTAssertEqual(tree.first?.name, "Terminals")
    }

    /// A workstream that has to carry a project spells "none" as the empty
    /// string, which has to read as loose rather than as a project named "".
    func testAnEmptyProjectIsLoose() throws {
        let tree = projects([try session(id: "a", cwd: "/srv/repo", project: "")])
        XCTAssertEqual(tree.map(\.kind), [.terminals])
    }

    // MARK: - Shape

    /// Terminals, then Chats, then the folders — the desktop's own emission
    /// order, so the phone's list reads the way the sidebar does.
    func testContainersComeBeforeFoldersInTheDesktopsOrder() throws {
        let tree = projects([
            try session(id: "folder", cwd: "/srv/two", project: "/srv/two"),
            try session(id: "chat", agentID: "claude"),
            try session(id: "shell", cwd: "/srv/one"),
        ])
        XCTAssertEqual(tree.map(\.kind), [.terminals, .chats, .folder])
    }

    /// An empty funnel is not shown: a box with no loose sessions has no
    /// Terminals or Chats container at all, the same rule
    /// `CompanionServer.companionRoster` follows.
    func testAnEmptyLooseContainerIsNotEmitted() throws {
        let tree = projects([try session(id: "a", cwd: "/srv/repo", project: "/srv/repo")])
        XCTAssertEqual(tree.map(\.kind), [.folder])
    }

    /// The daemon walks a hash map to answer `list`, so the same sessions come
    /// back in a different order every time; two pushes describing the same
    /// device must produce the same tree, ids included.
    func testTwoPushesOfTheSameSessionsProduceTheSameTree() throws {
        let sessions = [
            try session(id: "a", cwd: "/srv/one", project: "/srv/one", createdUnix: 10),
            try session(id: "b", cwd: "/srv/two", project: "/srv/two", createdUnix: 20),
            try session(id: "c", cwd: "/srv/one", project: "/srv/one", createdUnix: 30),
            try session(id: "d", agentID: "codex", createdUnix: 40),
            try session(id: "e", cwd: "/tmp", createdUnix: 50),
        ]
        let first = projects(sessions)
        let second = projects(sessions.reversed())
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(
            first.map { $0.sessions.map(\.id) },
            second.map { $0.sessions.map(\.id) }
        )
        XCTAssertEqual(first.map(\.id), [
            FyolodRoster.terminalsProjectID,
            FyolodRoster.chatsProjectID,
            FyolodRoster.projectID(forRoot: "/srv/one"),
            FyolodRoster.projectID(forRoot: "/srv/two"),
        ])
        XCTAssertEqual(first.last(where: { $0.kind == .folder })?.sessions.map(\.id), ["b"])
        XCTAssertEqual(first[2].sessions.map(\.id), ["a", "c"])
    }

    /// A project id has to be readable back into the path it addresses, because
    /// every file and spawn verb over there is scoped by an absolute path. The
    /// two container ids deliberately do not resolve here — their roots depend
    /// on the device's home directory, which the handshake supplies.
    func testAProjectIDRoundTripsToItsRoot() {
        let id = FyolodRoster.projectID(forRoot: "/srv/repo")
        XCTAssertEqual(FyolodRoster.root(ofProjectID: id), "/srv/repo")
        XCTAssertNil(FyolodRoster.root(ofProjectID: FyolodRoster.terminalsProjectID))
        XCTAssertNil(FyolodRoster.root(ofProjectID: FyolodRoster.chatsProjectID))
    }
}
