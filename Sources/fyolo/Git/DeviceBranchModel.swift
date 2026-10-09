import FyoloShared
import Foundation
import Combine

/// Keeps a live branch label for checkouts on other machines — `BranchModel`'s
/// device-side twin, with the read and the watch relocated across the wire. The
/// daemon rides the workspace watch it already runs and re-reads `HEAD`
/// in-process (`fyolod/src/git.rs` `read_head`, the `head:` resource), so a
/// `git checkout` on the box updates the label here the way a local one does —
/// without the per-event `git status` the Changes pane's `git:` subscription
/// costs, which is what makes it affordable while the checkout is merely on
/// screen.
///
/// Batches are full state, never deltas: applying one is a replacement. A box
/// without a daemon, or with one too old to know `head:`, simply never answers,
/// and the label stays hidden — exactly what those sessions showed before.
///
/// Identity is the checkout — the machine *and* the root — because a remote
/// path can spell exactly like a local one (`~/repo` here and on the box), and
/// a label keyed by bare path would show one machine's branch beside the
/// other's name.
@MainActor
final class DeviceBranchModel: ObservableObject {
    struct Key: Hashable {
        /// `Checkout.deviceIdentity`: the `host_id` once a handshake has
        /// revealed one, the alias until then.
        let device: String
        let root: String
    }

    /// Checkout → branch label (the branch name, or a short commit hash when
    /// the checkout is in a detached HEAD). Absent while the device has not
    /// answered — or answered "not a repo" — so callers hide the chip.
    @Published private(set) var branches: [Key: String] = [:]
    @Published private(set) var detachedCheckouts: Set<Key> = []

    /// One armed `head:` subscription. The subscription object *is* the
    /// interest — releasing the last reference retires the watch on the device
    /// — so holding it here is what keeps the label live, and dropping the
    /// entry is the whole unsubscribe.
    private final class Watch {
        var subscription: Fyolod.ResourceSubscription?
        /// A handshake is in flight. What keeps a `setWatched` re-poke and the
        /// interruption retry from opening a second subscription over the one
        /// still being negotiated.
        var arming = false
        /// The last applied cursor, so two batches hopping to the main actor as
        /// separate tasks cannot land out of order and roll the label back.
        /// Reset when the watch re-arms: a resubscribe is served full state at
        /// whatever cursor the device is at, including a lower one after a
        /// daemon restart.
        var lastSeq: UInt64 = 0
    }

    private var watches: [Key: Watch] = [:]

    func branch(for checkout: Checkout) -> String? {
        Self.key(for: checkout).flatMap { branches[$0] }
    }

    func isDetached(_ checkout: Checkout) -> Bool {
        guard let key = Self.key(for: checkout) else { return false }
        return detachedCheckouts.contains(key)
    }

    /// Reconciles the watched set: arms any newly wanted checkout and drops any
    /// that has gone, forgetting its label. Idempotent, so the store can call it
    /// on every selection change. Checkouts on this Mac are ignored — they are
    /// `BranchModel`'s to watch.
    func setWatched(_ checkouts: [Checkout]) {
        var wanted: [Key: FyolodRoute] = [:]
        for checkout in checkouts {
            guard let key = Self.key(for: checkout) else { continue }
            wanted[key] = checkout.device.route
        }
        for key in watches.keys where wanted[key] == nil {
            watches[key] = nil
            if branches[key] != nil { branches[key] = nil }
            detachedCheckouts.remove(key)
        }
        for (key, route) in wanted {
            if let existing = watches[key] {
                // A watch whose handshake failed (the box was asleep, say) sits
                // here unarmed; the next reconcile — a selection change, the app
                // becoming active — is its retry.
                if existing.subscription == nil, !existing.arming {
                    arm(key, route: route, watch: existing)
                }
                continue
            }
            let watch = Watch()
            watches[key] = watch
            arm(key, route: route, watch: watch)
        }
    }

    private static func key(for checkout: Checkout) -> Key? {
        guard checkout.isOnAnotherDevice, let root = checkout.root else { return nil }
        return Key(device: checkout.deviceIdentity, root: root)
    }

    /// Opens the subscription for one checkout. Every completion is guarded by
    /// the `Watch`'s identity: a handshake or batch that outlives the interest
    /// that asked for it finds a different (or no) entry under its key and
    /// stands down — releasing the orphaned subscription, which retires the
    /// device's watch.
    private func arm(_ key: Key, route: FyolodRoute, watch: Watch) {
        watch.lastSeq = 0
        watch.arming = true
        // The wire closures are `@Sendable` and must not carry the main-actor
        // `Watch`; they carry its identity instead, and every hop back resolves
        // the *current* entry under the key and compares — a delivery that
        // outlives the interest that asked for it finds a different (or no)
        // watch and stands down.
        let token = ObjectIdentifier(watch)
        Task { [weak self] in
            defer {
                if let self, let current = self.watches[key],
                   ObjectIdentifier(current) == token {
                    current.arming = false
                }
            }
            do {
                let (subscription, _, _) = try await Fyolod.watchHead(
                    route: route,
                    root: key.root,
                    onBatch: { [weak self] batch in
                        Task { @MainActor [weak self] in
                            guard let self, let current = self.watches[key],
                                  ObjectIdentifier(current) == token else { return }
                            self.apply(batch, to: current, key: key)
                        }
                    },
                    onInterrupted: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, let current = self.watches[key],
                                  ObjectIdentifier(current) == token else { return }
                            self.interrupted(key, route: route, watch: current)
                        }
                    })
                guard let self, let current = self.watches[key],
                      ObjectIdentifier(current) == token else { return }
                current.subscription = subscription
            } catch {
                // The box is unreachable, its daemon predates `head:`, or the
                // root is not a repository there. The label stays hidden — the
                // honest answer, and what these sessions always showed.
            }
        }
    }

    private func apply(_ batch: Fyolod.HeadChangedPayload, to watch: Watch, key: Key) {
        guard batch.seq > watch.lastSeq else { return }
        watch.lastSeq = batch.seq
        let label = batch.branch ?? batch.head
        let detached = batch.branch == nil && batch.head != nil
        if detached != detachedCheckouts.contains(key) {
            if detached {
                detachedCheckouts.insert(key)
            } else {
                detachedCheckouts.remove(key)
            }
        }
        if branches[key] != label { branches[key] = label }
    }

    /// The channel dropped. The label is kept — the checkout did not stop
    /// having a branch, the pipe stopped saying so — and the watch re-arms
    /// after a beat, resuming as full state.
    private func interrupted(_ key: Key, route: FyolodRoute, watch: Watch) {
        watch.subscription = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.watches[key] === watch,
                  watch.subscription == nil, !watch.arming else { return }
            self.arm(key, route: route, watch: watch)
        }
    }
}
