import XCTest

@testable import fyolo

/// Creating a workspace from the menu. Two facts are worth a test because both
/// are silent when wrong: the machine the workspace lands on comes from the row
/// that was clicked, and a workspace someone asked for is never marked as
/// Fyolo's own — `pruneEmptyDeviceWorkspaces` deletes an empty
/// `isAutoCreated` workspace, so getting that flag wrong makes a user's brand
/// new, still-empty workspace disappear.
@MainActor
final class WorkspaceCreationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-creation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "workspace-creation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// Scratch storage for both settings layers: a test must not rewrite the
    /// settings file or the defaults domain of the fyolo the user is running.
    private func makeStore() -> FyoloStore {
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
        return FyoloStore(workspaces: [Workspace(name: "Default")], settings: settings)
    }

    private func workspace(_ id: Workspace.ID, in store: FyoloStore) -> Workspace? {
        store.workspaces.first { $0.id == id }
    }

    func testWorkspaceCreatedOnThisMacHasNoAlias() {
        let store = makeStore()

        let id = store.addWorkspace(named: "Ship auth", on: .thisMac)

        XCTAssertEqual(workspace(id, in: store)?.device, .thisMac)
        XCTAssertNil(workspace(id, in: store)?.deviceAlias, "this Mac is the machine with no alias")
    }

    /// The row that was clicked decides the machine, so the alias has to survive
    /// the trip into the tree — a workspace filed on this Mac instead would take
    /// every checkout opened in it with it.
    func testWorkspaceCreatedOnADeviceCarriesItsAlias() {
        let store = makeStore()

        let id = store.addWorkspace(named: "Ship auth", on: .ssh(alias: "ukvps"))

        XCTAssertEqual(workspace(id, in: store)?.device, .ssh(alias: "ukvps"))
        XCTAssertEqual(workspace(id, in: store)?.deviceAlias, "ukvps")
    }

    /// `isAutoCreated` authorises deletion. It must be a recorded `false`, not a
    /// missing value: absent means "written before the field existed", which
    /// `WorkspaceMigration.reconcile` is free to re-derive.
    func testUserCreatedWorkspaceIsNotMarkedAutoCreated() {
        let store = makeStore()

        let local = store.addWorkspace(named: "Ship auth", on: .thisMac)
        let remote = store.addWorkspace(named: "Ship auth on the box", on: .ssh(alias: "ukvps"))

        XCTAssertEqual(workspace(local, in: store)?.isAutoCreated, false)
        XCTAssertEqual(workspace(remote, in: store)?.isAutoCreated, false,
                       "naming a machine is not the same as being made by Fyolo")
    }

    /// A machine's fallback is the other half of the contrast: nobody asked for
    /// it, so it is Fyolo's to sweep.
    func testTheMachineFallbackIsMarkedAutoCreated() {
        let store = makeStore()

        let id = store.deviceWorkspace(for: "ukvps")

        XCTAssertEqual(workspace(id, in: store)?.isAutoCreated, true)
    }

    /// Creating a workspace moves into it, and an empty scope has nothing to keep
    /// selected.
    func testCreatingAWorkspaceMovesIntoIt() {
        let store = makeStore()

        let id = store.addWorkspace(named: "Ship auth", on: .thisMac)

        XCTAssertEqual(store.currentWorkspaceID, id)
        XCTAssertNil(store.selectedSessionID)
    }
}
