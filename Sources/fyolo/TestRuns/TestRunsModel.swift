import Combine
import FyoloShared
import Foundation

/// The selected checkout's Vitest runs, live and recorded: the inspector's Tests
/// segment and pane read the same state.
///
/// The device records every run whether or not anyone is watching
/// (`fyolod/src/test_runs.rs`), so this model only has to follow the checkout on
/// screen. It subscribes to the checkout's `tests:` resource first and lists
/// second, holding back events that land between the two, so a run that starts
/// while the list is in flight is neither lost nor applied out of order. A device
/// whose daemon predates `test_runs` answers nothing, and the segment stays
/// hidden.
@MainActor
final class TestRunsModel: ObservableObject {
    /// Newest first: the live run, if any, then the last finished ones the
    /// device keeps.
    @Published private(set) var runs: [Fyolod.TestRunSummary] = []
    @Published private(set) var details: [String: Fyolod.TestRunDetail] = [:]
    @Published private(set) var loadingDetails: Set<String> = []
    /// The device has answered for this checkout, with runs or without.
    @Published private(set) var hasAnswered = false

    /// The checkout being followed, and the root the device files its runs
    /// under (its repository), once the list has said.
    private(set) var checkout: Checkout?
    private(set) var root: String?
    private var subscription: Fyolod.ResourceSubscription?
    private var arming = false
    /// Bumped on every re-point, so a reply that outlives the checkout it was
    /// asked for stands down.
    private var generation = 0
    /// The last applied resource cursor. Events hop to the main actor as separate
    /// tasks and can arrive out of order; an older one must not roll a row back.
    private var lastSeq: UInt64 = 0
    /// Events received before the list arrived, applied on top of it.
    private var heldBack: [(seq: UInt64, run: Fyolod.TestRunSummary)]?

    var latest: Fyolod.TestRunSummary? { runs.first }

    /// Points the model at `checkout`. Idempotent for the checkout already
    /// followed, except that it retries a watch that could not be armed.
    func follow(_ checkout: Checkout?) {
        if checkout == self.checkout, subscription != nil || arming { return }
        if checkout != self.checkout {
            self.checkout = checkout
            root = nil
            runs = []
            details = [:]
            loadingDetails = []
            hasAnswered = false
        }
        subscription = nil
        generation += 1
        guard let checkout, let candidate = checkout.root else { return }
        arm(route: checkout.device.route, root: candidate, generation: generation)
    }

    /// Fetches a finished run's per-file results and failures once.
    func loadDetail(for run: Fyolod.TestRunSummary) {
        guard !run.isRunning, details[run.id] == nil, !loadingDetails.contains(run.id),
              let checkout, let root else { return }
        loadingDetails.insert(run.id)
        let generation = generation
        Task { [weak self] in
            let detail: Fyolod.TestRunDetail?
            do {
                detail = try await Fyolod.testRunDetail(
                    route: checkout.device.route, root: root, id: run.id)
            } catch {
                Log.fyolod.error("test run detail failed: \(error.localizedDescription, privacy: .public)")
                detail = nil
            }
            guard let self, self.generation == generation else { return }
            self.loadingDetails.remove(run.id)
            // A run the device no longer keeps reads as one with nothing to show.
            self.details[run.id] = detail ?? Fyolod.TestRunDetail()
        }
    }

    private func arm(route: FyolodRoute, root candidate: String, generation: Int) {
        arming = true
        lastSeq = 0
        heldBack = []
        Task { [weak self] in
            do {
                let subscription = try await Fyolod.watchTestRuns(
                    route: route,
                    root: candidate,
                    onRun: { [weak self] seq, run in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.receive(seq: seq, run: run)
                        }
                    },
                    onInterrupted: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.interrupted()
                        }
                    })
                guard let self, self.generation == generation else { return }
                self.subscription = subscription
                let listed = try await Fyolod.testRuns(route: route, root: candidate)
                guard self.generation == generation else { return }
                self.root = listed.root
                self.runs = listed.runs
                let held = self.heldBack ?? []
                self.heldBack = nil
                for event in held { self.receive(seq: event.seq, run: event.run) }
                self.arming = false
                self.hasAnswered = true
            } catch {
                // An unreachable box, or a daemon without `test_runs`. Nothing to
                // show is the honest answer; the next `follow` retries.
                guard let self, self.generation == generation else { return }
                self.subscription = nil
                self.arming = false
                self.hasAnswered = true
            }
        }
    }

    private func receive(seq: UInt64, run: Fyolod.TestRunSummary) {
        if heldBack != nil {
            heldBack?.append((seq, run))
            return
        }
        guard seq > lastSeq else { return }
        lastSeq = seq
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            if runs[index] != run { runs[index] = run }
        } else {
            let index = runs.firstIndex(where: { $0.startedAt < run.startedAt }) ?? runs.endIndex
            runs.insert(run, at: index)
            trimToHistory()
        }
        // A finished run's detail is new; whatever was cached (nothing, for a
        // live run) is stale.
        if !run.isRunning { details[run.id] = nil }
    }

    /// Keeps what the device keeps: every live run, and the newest finished ones
    /// up to its cap. The device has already deleted the rest.
    private func trimToHistory() {
        var finished = 0
        runs.removeAll { run in
            guard !run.isRunning else { return false }
            finished += 1
            if finished > Self.finishedRunsKept {
                details[run.id] = nil
                return true
            }
            return false
        }
    }

    /// `fyolod/src/test_runs.rs` `RUNS_PER_ROOT`.
    private static let finishedRunsKept = 6

    /// The channel dropped. The rows stay, and the watch re-arms after a beat,
    /// re-listing to pick up what finished meanwhile.
    private func interrupted() {
        subscription = nil
        let generation = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.generation == generation, self.subscription == nil,
                  !self.arming, let checkout = self.checkout, let root = checkout.root else { return }
            self.arm(route: checkout.device.route, root: root, generation: generation)
        }
    }
}
