import XCTest
@testable import fyolo

/// Where work that runs on **this Mac** is filed once a workspace belongs to
/// exactly one machine.
///
/// The rule already existed for loose sessions, phrased as "not a machine's
/// fallback"; it is restated here as a claim about the machine, and it now covers
/// `Open Project…` too — that path filed a local folder into whatever workspace
/// was current, a box's included. Both callers read `workspaceForThisMac`, which
/// is the decision; appending the row is not.
@MainActor
final class WorkspaceDeviceTests: XCTestCase {
    private func makeStore(workspaces: [Workspace], current: Workspace) -> FyoloStore {
        let defaults = UserDefaults(suiteName: "workspace-device-\(UUID().uuidString)")
            ?? UserDefaults.standard
        let store = FyoloStore(workspaces: workspaces, settings: AppSettings(defaults: defaults))
        store.currentWorkspaceID = current.id
        return store
    }

    /// A workspace states its machine outright, so an absent alias stops having to
    /// mean both "this Mac" and "the user made it". Nothing is stored differently —
    /// this reads the field that was always there.
    func testAWorkspaceNamesItsMachine() {
        XCTAssertEqual(Workspace(name: "Sessions").device, .thisMac)
        XCTAssertEqual(Workspace(name: "ukvps", deviceAlias: "ukvps").device,
                       .ssh(alias: "ukvps"))
        XCTAssertNil(WorkspaceDevice.thisMac.alias, "this Mac has no alias to reach it by")
    }

    /// A local shell or a local folder opened while a box's workspace is current
    /// lands on this Mac, not over there — the workspace would otherwise claim work
    /// that machine knows nothing about.
    func testLocalWorkGoesToAWorkspaceOnThisMac() {
        let home = Workspace(name: "Sessions")
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps")
        let store = makeStore(workspaces: [home, ukvps], current: ukvps)

        XCTAssertEqual(store.workspaceForThisMac.id, home.id)
    }

    /// A workspace already on this Mac keeps it: the redirect exists to correct a
    /// machine mismatch, not to overrule which scope the user is working in.
    func testTheCurrentWorkspaceIsKeptWhenItIsAlreadyOnThisMac() {
        let home = Workspace(name: "Sessions")
        let other = Workspace(name: "Side")
        let store = makeStore(workspaces: [home, other], current: other)

        XCTAssertEqual(store.workspaceForThisMac.id, other.id)
    }

    /// With no workspace on this Mac at all, the current one still takes it: a row
    /// the user cannot see is worse than a workspace whose machine is briefly
    /// wrong, and the next load's `reconcile` splits it back apart.
    func testWithNoLocalWorkspaceTheCurrentOneStillTakesIt() {
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps")
        let store = makeStore(workspaces: [ukvps], current: ukvps)

        XCTAssertEqual(store.workspaceForThisMac.id, ukvps.id)
    }

    /// Two workspaces can name one machine, so the fallback lookup picks rather
    /// than assuming the first match is the right one. The shape is reachable from
    /// a shipped state file: a workspace the user named, holding a checkout on a
    /// box that already has a fallback, adopts that box on the next load. A session
    /// the `fyolod` CLI or the phone then starts over there is one nobody filed,
    /// so it belongs in the workspace nobody asked for — not in the middle of the
    /// user's own work.
    func testAMachinesFallbackIsPreferredOverAWorkspaceThatAdoptedIt() {
        let named = Workspace(name: "Work")
        let fallback = Workspace(name: "ukvps", deviceAlias: "ukvps")
        var checkout = Project(
            workspaceID: named.id, name: "api", path: "/srv/api", branch: "—", sessions: [])
        checkout.legacyDevice = KnownDevice(alias: "ukvps", deviceID: nil)

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [named, fallback], projects: [checkout])
        XCTAssertEqual(workspaces.filter { $0.deviceAlias == "ukvps" }.count, 2,
                       "both are on that box — adoption is what states the truth")
        XCTAssertEqual(projects.first?.workspaceID, named.id,
                       "and the user keeps the workspace they named, checkout and all")

        let store = makeStore(workspaces: workspaces, current: named)

        XCTAssertEqual(store.deviceWorkspace(for: "ukvps"), fallback.id)
        XCTAssertEqual(store.workspaces.count, 2, "and nothing is minted for a machine that has one")
    }

    /// The preference is among the workspaces that exist, not a requirement that a
    /// fallback does: a machine whose only workspace is the user's still resolves
    /// to it rather than growing a second one beside it.
    func testAMachinesOnlyWorkspaceAnswersEvenWhenItIsTheUsers() {
        let home = Workspace(name: "Sessions", isAutoCreated: false)
        let named = Workspace(name: "Work", deviceAlias: "ukvps", isAutoCreated: false)
        let store = makeStore(workspaces: [home, named], current: home)

        XCTAssertEqual(store.deviceWorkspace(for: "ukvps"), named.id)
        XCTAssertEqual(store.workspaces.count, 2)
    }

    // MARK: - Where a plain `ssh` shell is filed

    /// The bug this rule exists to remove: opening an `ssh` shell minted a
    /// workspace for the box and moved the sidebar into it, so a user who asked
    /// for a terminal got a scope they had never seen — and had to find the
    /// switcher to get back.
    func testAnSSHShellStaysInTheWorkspaceOnScreen() {
        let home = Workspace(name: "Sessions", isAutoCreated: false)
        let store = makeStore(workspaces: [home], current: home)

        store.addSSHSession(host: "oracal")

        XCTAssertEqual(store.workspaces.count, 1, "nothing is minted for the box it reaches")
        XCTAssertEqual(store.currentWorkspaceID, home.id, "and the scope does not move")
        XCTAssertEqual(store.workspaces[0].terminals.first?.sshHost, "oracal")
        XCTAssertEqual(store.workspaces[0].terminals.first?.title, "oracal",
                       "the row names the machine, since the band above it no longer does")
    }

    /// A workspace Fyolo named after a box speaks for that box — its band names
    /// the machine and its rows drop their device marks in exchange — so a shell to
    /// a *different* host cannot be filed there without reading as one on this one.
    func testAnSSHShellToAnotherBoxAvoidsAMachinesOwnWorkspace() {
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps", isAutoCreated: true)
        let store = makeStore(workspaces: [ukvps], current: ukvps)

        store.addSSHSession(host: "oracal")

        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertTrue(ukvps.looseSessions.isEmpty)
        let oracal = store.workspaces.first { $0.deviceAlias == "oracal" }
        XCTAssertEqual(oracal?.terminals.first?.sshHost, "oracal")
        XCTAssertEqual(oracal?.terminals.first?.title, "SSH Shell",
                       "under a band that names the machine, the row says what kind it is")
    }

    /// The same machine's own workspace still takes its own shell, so `ssh` and a
    /// durable fyolod session on one box sit together when that is where the user
    /// already is.
    func testAMachinesOwnWorkspaceKeepsItsOwnSSHShell() {
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps", isAutoCreated: true)
        let store = makeStore(workspaces: [ukvps], current: ukvps)

        store.addSSHSession(host: "ukvps")

        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces[0].terminals.first?.sshHost, "ukvps")
    }

    /// The phone names the workspace it is showing, and the shell lands there for
    /// the same reason it lands in the sidebar's scope on the Mac.
    func testTheWorkspaceACallerNamesTakesTheShell() {
        let home = Workspace(name: "Sessions", isAutoCreated: false)
        let side = Workspace(name: "Side", isAutoCreated: false)
        let store = makeStore(workspaces: [home, side], current: home)

        store.addSSHSession(host: "oracal", preferring: side.id)

        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(store.workspaces[1].terminals.first?.sshHost, "oracal")
        XCTAssertTrue(store.workspaces[0].terminals.isEmpty)
    }
}

/// Which workspaces Fyolo may sweep when they empty out.
///
/// The flag exists because the device pass made the old test unsafe: once every
/// workspace names a machine, "named after a machine" no longer distinguishes one
/// Fyolo invented from one the user made and filled with checkouts on that box.
final class WorkspaceAutoCreatedTests: XCTestCase {
    /// `autoCreated` defaults to **nil**, not `false`: nil is what a state file
    /// written before the flag decodes to, which is the input the recovery pass
    /// exists for. Defaulting it to `false` made these tests assert against a
    /// value that had already been answered.
    private func workspace(
        _ name: String, alias: String? = nil, autoCreated: Bool? = nil
    ) -> Workspace {
        Workspace(name: name, deviceAlias: alias, isAutoCreated: autoCreated)
    }

    /// A file written before the flag: a fallback still looks exactly as
    /// `deviceWorkspace(for:)` made it, so it is reclaimed as Fyolo's.
    func testAnUntouchedFallbackIsRecoveredAsAutoCreated() {
        let (result, _) = WorkspaceMigration.reconcile(
            workspaces: [workspace("ukvps", alias: "ukvps")], projects: [])
        XCTAssertEqual(result[0].isAutoCreated, true)
    }

    /// Renaming a fallback is how a user claims it, so the name no longer matching
    /// the alias means it is theirs and must never be swept.
    func testARenamedFallbackIsTheUsers() {
        let (result, _) = WorkspaceMigration.reconcile(
            workspaces: [workspace("Ship auth", alias: "ukvps")], projects: [])
        XCTAssertEqual(result[0].isAutoCreated, false)
    }

    /// The regression this flag exists to stop: a workspace the user named, whose
    /// projects all live on one box, adopts that box's alias in the device pass —
    /// and must not become sweepable because of it.
    func testAUserWorkspaceAdoptingADeviceStaysTheUsers() {
        let named = workspace("Ship auth")
        var checkout = Project(
            workspaceID: named.id, name: "api", path: "/srv/api", branch: "—", sessions: [])
        checkout.legacyDevice = KnownDevice(alias: "ukvps", deviceID: nil)
        let (result, _) = WorkspaceMigration.reconcile(
            workspaces: [named], projects: [checkout])

        let adopted = result.first { $0.id == named.id }
        XCTAssertEqual(adopted?.deviceAlias, "ukvps", "the device pass should still stamp it")
        XCTAssertEqual(adopted?.isAutoCreated, false, "but it is still the user's workspace")
    }

    /// `reconcile` runs on every load, so the recovery must not change its answer
    /// on the second pass — by then every workspace names a machine.
    func testRecoveryIsIdempotent() {
        let once = WorkspaceMigration.reconcile(
            workspaces: [workspace("Ship auth"), workspace("ukvps", alias: "ukvps")],
            projects: [])
        let twice = WorkspaceMigration.reconcile(
            workspaces: once.workspaces, projects: once.projects)
        XCTAssertEqual(once.workspaces.map(\.isAutoCreated), twice.workspaces.map(\.isAutoCreated))
        XCTAssertEqual(twice.workspaces.first { $0.name == "Ship auth" }?.isAutoCreated, false)
    }
}

/// The two failures an adversarial review found in the first cut of the device
/// pass. Both are launch-2 or loose-session shaped, which is why the original
/// tests missed them.
final class WorkspaceDeviceRegressionTests: XCTestCase {
    private func checkout(_ name: String, in workspace: Workspace, on alias: String?) -> Project {
        var project = Project(
            workspaceID: workspace.id, name: name, path: "/srv/\(name)",
            branch: "—", sessions: [])
        project.legacyDevice = alias.map { KnownDevice(alias: $0, deviceID: nil) }
        return project
    }

    /// A user names a workspace after the box its checkouts live on. Launch 1
    /// stamps the alias; launch 2 must not then read that stamp back as "Fyolo
    /// made this" and make the workspace sweepable.
    func testAUserWorkspaceNamedAfterItsMachineSurvivesASecondLaunch() {
        let named = Workspace(name: "ukvps")
        let first = WorkspaceMigration.reconcile(
            workspaces: [named], projects: [checkout("api", in: named, on: "ukvps")])
        XCTAssertEqual(first.workspaces[0].deviceAlias, "ukvps", "launch 1 stamps the device")
        XCTAssertEqual(first.workspaces[0].isAutoCreated, false, "and records that it is the user's")

        let second = WorkspaceMigration.reconcile(
            workspaces: first.workspaces, projects: first.projects)
        XCTAssertEqual(
            second.workspaces[0].isAutoCreated, false,
            "launch 2 must not claim a workspace the user named")
        XCTAssertEqual(second.workspaces, first.workspaces, "and must change nothing at all")
    }

    /// A workspace holding local shells and one remote checkout used to adopt the
    /// remote box, because only projects were consulted — leaving a one-workspace
    /// tree with nowhere on this Mac for local work to go.
    func testLocalLooseShellsKeepAWorkspaceOffARemoteBox() {
        let scope = Workspace(name: "Sessions", terminals: [Session(title: "Terminal 1")])
        let (workspaces, _) = WorkspaceMigration.reconcile(
            workspaces: [scope], projects: [checkout("api", in: scope, on: "ukvps")])

        XCTAssertNotNil(
            workspaces.first { $0.device.isThisMac },
            "a local shell is a claim on this Mac, so somewhere must still be local")
        let kept = workspaces.first { $0.id == scope.id }
        XCTAssertEqual(kept?.device, .thisMac, "the shells' own workspace stays local")
        XCTAssertEqual(kept?.terminals.count, 1, "and keeps them")
    }

    /// The same, for a loose shell that runs on a box: it claims that box, so a
    /// workspace holding only those does not end up on this Mac by default.
    func testARemoteLooseShellClaimsItsMachine() {
        var shell = Session(title: "Terminal 1")
        shell.fyolodRemoteHost = "ukvps"
        let scope = Workspace(name: "Sessions", terminals: [shell])

        let (workspaces, _) = WorkspaceMigration.reconcile(workspaces: [scope], projects: [])
        XCTAssertEqual(workspaces.first { $0.id == scope.id }?.device, .ssh(alias: "ukvps"))
    }

    /// A plain `ssh` shell claims neither end. It is a local PTY holding a
    /// connection open, filed wherever the user opened it, so counting it for the
    /// far box handed the user's own scope to that machine on the next launch.
    func testAPlainSSHShellLeavesItsWorkspaceWhereItIs() {
        var shell = Session(title: "oracal")
        shell.sshHost = "oracal"
        let scope = Workspace(name: "Sessions", terminals: [shell], isAutoCreated: false)

        let (workspaces, _) = WorkspaceMigration.reconcile(workspaces: [scope], projects: [])
        XCTAssertEqual(workspaces.count, 1, "and no half splits off for the box")
        XCTAssertEqual(workspaces[0].device, .thisMac, "the scope the user named stays theirs")
        XCTAssertEqual(workspaces[0].terminals.count, 1)
    }

    /// And the mirror: one filed under a box's own workspace must not split a
    /// phantom local half off it either.
    func testAPlainSSHShellLeavesAMachinesWorkspaceWhereItIs() {
        var shell = Session(title: "SSH Shell")
        shell.sshHost = "ukvps"
        let scope = Workspace(
            name: "ukvps", terminals: [shell], deviceAlias: "ukvps", isAutoCreated: true)

        let (workspaces, _) = WorkspaceMigration.reconcile(workspaces: [scope], projects: [])
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].device, .ssh(alias: "ukvps"))
    }
}
