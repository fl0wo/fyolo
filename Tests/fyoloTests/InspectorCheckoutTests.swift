import XCTest
@testable import fyolo

/// The inspector's checkout derivation (`FyoloStore.checkout(for:in:…)`).
///
/// The case that matters is destructive rather than cosmetic: a session running
/// on another machine used to resolve to the local project's path, so the Files,
/// Search, Changes, and Issues panes showed this Mac's filesystem under a shell
/// on someone else's box. Every test here asserts that a checkout on another
/// device offers this Mac nothing to read.
@MainActor
final class InspectorCheckoutTests: XCTestCase {
    private func project(_ path: String, checkouts: [String: String] = [:]) -> Project {
        var project = Project(
            workspaceID: UUID(), name: "repo", path: path, branch: "main", sessions: [])
        project.remoteCheckouts = checkouts
        return project
    }

    private func derive(_ session: Session, in project: Project?,
                        localRoot: String?, liveWorkingDirectory: String? = nil,
                        routeDeviceID: String? = nil) -> Checkout {
        FyoloStore.checkout(for: session, in: project, localRoot: localRoot,
                             liveWorkingDirectory: liveWorkingDirectory,
                             routeDeviceID: routeDeviceID)
    }

    /// The defect itself: a fyolod session filed under the local project it was
    /// opened from has no `sshHost`, so it used to match no remote branch and fall
    /// through to the Mac's path.
    func testRemoteSessionUnderALocalProjectOffersNoLocalRoot() {
        var session = Session(title: "ukvps", agent: .terminal)
        session.fyolodRemoteHost = "ukvps"
        session.deviceID = "device-a"
        session.fyolodRemoteCwd = "/srv/api"

        let checkout = derive(session, in: project("/Users/me/api"), localRoot: "/Users/me/api")

        XCTAssertNil(checkout.localRoot, "a session on another box may never read this Mac")
        XCTAssertTrue(checkout.isOnAnotherDevice)
        XCTAssertEqual(checkout.device.name, "ukvps", "the empty state names the machine")
        XCTAssertEqual(checkout.root, "/srv/api")
    }

    /// With no spawn directory recorded, the project's checkout for that device is
    /// the root — and a session filed outside any project has none at all rather
    /// than borrowing the local path it sits beside.
    func testRemoteRootFallsBackToTheDeviceCheckout() {
        var session = Session(title: "ukvps", agent: .terminal)
        session.fyolodRemoteHost = "ukvps"
        session.deviceID = "device-a"

        let underProject = derive(session,
                                  in: project("/Users/me/api", checkouts: ["device-a": "/srv/api"]),
                                  localRoot: "/Users/me/api")
        XCTAssertEqual(underProject.root, "/srv/api")

        let loose = derive(session, in: nil, localRoot: NSHomeDirectory())
        XCTAssertNil(loose.root)
        XCTAssertNil(loose.localRoot)
    }

    /// A plain `ssh` terminal runs its PTY here, but it exists to put the user on
    /// that box: it is that machine's checkout, and this Mac's files are never
    /// what its panes show. With no recorded checkout on that device there is no
    /// root either, so the pane names the machine instead of drawing a tree.
    func testPlainSSHSessionIsTheBoxItReaches() {
        var session = Session(title: "shell", agent: .terminal)
        session.sshHost = "ukvps"

        let checkout = derive(session, in: project("/Users/me/api"), localRoot: "/Users/me/api")

        XCTAssertNil(checkout.localRoot)
        XCTAssertTrue(checkout.isOnAnotherDevice)
        XCTAssertEqual(checkout.device.name, "ukvps")
        XCTAssertNil(checkout.root)
    }

    /// A local session is untouched: whatever root its slot supplies is the root,
    /// and this Mac may read it.
    func testLocalSessionKeepsItsRoot() {
        let plain = derive(Session(title: "shell", agent: .terminal),
                           in: project("/Users/me/api"), localRoot: "/Users/me/api")
        XCTAssertEqual(plain.localRoot, "/Users/me/api")
        XCTAssertFalse(plain.isOnAnotherDevice)

        let worktree = derive(Session(title: "shell", agent: .terminal),
                              in: project("/Users/me/api"), localRoot: "/Users/me/api-fix")
        XCTAssertEqual(worktree.localRoot, "/Users/me/api-fix")

        let loose = derive(Session(title: "shell", agent: .terminal),
                           in: nil, localRoot: "/Users/me/elsewhere")
        XCTAssertEqual(loose.localRoot, "/Users/me/elsewhere")
    }

    /// A loose terminal is wherever it wandered — on this Mac and on a device
    /// alike. The panes used to follow a local `cd` and pin a remote one to the
    /// directory the session was spawned in, so the same `cd ..` moved the tree
    /// here and did nothing there.
    func testALooseTerminalOnADeviceFollowsItsWorkingDirectory() {
        var session = Session(title: "ukvps", agent: .terminal)
        session.fyolodRemoteHost = "ukvps"
        session.deviceID = "device-a"
        session.fyolodRemoteCwd = "/home/me/repo/proto"

        let checkout = derive(session, in: nil, localRoot: nil,
                              liveWorkingDirectory: "/home/me")

        XCTAssertEqual(checkout.root, "/home/me")
        XCTAssertNil(checkout.localRoot, "still nothing this Mac may read")
    }

    /// The slot decides whether the root follows the shell: a project session's
    /// root is its checkout on both machines, so no live cwd is offered and the
    /// spawn directory stands.
    func testAProjectSessionOnADeviceStaysAtItsCheckout() {
        var session = Session(title: "ukvps", agent: .terminal)
        session.fyolodRemoteHost = "ukvps"
        session.deviceID = "device-a"
        session.fyolodRemoteCwd = "/home/me/repo/proto"

        let checkout = derive(session, in: project("/Users/me/proto"), localRoot: "/Users/me/proto")

        XCTAssertEqual(checkout.root, "/home/me/repo/proto")
    }

    /// A plain `ssh` terminal runs its PTY *here*, so the cwd sampled for it is a
    /// directory on this Mac. Handing that back as a path on the box is the
    /// wrong-machine mixup the checkout exists to prevent, so it is refused even
    /// though the slot follows the shell.
    func testAPlainSSHTerminalNeverTakesTheLocalCwdAsARemoteRoot() {
        var session = Session(title: "shell", agent: .terminal)
        session.sshHost = "ukvps"

        let checkout = derive(session, in: nil, localRoot: NSHomeDirectory(),
                              liveWorkingDirectory: "/Users/me/Documents")

        XCTAssertNil(checkout.root)
        XCTAssertNil(checkout.localRoot)
    }

    /// The identity is the device, not the road to it: the same box reached by a
    /// LAN name and a tailnet name is one checkout, or every alias would fork the
    /// same directory into a checkout of its own.
    func testOneDeviceReachedByTwoAliasesIsOneCheckout() {
        func session(alias: String) -> Session {
            var session = Session(title: alias, agent: .terminal)
            session.fyolodRemoteHost = alias
            session.deviceID = "device-a"
            session.fyolodRemoteCwd = "/srv/api"
            return session
        }

        let lan = derive(session(alias: "vps-lan"), in: nil, localRoot: nil)
        let tailnet = derive(session(alias: "vps-tailnet"), in: nil, localRoot: nil)

        XCTAssertEqual(lan, tailnet)
        XCTAssertEqual(Set([lan, tailnet]).count, 1)
    }

    /// Until a handshake resolves a `host_id` the alias is all there is, so two
    /// aliases stay two checkouts — the same bootstrap split `KnownDevice` carries.
    func testAliasesStayDistinctUntilADeviceResolvesThem() {
        func session(alias: String) -> Session {
            var session = Session(title: alias, agent: .terminal)
            session.fyolodRemoteHost = alias
            return session
        }

        XCTAssertNotEqual(derive(session(alias: "vps-lan"), in: nil, localRoot: nil),
                          derive(session(alias: "vps-wan"), in: nil, localRoot: nil))
    }
}
