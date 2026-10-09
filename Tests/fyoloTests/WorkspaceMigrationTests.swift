import XCTest
@testable import fyolo

/// `WorkspaceMigration` — the upgrade that turns a pre-workspace state file into
/// workspaces. It rewrites persisted user state on launch, so the cases that
/// matter are the destructive ones: don't lose a session, open to the sidebar the
/// user closed, and don't leave a project pointing at an owner that isn't there.
final class WorkspaceMigrationTests: XCTestCase {
    private typealias Legacy = WorkspaceMigration.LegacyProject

    private func session(_ title: String, agent: AgentPreset = .terminal) -> Session {
        Session(title: title, agent: agent)
    }

    private func remote(_ title: String, host: String) -> Session {
        var session = Session(title: title, agent: .terminal)
        session.fyolodRemoteHost = host
        return session
    }

    private func terminals(_ sessions: [Session]) -> Legacy {
        Legacy(name: "Terminals", path: NSHomeDirectory(), branch: "—",
               sessions: sessions, kind: .terminals)
    }

    private func chats(_ sessions: [Session]) -> Legacy {
        Legacy(name: "Chats",
               path: NSHomeDirectory() + "/.fyolo/chats", branch: "—",
               sessions: sessions, kind: .chats)
    }

    private func folder(_ name: String, sessions: [Session] = []) -> Legacy {
        Legacy(name: name, path: "/code/\(name)", branch: "main", sessions: sessions)
    }

    /// A checkout as an older state file wrote it: the machine recorded on the
    /// checkout itself, which is what `reconcile` reads to give the workspace one.
    /// No alias is that file's way of saying this Mac.
    private func checkout(
        _ name: String, in workspace: Workspace, on alias: String? = nil, device: String? = nil
    ) -> Project {
        var project = Project(workspaceID: workspace.id, name: name, path: "/code/\(name)",
                              branch: "main", sessions: [])
        project.legacyDevice = alias.map { KnownDevice(alias: $0, deviceID: device) }
        return project
    }

    /// The whole point of the upgrade: the user opens to the column they closed.
    /// Terminals, Chats and every folder project land in one workspace, so the
    /// switcher stays out of sight for someone who never asked for a second scope.
    func testEverythingThisMacShowedBecomesOneWorkspace() {
        let (workspaces, projects) = WorkspaceMigration.migrate([
            terminals([session("Terminal 1")]),
            chats([session("Claude Code", agent: .claudeCode)]),
            folder("fyolo", sessions: [session("Terminal 1")]),
            folder("vibewizard"),
        ])

        XCTAssertEqual(workspaces.count, 1, "one workspace, so the switcher stays hidden")
        XCTAssertEqual(workspaces.first?.terminals.map { $0.title }, ["Terminal 1"])
        XCTAssertEqual(workspaces.first?.chats.map { $0.title }, ["Claude Code"])
        XCTAssertEqual(projects.map { $0.name }, ["fyolo", "vibewizard"])
        XCTAssertEqual(Set(projects.map { $0.workspaceID }), [workspaces[0].id])
    }

    /// A machine's container was never a folder — its path is a directory on that
    /// box and its rows are loose shells there. It becomes that machine's own
    /// workspace, which is exactly what the sidebar showed after switching device.
    func testAHostContainerBecomesThatMachinesWorkspace() {
        let (workspaces, projects) = WorkspaceMigration.migrate([
            terminals([session("Terminal 1")]),
            Legacy(name: "ukvps", path: "/home/me/repo", branch: "—",
                   sessions: [remote("Terminal 1", host: "ukvps")],
                   kind: .host, sshHost: "ukvps", deviceID: "h_aaaa"),
        ])

        XCTAssertTrue(projects.isEmpty, "a machine is not a folder")
        XCTAssertEqual(workspaces.count, 2)
        let fallback = workspaces.first { !$0.device.isThisMac }
        XCTAssertEqual(fallback?.name, "ukvps")
        XCTAssertEqual(fallback?.deviceAlias, "ukvps")
        XCTAssertEqual(fallback?.deviceID, "h_aaaa", "the machine it resolved to is kept")
        XCTAssertEqual(fallback?.terminals.map { $0.title }, ["Terminal 1"])
    }

    /// The hard rule: nothing the user could see before the upgrade is missing
    /// after it, whatever the mix of containers.
    func testNoSessionIsLost() {
        let input: [Legacy] = [
            terminals([session("l1"), session("l2")]),
            chats([session("Claude Code", agent: .claudeCode)]),
            folder("fyolo", sessions: [session("p1"), session("p2")]),
            Legacy(name: "ukvps", path: "~", branch: "—",
                   sessions: [remote("r1", host: "ukvps")], kind: .host, sshHost: "ukvps"),
        ]

        let (workspaces, projects) = WorkspaceMigration.migrate(input)

        let before = Set(input.flatMap { $0.sessions.map { $0.id } })
        let after = Set(workspaces.flatMap { $0.looseSessions.map { $0.id } }
            + projects.flatMap { $0.sessions.map { $0.id } })
        XCTAssertEqual(after, before)
    }

    /// A project keeps its identity across the upgrade — its id is what the split
    /// groups, the recent list, and the CLI's scope all address it by.
    func testProjectsKeepTheirIdentityAndContents() {
        let original = folder("fyolo", sessions: [session("Terminal 1")])
        let (_, projects) = WorkspaceMigration.migrate([original])

        XCTAssertEqual(projects.first?.id, original.id)
        XCTAssertEqual(projects.first?.path, "/code/fyolo")
        XCTAssertEqual(projects.first?.branch, "main")
        XCTAssertEqual(projects.first?.sessions.map { $0.id }, original.sessions.map { $0.id })
    }

    /// The older container migrations still run ahead of the fold, so a state file
    /// two upgrades behind lands in the right sections rather than as fake folders.
    func testOlderContainerMigrationsStillRunFirst() {
        // Pre-loose-terminal-entity: scratch shells were a plain project at $HOME.
        // Pre-chats-funnel: scratch agents were a "default" project at ~/.fyolo/default.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let (workspaces, projects) = WorkspaceMigration.migrate([
            Legacy(name: "home", path: home.path, branch: "—", sessions: [session("shell")]),
            Legacy(name: "default",
                   path: home.appendingPathComponent(".fyolo/default").path,
                   branch: "—", sessions: [session("Claude Code", agent: .claudeCode)]),
        ])

        XCTAssertTrue(projects.isEmpty, "neither was ever a real project")
        XCTAssertEqual(workspaces.first?.terminals.map { $0.title }, ["Terminal 1"],
                       "the pre-entity “shell” is renumbered")
        XCTAssertEqual(workspaces.first?.chats.map { $0.title }, ["Claude Code"])
    }

    /// A remote session left in the loose funnel by a two-versions-old file is
    /// lifted onto its machine before the fold, so it ends up in that machine's
    /// workspace rather than among the local shells.
    func testRemoteSessionsInTheLooseFunnelReachTheirMachinesWorkspace() {
        let (workspaces, _) = WorkspaceMigration.migrate([
            terminals([session("Terminal 1"), remote("Terminal 2", host: "ukvps")]),
        ])

        XCTAssertEqual(workspaces.count, 2)
        XCTAssertEqual(workspaces.first?.terminals.map { $0.title }, ["Terminal 1"])
        XCTAssertEqual(workspaces.last?.deviceAlias, "ukvps")
        XCTAssertEqual(workspaces.last?.terminals.count, 1)
    }

    /// An empty state file still produces a scope: the sidebar has to have one to
    /// show, and a project can never be left pointing at nothing.
    func testMigratingNothingStillProducesAWorkspace() {
        let (workspaces, projects) = WorkspaceMigration.migrate([])

        XCTAssertEqual(workspaces.count, 1)
        XCTAssertTrue(projects.isEmpty)
    }

    /// The published `state.json` shape, decoded through the snapshot the app
    /// actually loads and then migrated. This is the end-to-end check the released
    /// app depends on: the file on a user's disk carries `kind`/`sshHost` on each
    /// project and no `workspaces` key at all, and it has to come back as a
    /// sidebar rather than as a fresh install.
    func testAPublishedStateFileDecodesAndMigrates() throws {
        let json = Data("""
        {
          "projects": [
            {"id": "\(UUID().uuidString)", "name": "Terminals", "path": "\(NSHomeDirectory())",
             "branch": "—", "kind": "terminals",
             "sessions": [{"id": "\(UUID().uuidString)", "title": "Terminal 1",
                           "agent": "terminal", "createdAt": 750000000}]},
            {"id": "\(UUID().uuidString)", "name": "fyolo", "path": "/code/fyolo",
             "branch": "main",
             "sessions": [{"id": "\(UUID().uuidString)", "title": "Claude Code",
                           "agent": "claude-code", "createdAt": 750000000}]},
            {"id": "\(UUID().uuidString)", "name": "ukvps", "path": "~", "branch": "—",
             "kind": "host", "sshHost": "ukvps",
             "sessions": [{"id": "\(UUID().uuidString)", "title": "Terminal 1",
                           "agent": "terminal", "createdAt": 750000000,
                           "fyolodRemoteHost": "ukvps"}]}
          ]
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(StateFile.Snapshot.self, from: json)
        XCTAssertNil(snapshot.workspaces, "a published file has no workspaces key")
        let legacy = try XCTUnwrap(snapshot.legacyProjects, "it decodes through the old shape")
        XCTAssertEqual(legacy.count, 3)

        let (workspaces, projects) = WorkspaceMigration.migrate(legacy)

        XCTAssertEqual(workspaces.count, 2, "this Mac's sidebar, plus the machine's own")
        XCTAssertEqual(workspaces.first?.terminals.count, 1)
        XCTAssertEqual(projects.map { $0.name }, ["fyolo"])
        XCTAssertEqual(projects.first?.workspaceID, workspaces.first?.id)
        XCTAssertEqual(workspaces.last?.deviceAlias, "ukvps")
        XCTAssertEqual(workspaces.last?.terminals.count, 1)
    }

    /// A state file this build wrote skips the upgrade entirely — the legacy read
    /// is what tells the two apart, and it must not fire on a current file.
    func testAWorkspaceEraFileIsNotMigratedAgain() throws {
        let home = Workspace(name: "Sessions", terminals: [session("Terminal 1")])
        let written = StateFile.Snapshot(
            workspaces: [home], currentWorkspaceID: home.id,
            projects: [Project(workspaceID: home.id, name: "fyolo", path: "/code/fyolo",
                               branch: "main", sessions: [])],
            selectedSessionID: nil, splitGroups: [], inspectorLayouts: nil)

        let decoded = try JSONDecoder().decode(
            StateFile.Snapshot.self, from: try JSONEncoder().encode(written))

        XCTAssertNil(decoded.legacyProjects, "nothing to upgrade")
        XCTAssertEqual(decoded.workspaces?.first?.terminals.map { $0.title }, ["Terminal 1"])
        XCTAssertEqual(decoded.currentWorkspaceID, home.id)
        XCTAssertEqual(decoded.projects.first?.workspaceID, home.id)
    }

    /// A project whose owner is gone — a workspace deleted while the app was
    /// closed — is filed under the first one rather than vanishing from the tree.
    func testReconcileRehomesAProjectWhoseWorkspaceIsGone() {
        let home = Workspace(name: "Sessions")
        let orphan = Project(workspaceID: UUID(), name: "fyolo", path: "/code/fyolo",
                             branch: "main", sessions: [session("Terminal 1")])

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [home], projects: [orphan])

        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(projects.first?.workspaceID, home.id)
    }

    /// An orphan is the user's own work, so it is never buried in a machine's
    /// fallback — those hold what nobody filed, which is the opposite claim.
    func testReconcilePrefersAUserWorkspaceOverAMachineFallback() {
        let fallback = Workspace(name: "ukvps", deviceAlias: "ukvps")
        let home = Workspace(name: "Sessions")
        let orphan = Project(workspaceID: UUID(), name: "fyolo", path: "/code/fyolo",
                             branch: "main", sessions: [])

        let (_, projects) = WorkspaceMigration.reconcile(
            workspaces: [fallback, home], projects: [orphan])

        XCTAssertEqual(projects.first?.workspaceID, home.id)
    }

    /// Reconcile leaves a well-formed tree exactly as it found it — it runs on
    /// every load, so it has to be a no-op in the normal case.
    func testReconcileLeavesAHealthyTreeAlone() {
        let home = Workspace(name: "Sessions")
        let filed = Project(workspaceID: home.id, name: "fyolo", path: "/code/fyolo",
                            branch: "main", sessions: [])

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [home], projects: [filed])

        // Everything but the ownership answer is untouched. That answer is
        // recorded rather than left absent on purpose: an unrecorded one would be
        // re-derived next launch, against a device this pass may have just stamped
        // on, and could then claim a workspace the user named.
        var settled = home
        settled.isAutoCreated = false
        XCTAssertEqual(workspaces, [settled])
        XCTAssertEqual(projects, [filed])

        // And it is a fixed point from there — the property the churn would break.
        let again = WorkspaceMigration.reconcile(workspaces: workspaces, projects: projects)
        XCTAssertEqual(again.workspaces, workspaces)
    }

    // MARK: - Every workspace belongs to one machine

    /// A workspace holding nothing but checkouts on one box *is* that box's,
    /// whoever made it — so it says so, and the device it resolved to rides along.
    func testAWorkspaceAdoptsTheMachineItsProjectsAreOn() {
        let scope = Workspace(name: "Servers")
        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [scope],
            projects: [checkout("api", in: scope, on: "ukvps", device: "h_aaaa"),
                       checkout("web", in: scope, on: "ukvps")])

        XCTAssertEqual(workspaces.count, 1, "one machine, so nothing to split")
        XCTAssertEqual(workspaces.first?.device, .ssh(alias: "ukvps"))
        XCTAssertEqual(workspaces.first?.deviceID, "h_aaaa")
        XCTAssertEqual(workspaces.first?.id, scope.id, "adoption is not a new workspace")
        XCTAssertEqual(Set(projects.map(\.workspaceID)), [scope.id])
    }

    /// Nothing filed under it and no machine named: this Mac, which is what an
    /// absent alias already meant. Nothing is written, so the state file keeps its
    /// shape.
    func testAWorkspaceWithNoProjectsStaysOnThisMac() {
        let scope = Workspace(name: "Sessions", terminals: [session("Terminal 1")])

        let (workspaces, _) = WorkspaceMigration.reconcile(workspaces: [scope], projects: [])

        var settled = scope
        settled.isAutoCreated = false
        XCTAssertEqual(workspaces, [settled])
        XCTAssertEqual(workspaces.first?.device, .thisMac)
        XCTAssertNil(workspaces.first?.deviceAlias, "no alias is written, so the file keeps its shape")
    }

    /// The lossy case, and a reachable one: `addProject` files a local folder into
    /// whatever workspace is current and `addRemoteProject` files a checkout on a
    /// box into the same place. A workspace cannot mean two machines, so it splits.
    func testAWorkspaceWhoseProjectsSpanMachinesSplits() throws {
        let scope = Workspace(name: "Work", terminals: [session("Terminal 1")])
        let local = checkout("fyolo", in: scope)
        let remote = checkout("api", in: scope, on: "ukvps")

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [scope], projects: [local, remote])

        XCTAssertEqual(workspaces.count, 2)
        let here = try XCTUnwrap(workspaces.first { $0.device == .thisMac })
        let there = try XCTUnwrap(workspaces.first { $0.device == .ssh(alias: "ukvps") })
        XCTAssertEqual(there.name, "ukvps", "the new half is named after its machine")
        XCTAssertEqual(projects.first { $0.id == local.id }?.workspaceID, here.id)
        XCTAssertEqual(projects.first { $0.id == remote.id }?.workspaceID, there.id)
    }

    /// The original uuid survives the split, and on the half the user is still
    /// looking at. Wire ids embed it — `looseWireID` builds `<uuid>-terminals` for
    /// the phone to start a session by, and `ControlScope.id` keys the CLI's watch
    /// streams — so reissuing it on both halves would break both.
    func testTheOriginalWorkspaceKeepsItsIdAndItsLooseSessions() {
        let scope = Workspace(name: "Work", terminals: [session("Terminal 1")],
                              chats: [session("Claude Code", agent: .claudeCode)])

        let (workspaces, _) = WorkspaceMigration.reconcile(
            workspaces: [scope],
            projects: [checkout("fyolo", in: scope), checkout("api", in: scope, on: "ukvps")])

        let kept = workspaces.first { $0.id == scope.id }
        XCTAssertEqual(kept?.device, .thisMac, "this Mac's half keeps the id")
        XCTAssertEqual(kept?.name, "Work", "and the name the user gave it")
        XCTAssertEqual(kept?.looseSessions.map(\.id), scope.looseSessions.map(\.id),
                       "a loose session has no project to place it by")
    }

    /// A machine's own workspace keeps the id when it is the one that splits: its
    /// loose sessions run on that box, and `deviceWorkspace(for:)` finds it by
    /// alias. The stray local checkout is what moves.
    func testAMachinesWorkspaceKeepsItsIdAndSheddsTheLocalCheckout() {
        let ukvps = Workspace(name: "ukvps", terminals: [remote("Terminal 1", host: "ukvps")],
                              deviceAlias: "ukvps")
        let strayLocal = checkout("fyolo", in: ukvps)

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [ukvps],
            projects: [strayLocal, checkout("api", in: ukvps, on: "ukvps")])

        let kept = workspaces.first { $0.id == ukvps.id }
        XCTAssertEqual(kept?.device, .ssh(alias: "ukvps"))
        XCTAssertEqual(kept?.terminals.count, 1, "the remote shells stay on their machine")
        XCTAssertEqual(workspaces.count, 2)
        let here = workspaces.first { $0.device == .thisMac }
        XCTAssertEqual(projects.first { $0.id == strayLocal.id }?.workspaceID, here?.id)
    }

    /// A split files its checkouts into the workspace that machine already has,
    /// rather than minting a second one for the same alias — `deviceWorkspace(for:)`
    /// matches by alias and expects to find one.
    func testASplitReusesTheMachinesExistingWorkspace() {
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps")
        let scope = Workspace(name: "Work")
        let remote = checkout("api", in: scope, on: "ukvps")

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [scope, ukvps], projects: [checkout("fyolo", in: scope), remote])

        XCTAssertEqual(workspaces.count, 2, "no second workspace for a machine that has one")
        XCTAssertEqual(projects.first { $0.id == remote.id }?.workspaceID, ukvps.id)
    }

    /// A local checkout shed by a machine's workspace goes to the workspace this
    /// Mac already has, rather than adding a scope for a machine the user is
    /// sitting in front of.
    ///
    /// Asserted for both orderings: which workspace `state.json` lists first is an
    /// accident of when the user made them, and the sidebar they get back must not
    /// turn on it. Listing the box's workspace first used to mint a third workspace
    /// named "This Mac" beside the perfectly good local one.
    func testALocalCheckoutShedByASplitGoesToTheWorkspaceThisMacHas() {
        let home = Workspace(name: "Sessions")
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps")
        let stray = checkout("fyolo", in: ukvps)
        let filed = [stray, checkout("api", in: ukvps, on: "ukvps")]

        for order in [[home, ukvps], [ukvps, home]] {
            let (workspaces, projects) = WorkspaceMigration.reconcile(
                workspaces: order, projects: filed)

            XCTAssertEqual(workspaces.count, 2, "the Mac in front of the user already has one")
            XCTAssertEqual(projects.first { $0.id == stray.id }?.workspaceID, home.id)
        }
    }

    /// Naming no machine is not the same as being on this Mac, which is what makes
    /// the local home worth deciding up front rather than reading off the workspaces
    /// already processed: a workspace whose checkouts all sit on a box adopts that
    /// box in this very pass. The shed local checkout gets a workspace of its own
    /// rather than being filed into a scope that is on its way to another machine.
    func testAShedLocalCheckoutSkipsAWorkspaceThatIsAboutToAdoptAMachine() throws {
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps")
        let servers = Workspace(name: "Servers")
        let stray = checkout("fyolo", in: ukvps)

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [ukvps, servers],
            projects: [stray, checkout("api", in: ukvps, on: "ukvps"),
                       checkout("web", in: servers, on: "devbox")])

        XCTAssertEqual(workspaces.first { $0.id == servers.id }?.device, .ssh(alias: "devbox"),
                       "it adopts the box its only checkout is on")
        let here = try XCTUnwrap(workspaces.first { $0.device == .thisMac })
        XCTAssertNotEqual(here.id, servers.id)
        XCTAssertEqual(projects.first { $0.id == stray.id }?.workspaceID, here.id)
    }

    /// `reconcile` runs on every load, so a tree it produced must come back
    /// unchanged — otherwise the sidebar reshuffles itself on every launch.
    func testReconcileIsIdempotentOverItsOwnOutput() {
        let scope = Workspace(name: "Work", terminals: [session("Terminal 1")])
        let once = WorkspaceMigration.reconcile(
            workspaces: [scope, Workspace(name: "Servers")],
            projects: [checkout("fyolo", in: scope),
                       checkout("api", in: scope, on: "ukvps"),
                       checkout("web", in: scope, on: "devbox")])

        let twice = WorkspaceMigration.reconcile(
            workspaces: once.workspaces, projects: once.projects)

        XCTAssertEqual(twice.workspaces, once.workspaces)
        XCTAssertEqual(twice.projects, once.projects)
    }

    /// The upgrade runs once. A state file that already carries workspaces is
    /// never handed to `migrate`, and re-running it over its own output would be a
    /// sign the snapshot decode had gone wrong — so pin that the fold is stable.
    func testMigratingIsStableOverItsOwnShape() {
        let once = WorkspaceMigration.migrate([
            terminals([session("Terminal 1")]),
            folder("fyolo", sessions: [session("Terminal 1")]),
        ])
        let reconciled = WorkspaceMigration.reconcile(
            workspaces: once.workspaces, projects: once.projects)

        // `migrate` does not answer the ownership question for the home workspace
        // it mints, so the first `reconcile` records it; nothing else moves.
        XCTAssertEqual(reconciled.workspaces.map(\.id), once.workspaces.map(\.id))
        XCTAssertEqual(reconciled.workspaces.map(\.name), once.workspaces.map(\.name))
        XCTAssertEqual(reconciled.workspaces.map(\.deviceAlias), once.workspaces.map(\.deviceAlias))
        XCTAssertEqual(reconciled.projects, once.projects)

        let again = WorkspaceMigration.reconcile(
            workspaces: reconciled.workspaces, projects: reconciled.projects)
        XCTAssertEqual(again.workspaces, reconciled.workspaces)
    }
}

/// The default name the New Workspace panel opens with. The panel treats an empty
/// field as a cancel, so this default is what makes Return create a workspace at
/// all — an off-by-one here hands the user a name that is already taken.
final class WorkspaceDefaultNameTests: XCTestCase {
    func testFirstWorkspaceTakesTheBareName() {
        XCTAssertEqual(
            FyoloStore.nextFreeWorkspaceName(base: "Workspace", taken: []), "Workspace")
        XCTAssertEqual(
            FyoloStore.nextFreeWorkspaceName(base: "Workspace", taken: ["Sessions"]), "Workspace")
    }

    func testTheCounterStartsAtTwoAndSkipsWhatIsTaken() {
        XCTAssertEqual(
            FyoloStore.nextFreeWorkspaceName(base: "Workspace", taken: ["Workspace"]),
            "Workspace 2")
        XCTAssertEqual(
            FyoloStore.nextFreeWorkspaceName(
                base: "Workspace", taken: ["Workspace", "Workspace 2"]),
            "Workspace 3")
        // A gap is not filled: the next free number wins, not the lowest missing
        // one, so the name never collides with a workspace further down the list.
        XCTAssertEqual(
            FyoloStore.nextFreeWorkspaceName(
                base: "Workspace", taken: ["Workspace", "Workspace 3"]),
            "Workspace 2")
    }

    /// The base is `localized("Workspace")`, so the rule has to hold for a
    /// translated base too — zh-Hans ships 工作区.
    func testTheRuleHoldsForALocalizedBase() {
        XCTAssertEqual(
            FyoloStore.nextFreeWorkspaceName(base: "工作区", taken: ["工作区"]), "工作区 2")
    }
}
