import XCTest
@testable import fyolo

/// A spawned prompt that was written but never received.
///
/// `performDelivery` answers whether bytes could be *written* to a surface,
/// which is weaker than it reads. An agent still on a startup gate — a
/// hook-trust prompt, a usage notice, a first-run dialog — consumes typed text
/// as the answer to its own question and shows nothing for it. The write
/// succeeds, the prompt is gone, and `spawn` has already replied with an
/// address.
///
/// That gate also defeats the readiness check that precedes typing, whose test
/// is two identical frames: a program waiting for a keypress is perfectly
/// still. So this cannot be prevented before the fact, only reported after it,
/// and `sessions list` is where a caller who already has its reply can find out.
@MainActor
final class UndeliveredPromptTests: XCTestCase {
    private func makeStore(_ session: Session) -> FyoloStore {
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "fyolo", path: "/code/fyolo",
                              branch: "main", sessions: [session])
        let defaults = UserDefaults(suiteName: "undelivered-\(UUID().uuidString)")
        return FyoloStore(workspaces: [workspace], projects: [project],
                           settings: AppSettings(defaults: defaults ?? .standard))
    }

    func testASessionStartsWithNoUndeliveredPrompt() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(session)
        XCTAssertFalse(store.undeliveredPrompts.contains(session.id))
    }

    /// The record is what turns an invisible failure into a visible one.
    func testNotingAnUndeliveredPromptMarksTheSession() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(session)

        store.noteUndeliveredPrompt(for: session.id)

        XCTAssertTrue(
            store.undeliveredPrompts.contains(session.id),
            "a prompt that never reached the agent left no trace for the caller to find")
    }

    /// It describes the present, not history: once anything has been driven into
    /// the session by hand, the warning has served its purpose and must go —
    /// otherwise every later `list` keeps accusing a session that is now fine.
    func testTheWarningClearsOnceTheSessionIsDrivenAgain() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(session)
        store.noteUndeliveredPrompt(for: session.id)

        store.undeliveredPrompts.remove(session.id)

        XCTAssertFalse(store.undeliveredPrompts.contains(session.id))
    }

    /// Marking one session must not implicate its siblings — the whole point is
    /// telling apart the spawn that failed from the ones working quietly.
    func testTheMarkIsPerSession() {
        let failed = Session(title: "gated", agent: .terminal)
        let fine = Session(title: "working", agent: .terminal)
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "fyolo", path: "/code/fyolo",
                              branch: "main", sessions: [failed, fine])
        let defaults = UserDefaults(suiteName: "undelivered-multi-\(UUID().uuidString)")
        let store = FyoloStore(workspaces: [workspace], projects: [project],
                                settings: AppSettings(defaults: defaults ?? .standard))

        store.noteUndeliveredPrompt(for: failed.id)

        XCTAssertTrue(store.undeliveredPrompts.contains(failed.id))
        XCTAssertFalse(store.undeliveredPrompts.contains(fine.id))
    }
}
