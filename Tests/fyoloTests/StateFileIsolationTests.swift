import XCTest
@testable import fyolo

/// The test suite must never write to a channel a real fyolo reads.
///
/// `FyoloStore.projects` persists in its `didSet`, so *any* test that builds a
/// store over fixture projects writes a complete `state.json`. Under `swift test`
/// there is no `FYOLO_CHANNEL` and no `.dev` bundle id, so the channel resolved
/// to **release** — and a full run left the installed app owning one project at
/// `/code/fyolo`, wiping the user's real session tree. The whole tree, because
/// `persist` writes a snapshot rather than a patch.
@MainActor
final class StateFileIsolationTests: XCTestCase {
    func testTheChannelKnowsItIsUnderTest() {
        XCTAssertTrue(AppChannel.isRunningTests)
    }

    /// The directories that get *written* are the ones that have to move. Both,
    /// not just the state file: sockets, themes, downloaded binaries and agent
    /// definitions all hang off these two.
    func testWrittenDirectoriesLeaveEveryRealChannelAlone() {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        for directory in [AppChannel.supportDirectory, AppChannel.homeConfigDirectory] {
            let path = directory.standardizedFileURL.path
            XCTAssertTrue(path.hasPrefix(temporary), "\(path) is not under the temp directory")
            XCTAssertFalse(path.contains("Application Support"), path)
        }
    }

    /// The end-to-end version of the same claim, stated the way the bug was
    /// found: mutate a store's projects, then look for the fixture on disk
    /// anywhere a shipped fyolo would read it.
    func testAStoreMutationCannotReachAnInstalledFyoloSStateFile() throws {
        let defaults = UserDefaults(suiteName: "isolation-\(UUID().uuidString)")
            ?? UserDefaults.standard
        let workspace = Workspace(name: "Sessions")
        let store = FyoloStore(workspaces: [workspace], projects: [],
                                settings: AppSettings(defaults: defaults))

        let marker = "/code/fyolo-isolation-\(UUID().uuidString)"
        store.projects = [Project(workspaceID: workspace.id, name: "fyolo", path: marker,
                                  branch: "main", sessions: [])]

        // Decoded, not string-matched: `JSONEncoder` escapes `/` as `\/`, so a
        // `contains("/code/…")` over the raw file never matches — it would report
        // every channel clean, including a clobbered one.
        func persistedPaths(at url: URL) -> [String] {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(StateFile.Snapshot.self, from: data)
            else { return [] }
            return snapshot.projects.map(\.path)
        }

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        for channel in ["fyolo", "fyolo-dev"] {
            guard let stateURL = support?
                .appendingPathComponent(channel, isDirectory: true)
                .appendingPathComponent("state.json") else { continue }
            XCTAssertFalse(persistedPaths(at: stateURL).contains(marker),
                           "a test wrote a fixture project into \(stateURL.path)")
        }

        let isolated = AppChannel.supportDirectory.appendingPathComponent("state.json")
        XCTAssertTrue(
            persistedPaths(at: isolated).contains(marker),
            "the store did persist — to the isolated channel, which is the point")
    }
}
