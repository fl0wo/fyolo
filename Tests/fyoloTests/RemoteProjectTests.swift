import XCTest
@testable import fyolo

/// A project whose checkout is on another machine.
///
/// The machine is the workspace's now — a checkout inherits it from the scope it
/// is filed under — so these ask the store rather than the project. The identity
/// question is the one worth pinning: a box commonly answers to a LAN name, a WAN
/// name, and a tailnet name, so matching a checkout by the alias it was reached
/// through would open a second row for the same directory the day the user
/// changes networks.
@MainActor
final class RemoteProjectTests: XCTestCase {
    private func makeStore(workspace: Workspace, projects: [Project]) -> FyoloStore {
        let defaults = UserDefaults(suiteName: "remote-project-\(UUID().uuidString)")
            ?? UserDefaults.standard
        return FyoloStore(
            workspaces: [workspace], projects: projects,
            settings: AppSettings(defaults: defaults))
    }

    private func checkout(_ path: String, in workspace: Workspace) -> Project {
        var project = Project(
            workspaceID: workspace.id, name: "api", path: path, branch: "—", sessions: [])
        project.remoteCheckouts[workspace.deviceID ?? workspace.deviceAlias ?? ""] = path
        return project
    }

    func testSameDirectoryOnTheSameDeviceIsTheSameCheckout() {
        let vps = Workspace(name: "vps-lan", deviceAlias: "vps-lan", deviceID: "device-a")
        let project = checkout("/srv/api", in: vps)
        let store = makeStore(workspace: vps, projects: [project])

        XCTAssertEqual(store.checkout(at: "/srv/api", on: "vps-lan", device: "device-a")?.id,
                       project.id)
        XCTAssertEqual(store.checkout(at: "/srv/api", on: "vps-tailnet", device: "device-a")?.id,
                       project.id, "one machine reached by a second alias is still one checkout")
        XCTAssertNil(store.checkout(at: "/srv/web", on: "vps-lan", device: "device-a"),
                     "a different directory on the same machine is a different checkout")
        XCTAssertNil(store.checkout(at: "/srv/api", on: "other", device: "device-b"))
    }

    /// Until a handshake resolves a `host_id` the alias is all there is — the same
    /// bootstrap/stable split `KnownDevice` carries.
    func testAliasMatchesUntilADeviceResolvesIt() {
        let vps = Workspace(name: "vps-lan", deviceAlias: "vps-lan")
        let project = checkout("/srv/api", in: vps)
        let store = makeStore(workspace: vps, projects: [project])

        XCTAssertEqual(store.checkout(at: "/srv/api", on: "vps-lan", device: nil)?.id, project.id)
        XCTAssertEqual(store.checkout(at: "/srv/api", on: "vps-lan", device: "device-a")?.id,
                       project.id,
                       "a device this workspace hasn’t learned yet can’t disprove the alias")
        XCTAssertNil(store.checkout(at: "/srv/api", on: "vps-wan", device: nil))
    }

    /// A folder on this Mac is never a remote checkout, however the paths line up —
    /// the local project row and a same-named directory on a VPS are two places.
    func testALocalProjectIsNeverARemoteCheckout() {
        let home = Workspace(name: "Sessions")
        let project = Project(
            workspaceID: home.id, name: "api", path: "/srv/api", branch: "main", sessions: [])
        let store = makeStore(workspace: home, projects: [project])

        XCTAssertEqual(store.device(of: project), .thisMac)
        XCTAssertFalse(store.isOnAnotherDevice(project))
        XCTAssertNil(store.checkout(at: "/srv/api", on: "vps-lan", device: "device-a"))
    }

    /// The local-disk gate is the store's answer, not the project's: a checkout
    /// filed in a workspace on a box is over there, and nothing may read its path
    /// off this Mac.
    func testACheckoutInAMachinesWorkspaceIsOnThatMachine() {
        let vps = Workspace(name: "ukvps", deviceAlias: "ukvps")
        let project = checkout("/srv/api", in: vps)
        let store = makeStore(workspace: vps, projects: [project])

        XCTAssertEqual(store.device(of: project), .ssh(alias: "ukvps"))
        XCTAssertTrue(store.isOnAnotherDevice(project))
    }

    /// A project whose workspace is gone: the machine is unknown, and unknown must
    /// not read as this Mac — the gate would open on a directory that may be on a
    /// box. Unreachable through the tree, since `reconcile` files every orphan on
    /// load, which is why the gate is what has to be safe.
    func testAProjectWithNoWorkspaceIsNotTreatedAsLocal() {
        let home = Workspace(name: "Sessions")
        let orphan = Project(
            workspaceID: UUID(), name: "api", path: "/srv/api", branch: "—", sessions: [])
        let store = makeStore(workspace: home, projects: [])

        XCTAssertNil(store.device(of: orphan))
        XCTAssertTrue(store.isOnAnotherDevice(orphan))
    }

    /// The checkout a remote terminal opens in resolves through the device key when
    /// one is known and the alias key until then, so the row works before and after
    /// the machine identifies itself.
    func testTheSeededCheckoutResolvesBothWays() {
        var known = Project(
            workspaceID: UUID(), name: "api", path: "/srv/api", branch: "—", sessions: [])
        known.remoteCheckouts["device-a"] = "/srv/api"
        XCTAssertEqual(known.remoteCheckout(device: "device-a", alias: "vps-lan"), "/srv/api")

        var unresolved = known
        unresolved.remoteCheckouts = ["vps-lan": "/srv/api"]
        XCTAssertEqual(unresolved.remoteCheckout(device: nil, alias: "vps-lan"), "/srv/api")
        XCTAssertEqual(unresolved.remoteCheckout(device: "device-a", alias: "vps-lan"), "/srv/api",
                       "a device key that isn’t recorded yet falls back to the alias")
    }

    /// A state file written before the hierarchy recorded the machine on each
    /// checkout. Those keys are still read, because they are the only thing that
    /// says a workspace's checkouts span two machines — and they are not written
    /// back, so the load after the upgrade reads a tree that inherits instead.
    func testOlderStateFilesStillCarryTheirCheckoutsMachine() throws {
        let older = """
        {"id":"\(UUID().uuidString)","name":"api","path":"/srv/api","branch":"—",
         "sessions":[],"deviceAlias":"vps-lan","deviceID":"device-a"}
        """
        let legacy = try JSONDecoder().decode(Project.self, from: Data(older.utf8))
        XCTAssertEqual(legacy.legacyDevice?.alias, "vps-lan")
        XCTAssertEqual(legacy.legacyDevice?.deviceID, "device-a")

        let rewritten = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(legacy)) as? [String: Any]
        XCTAssertNil(rewritten?["deviceAlias"], "the machine is the workspace's to record")
        XCTAssertNil(rewritten?["deviceID"])
    }

    /// A project written before either key existed decodes to one that inherits,
    /// which is what every project this build writes does.
    func testAProjectThatNamesNoMachineInheritsOne() throws {
        let older = """
        {"id":"\(UUID().uuidString)","name":"api","path":"/Users/me/api",
         "branch":"main","sessions":[]}
        """
        let legacy = try JSONDecoder().decode(Project.self, from: Data(older.utf8))
        XCTAssertNil(legacy.legacyDevice)
    }

    // MARK: - The path field's two rules

    /// What the field asks the machine for, and what it matches locally. The
    /// directory keeps its trailing slash so re-listing the same directory is
    /// recognised as the same request no matter how the user got there.
    func testSplitNamesTheDirectoryToListAndTheNameToMatch() {
        XCTAssertEqual(RemotePathEntry.split("/srv/ap").directory, "/srv/")
        XCTAssertEqual(RemotePathEntry.split("/srv/ap").partial, "ap")

        // Sitting on a slash lists that directory and matches everything in it.
        XCTAssertEqual(RemotePathEntry.split("/srv/").directory, "/srv/")
        XCTAssertEqual(RemotePathEntry.split("/srv/").partial, "")

        // The root is a directory like any other.
        XCTAssertEqual(RemotePathEntry.split("/").directory, "/")
        XCTAssertEqual(RemotePathEntry.split("/").partial, "")

        // No slash yet: nothing on that machine has been named, so nothing is
        // listed — the empty directory is what stops a request going out.
        XCTAssertEqual(RemotePathEntry.split("srv").directory, "")
        XCTAssertEqual(RemotePathEntry.split("srv").partial, "srv")
    }

    /// `~` is expanded here because fyolod expands nothing: it spawns the shell
    /// with a raw `chdir`. A double slash would be harmless but reads as a typo
    /// in the field, so the two shapes of `home` produce the same path.
    func testTildeExpandsAgainstTheMachinesOwnHome() {
        XCTAssertEqual(
            RemotePathEntry.expandingTilde("~/code/api", home: "/home/me"), "/home/me/code/api")
        XCTAssertEqual(
            RemotePathEntry.expandingTilde("~/code/api", home: "/home/me/"), "/home/me/code/api")
        XCTAssertEqual(RemotePathEntry.expandingTilde("~", home: "/home/me"), "/home/me")

        // An absolute path is already an answer.
        XCTAssertEqual(RemotePathEntry.expandingTilde("/srv/api", home: "/home/me"), "/srv/api")

        // `~user` is *another* account's home. Fyolo cannot resolve it and must
        // not quietly rewrite it into this one's.
        XCTAssertEqual(RemotePathEntry.expandingTilde("~root/api", home: "/home/me"), "~root/api")
    }
}
