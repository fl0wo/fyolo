import XCTest

@testable import fyolo

/// Dropping a sidebar row on a pane's edge (the drag form of "Group with"). The
/// zone math has its own tests in `SplitTreeTests`; these cover what the store
/// does with a zone once the pointer has resolved one — which side the pane takes,
/// which side the *row* takes, and the drops that must not become layout changes.
@MainActor
final class SessionDropTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "session-drop-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeStore(sessions: [Session], chats: [Session] = []) -> FyoloStore {
        var workspace = Workspace(name: "Default")
        workspace.terminals = sessions
        workspace.chats = chats
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
        return FyoloStore(workspaces: [workspace], settings: settings)
    }

    private func rowOrder(_ store: FyoloStore) -> [Session.ID] {
        store.workspaces.first?.terminals.map(\.id) ?? []
    }

    /// The half you drop on is the half you get: releasing on the anchor's left
    /// puts the dragged pane first, on a horizontal axis.
    func testDroppingOnTheLeftEdgeTakesTheLeadingHalf() {
        let anchor = Session(title: "Terminal 1")
        let moved = Session(title: "Terminal 2")
        let store = makeStore(sessions: [anchor, moved])

        store.dropSession(moved.id, onto: anchor.id, zone: .left)

        XCTAssertEqual(store.splitGroups.count, 1)
        XCTAssertEqual(store.splitGroups.first?.leafIDs, [moved.id, anchor.id])
        XCTAssertEqual(store.splitGroups.first?.branchDirection(childLeaf: anchor.id), .horizontal)
        XCTAssertEqual(store.selectedSessionID, moved.id)
    }

    /// A bottom drop is the same gesture on the other axis, and lands second.
    func testDroppingOnTheBottomEdgeStacksBelow() {
        let anchor = Session(title: "Terminal 1")
        let moved = Session(title: "Terminal 2")
        let store = makeStore(sessions: [anchor, moved])

        store.dropSession(moved.id, onto: anchor.id, zone: .bottom)

        XCTAssertEqual(store.splitGroups.first?.leafIDs, [anchor.id, moved.id])
        XCTAssertEqual(store.splitGroups.first?.branchDirection(childLeaf: anchor.id), .vertical)
    }

    /// The sidebar reads a group as one adjacent run, in the layout's order — so a
    /// pane that landed on the leading side lists *above* its anchor, not below it.
    func testTheRowFollowsTheSideThePaneLandedOn() {
        let first = Session(title: "Terminal 1")
        let anchor = Session(title: "Terminal 2")
        let moved = Session(title: "Terminal 3")
        let store = makeStore(sessions: [first, anchor, moved])

        store.dropSession(moved.id, onto: anchor.id, zone: .top)

        XCTAssertEqual(rowOrder(store), [first.id, moved.id, anchor.id])
    }

    /// A pane already grouped with the target is only being rearranged: it moves
    /// within the tree instead of being spliced in a second time.
    func testDroppingInsideTheSameGroupRearrangesRatherThanDuplicates() {
        let anchor = Session(title: "Terminal 1")
        let moved = Session(title: "Terminal 2")
        let store = makeStore(sessions: [anchor, moved])
        store.dropSession(moved.id, onto: anchor.id, zone: .right)

        store.dropSession(moved.id, onto: anchor.id, zone: .left)

        XCTAssertEqual(store.splitGroups.count, 1)
        XCTAssertEqual(store.splitGroups.first?.leafIDs, [moved.id, anchor.id])
    }

    /// A session drag has no dead middle: releasing dead centre still picks a side,
    /// because "group in beside this pane" is the only thing the gesture means.
    func testEveryPointOfAPaneIsALiveEdge() {
        let size = CGSize(width: 800, height: 600)
        for point in [CGPoint(x: 400, y: 300), CGPoint(x: 401, y: 299), CGPoint(x: 0, y: 0)] {
            XCTAssertNotNil(PaneDropZone.edge(at: point, in: size).splitDirection,
                            "no edge at \(point)")
        }
        XCTAssertEqual(PaneDropZone.edge(at: CGPoint(x: 60, y: 300), in: size), .left)
        XCTAssertEqual(PaneDropZone.edge(at: CGPoint(x: 400, y: 560), in: size), .bottom)
    }

    /// The center zone still exists for the pane-rearrange drag, where it means
    /// swap — so `dropSession` keeps refusing it rather than guessing a side.
    func testTheCenterIsNotALayoutChange() {
        let anchor = Session(title: "Terminal 1")
        let moved = Session(title: "Terminal 2")
        let store = makeStore(sessions: [anchor, moved])

        store.dropSession(moved.id, onto: anchor.id, zone: .center)

        XCTAssertTrue(store.splitGroups.isEmpty)
    }

    /// Two sessions in different checkouts can't be grouped — their rows can't be
    /// made adjacent without breaking the other bucket's run, which is what the
    /// group bracket is drawn from.
    func testSessionsInDifferentWorktreesDoNotGroup() {
        var anchor = Session(title: "Terminal 1")
        anchor.worktreePath = "/tmp/checkout-a"
        var moved = Session(title: "Terminal 2")
        moved.worktreePath = "/tmp/checkout-b"
        let store = makeStore(sessions: [anchor, moved])

        XCTAssertFalse(store.canGroup(moved.id, with: anchor.id))
        store.dropSession(moved.id, onto: anchor.id, zone: .right)

        XCTAssertTrue(store.splitGroups.isEmpty)
    }

    // MARK: - Sidebar row gaps

    /// The insertion line names a gap, so the row lands in that gap — not in the one
    /// the drag direction would have implied. Dragging downward onto a row's *top*
    /// third has to land above it, which is the case the old direction-inferred
    /// reorder got backwards.
    func testReorderLandsOnTheSideTheCallerNames() {
        let first = Session(title: "Terminal 1")
        let second = Session(title: "Terminal 2")
        let third = Session(title: "Terminal 3")
        let store = makeStore(sessions: [first, second, third])

        store.reorderSession(first.id, relativeTo: third.id, insert: .above)

        XCTAssertEqual(rowOrder(store), [second.id, first.id, third.id])
    }

    /// The same drag, the other gap.
    func testReorderBelowLandsAfterTheTarget() {
        let first = Session(title: "Terminal 1")
        let second = Session(title: "Terminal 2")
        let third = Session(title: "Terminal 3")
        let store = makeStore(sessions: [first, second, third])

        store.reorderSession(third.id, relativeTo: first.id, insert: .below)

        XCTAssertEqual(rowOrder(store), [first.id, third.id, second.id])
    }

    /// Dragging upward and dragging downward into the same gap must agree — the
    /// side is the pointer's, so the row that started lower cannot land elsewhere.
    func testTheSameGapIsReachedFromEitherDirection() {
        let a = Session(title: "Terminal 1")
        let b = Session(title: "Terminal 2")
        let store = makeStore(sessions: [a, b])

        store.reorderSession(b.id, relativeTo: a.id, insert: .above)
        XCTAssertEqual(rowOrder(store), [b.id, a.id])

        store.reorderSession(a.id, relativeTo: b.id, insert: .above)
        XCTAssertEqual(rowOrder(store), [a.id, b.id])
    }

    /// Rows in different rosters never reorder into each other — a row cannot leave
    /// its section by being dropped on one — so the gap cue stays dark there rather
    /// than offering a move that would not happen.
    func testReorderRefusesAcrossRosters() {
        let terminal = Session(title: "Terminal 1")
        let chat = Session(title: "Chat 1")
        let store = makeStore(sessions: [terminal], chats: [chat])

        XCTAssertFalse(store.canReorder(chat.id, relativeTo: terminal.id))
        store.reorderSession(chat.id, relativeTo: terminal.id, insert: .above)

        XCTAssertEqual(rowOrder(store), [terminal.id])
        XCTAssertEqual(store.workspaces.first?.chats.map(\.id), [chat.id])
    }

    /// Dropping a row on its own pane is the degenerate case of the same gesture.
    func testASessionCannotBeGroupedWithItself() {
        let session = Session(title: "Terminal 1")
        let store = makeStore(sessions: [session])

        XCTAssertFalse(store.canGroup(session.id, with: session.id))
        store.dropSession(session.id, onto: session.id, zone: .right)

        XCTAssertTrue(store.splitGroups.isEmpty)
    }
}
