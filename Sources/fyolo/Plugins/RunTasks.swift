import Combine
import Foundation

/// The run capsule's recents: per project root, the last `limit` tasks run there,
/// newest first, each at most once, with the terminal it last ran in.
struct RunHistory: Codable, Equatable {
    struct Record: Codable, Hashable {
        var task: RunTask
        /// The terminal the task last ran in — reused for the next run while it is
        /// open and idle, so repeated runs don't pile up panes.
        var sessionID: UUID?
    }

    static let limit = 10

    /// Keyed by the project root's path.
    private(set) var records: [String: [Record]] = [:]
    /// The task each project's capsule shows, by `RunTask.id`.
    private(set) var selected: [String: String] = [:]

    func recents(in root: String) -> [Record] {
        records[root] ?? []
    }

    /// The capsule's task: the one picked from the dropdown, else the latest run.
    func selectedRecord(in root: String) -> Record? {
        let recents = recents(in: root)
        return recents.first { $0.task.id == selected[root] } ?? recents.first
    }

    func record(for taskID: String) -> Record? {
        for list in records.values {
            if let found = list.first(where: { $0.task.id == taskID }) { return found }
        }
        return nil
    }

    /// Moves `task` to the front (or adds it), selects it, and drops the oldest
    /// past the limit.
    mutating func record(_ task: RunTask, session: UUID?, in root: String) {
        var list = recents(in: root).filter { $0.task.id != task.id }
        list.insert(Record(task: task, sessionID: session), at: 0)
        records[root] = Array(list.prefix(Self.limit))
        selected[root] = task.id
    }

    mutating func select(_ taskID: String, in root: String) {
        guard recents(in: root).contains(where: { $0.task.id == taskID }) else { return }
        selected[root] = taskID
    }

    mutating func clear(in root: String) {
        records[root] = nil
        selected[root] = nil
    }

    /// A closed terminal is no longer anyone's to reuse.
    mutating func forgetSessions(where isGone: (UUID) -> Bool) {
        for (root, list) in records where list.contains(where: { $0.sessionID.map(isGone) == true }) {
            records[root] = list.map { record in
                var record = record
                if record.sessionID.map(isGone) == true { record.sessionID = nil }
                return record
            }
        }
    }

    /// Drops every project whose root fails `keep` — a folder deleted since.
    mutating func prune(keeping keep: (String) -> Bool) {
        for root in records.keys where !keep(root) {
            clear(in: root)
        }
    }
}

/// What is running right now, and the recents it is drawn from. Its own
/// observable rather than more `FyoloStore` state, so a task starting or
/// stopping redraws the capsule and the gutter, not everything the store feeds.
///
/// A task counts as running from the click until the shell has it back. The
/// signals, all forwarded by the store:
/// - the device's foreground-job sample (any shell, any machine, ~2s cadence);
/// - the shell's OSC 133 command-finished mark (zsh under fyolod, instant);
/// - the terminal closing or exiting.
/// A command too short for the sampler to ever see in front, in a shell without
/// the mark, is caught by `startTimeout`.
@MainActor
final class RunTasks: ObservableObject {
    enum Phase: Equatable {
        /// Clicked, not yet seen in front of the shell.
        case starting
        case running
    }

    @Published private(set) var history: RunHistory
    @Published private(set) var phases: [String: Phase] = [:]

    /// Called after every change to `history`, so the store can persist it.
    var onHistoryChange: (() -> Void)?

    private var finishWatches: [UUID: AnyCancellable] = [:]
    private var startTimeouts: [String: Task<Void, Never>] = [:]
    /// Long enough for the device's 2s foreground poll to report a job twice over.
    private static let startTimeout: Duration = .seconds(5)

    init(history: RunHistory = RunHistory()) {
        self.history = history
    }

    /// The recents saved by the last run of the app.
    func restore(_ history: RunHistory) {
        self.history = history
    }

    func isRunning(_ task: RunTask) -> Bool {
        phases[task.id] != nil
    }

    func recents(in root: String?) -> [RunHistory.Record] {
        root.map { history.recents(in: $0) } ?? []
    }

    func selectedRecord(in root: String?) -> RunHistory.Record? {
        root.flatMap { history.selectedRecord(in: $0) }
    }

    func select(_ task: RunTask, in root: String) {
        history.select(task.id, in: root)
        onHistoryChange?()
    }

    func clear(in root: String) {
        history.clear(in: root)
        onHistoryChange?()
    }

    /// The terminal `task` last ran in, if it is still recorded.
    func session(of task: RunTask) -> UUID? {
        history.record(for: task.id)?.sessionID
    }

    /// A run was asked for: it shows as running at once and enters the recents.
    func willStart(_ task: RunTask, in root: String) {
        finish(task.id)
        phases[task.id] = .starting
        history.record(task, session: session(of: task), in: root)
        onHistoryChange?()
    }

    /// The command was typed into `session`. `commandFinished` fires each time the
    /// shell closes a command with OSC 133 `D`, when the terminal reports it.
    func didDeliver(_ task: RunTask, to session: UUID, in root: String,
                    commandFinished: AnyPublisher<Void, Never>?) {
        guard phases[task.id] != nil else { return }
        history.record(task, session: session, in: root)
        onHistoryChange?()
        finishWatches[session] = commandFinished?.sink { [weak self] in
            self?.finish(task.id)
        }
        startTimeouts[task.id]?.cancel()
        startTimeouts[task.id] = Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, self.phases[task.id] == .starting else { return }
            self.finish(task.id)
        }
    }

    /// The command never reached a terminal.
    func didFail(_ task: RunTask) {
        finish(task.id)
    }

    /// The device's word on whether a job holds `session`'s foreground. A job in
    /// front of a task's terminal is that task — which is also what brings the
    /// stop button back for a task that kept running across a relaunch.
    func noteForegroundJob(_ running: Bool, in session: UUID) {
        for list in history.records.values {
            for record in list where record.sessionID == session {
                let id = record.task.id
                if running {
                    if phases[id] != .running {
                        startTimeouts[id]?.cancel()
                        startTimeouts[id] = nil
                        phases[id] = .running
                    }
                } else if phases[id] == .running {
                    finish(id)
                }
            }
        }
    }

    /// The terminal closed or its shell exited.
    func sessionEnded(_ session: UUID) {
        finishWatches[session] = nil
        guard history.records.values.contains(where: { $0.contains { $0.sessionID == session } })
        else { return }
        for list in history.records.values {
            for record in list where record.sessionID == session {
                finish(record.task.id)
            }
        }
        history.forgetSessions { $0 == session }
        onHistoryChange?()
    }

    private func finish(_ taskID: String) {
        startTimeouts[taskID]?.cancel()
        startTimeouts[taskID] = nil
        if phases[taskID] != nil { phases[taskID] = nil }
    }
}
