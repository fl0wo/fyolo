import CoreGraphics
import Foundation

/// How a split arranges its two children: `.horizontal` places them side by side
/// (the "Split Right" action, divider running vertically), `.vertical` stacks
/// them (the "Split Down" action).
enum SplitDirection: String, Codable, Hashable {
    case horizontal
    case vertical
}

/// A direction the user can move pane focus in (⌥⌘ arrows). Separate from
/// `SplitDirection` because focus moves along an edge, not along a split axis.
enum PaneFocusDirection {
    case left, right, up, down
}

/// Which side of a new divider an added pane takes. `.second` is the trailing
/// slot — what "Split Right"/"Split Down" mean — and `.first` the leading one,
/// which is how a drag-drop onto a pane's left/top half lands the dropped pane
/// *before* its target.
enum SplitSlot {
    case first, second
}

/// Where a modifier-dragged pane is about to land on the pane under the
/// pointer (issue #183): an edge half → the target splits and the dragged pane
/// takes that side; the center → the two panes trade places (the existing
/// `swapping` behaviour). Pure math on pane-local geometry, so the hit regions
/// are testable without a view in sight. Points are in top-left-origin space.
enum PaneDropZone: Equatable {
    case left, right, top, bottom
    case center

    /// The middle box (as a fraction of each axis) that reads as "swap" rather
    /// than an edge: 0.4 keeps the swap target hittable without aiming while
    /// leaving each edge a generous 30% band.
    private static let centerFraction: CGFloat = 0.4

    /// The zone for a pointer at `point` in a pane of `size`. Outside the
    /// center box the nearest edge wins — the corner-to-corner diagonals
    /// ghostty's split drag uses, which give each edge a natural triangular
    /// region.
    static func zone(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let relX = point.x / size.width
        let relY = point.y / size.height
        let half = centerFraction / 2
        if abs(relX - 0.5) <= half, abs(relY - 0.5) <= half { return .center }
        return edge(at: point, in: size)
    }

    /// The nearest edge, with no center box — the zoning a session dragged out of
    /// the sidebar uses. That drag has exactly one meaning, "group in on this
    /// side", so every part of the pane has to answer it: a middle that did
    /// something else would be a dead zone you can only discover by missing.
    static func edge(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .left }
        let relX = point.x / size.width
        let relY = point.y / size.height
        let edges: [(PaneDropZone, CGFloat)] = [
            (.left, relX), (.right, 1 - relX), (.top, relY), (.bottom, 1 - relY),
        ]
        return edges.min { $0.1 < $1.1 }?.0 ?? .left
    }

    /// The part of the target pane to highlight while this zone is hovered:
    /// the half the dropped pane would occupy, or the whole pane for a swap —
    /// the preview that makes the drop unambiguous before the mouse releases.
    func highlightRect(in frame: CGRect) -> CGRect {
        switch self {
        case .left:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:
            CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom:
            CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        case .center:
            frame
        }
    }

    /// The split axis a drop here produces, or `nil` for the center swap.
    var splitDirection: SplitDirection? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    /// The slot the dragged pane takes in the new branch: leading for the
    /// left/top halves, trailing for right/bottom.
    var slot: SplitSlot {
        switch self {
        case .left, .top: .first
        case .right, .bottom, .center: .second
        }
    }
}

/// A branch of the split tree: two subtrees separated by a draggable divider.
/// `ratio` is the fraction of the branch's span given to `first`; it is clamped
/// so neither side can be dragged into an unusable sliver.
struct SplitBranch: Codable, Hashable {
    var id = UUID()
    var direction: SplitDirection
    var ratio: Double
    /// Whether this divider's ratio was set deliberately — a user drag, or a
    /// spawn that asked for a specific share. `equalized()` leaves pinned
    /// dividers alone, so stated intent survives later inserts and removals;
    /// everything unpinned is app-chosen and free to redistribute.
    var pinned: Bool
    var first: SplitNode
    var second: SplitNode

    /// The narrowest either side may be dragged to. Matches the floor terminal
    /// panes need to stay readable; applied on every ratio write so a persisted
    /// tree can never restore into a degenerate layout either.
    static let ratioRange: ClosedRange<Double> = 0.15...0.85

    static func clampedRatio(_ ratio: Double) -> Double {
        min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    init(direction: SplitDirection, ratio: Double, pinned: Bool = false,
         first: SplitNode, second: SplitNode) {
        self.direction = direction
        self.ratio = ratio
        self.pinned = pinned
        self.first = first
        self.second = second
    }

    /// The branch an insert produces: `newPane` takes `slot`, with `share` of
    /// the span when the caller stated one (a spawn's `--ratio`) — a stated
    /// share pins the divider so `equalized()` keeps it. No share splits at
    /// half, unpinned, free to redistribute. Keeping this arithmetic in one
    /// place is what guarantees every insert path pins on exactly the same
    /// condition.
    init(direction: SplitDirection, adding newPane: SplitNode, at slot: SplitSlot,
         share: Double?, to existing: SplitNode) {
        let clamped = share.map(Self.clampedRatio)
        self.init(direction: direction,
                  ratio: clamped.map { slot == .first ? $0 : 1 - $0 } ?? 0.5,
                  pinned: clamped != nil,
                  first: slot == .first ? newPane : existing,
                  second: slot == .first ? existing : newPane)
    }

    /// `pinned` arrived after trees were already persisted, so it decodes as
    /// absent-means-false rather than failing on an older state file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        direction = try container.decode(SplitDirection.self, forKey: .direction)
        ratio = try container.decode(Double.self, forKey: .ratio)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        first = try container.decode(SplitNode.self, forKey: .first)
        second = try container.decode(SplitNode.self, forKey: .second)
    }
}

/// The split layout of the terminal area: a binary tree whose leaves are
/// sessions and whose branches are draggable dividers. The tree is a pure value
/// — every mutation returns a new tree — so `FyoloStore` can hold it as one
/// `@Published` property and persistence is plain `Codable`.
///
/// There is deliberately no "tabs inside a pane" layer (the sidebar already
/// plays that role): a leaf *is* a session, which keeps the whole model to one
/// enum and a handful of recursions.
indirect enum SplitNode: Codable, Hashable {
    case leaf(Session.ID)
    case split(SplitBranch)

    /// The sessions shown by this tree, in visual order (left-to-right,
    /// top-to-bottom).
    var leafIDs: [Session.ID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let branch): return branch.first.leafIDs + branch.second.leafIDs
        }
    }

    func contains(_ id: Session.ID) -> Bool {
        switch self {
        case .leaf(let leaf): return leaf == id
        case .split(let branch): return branch.first.contains(id) || branch.second.contains(id)
        }
    }

    /// The axis of the branch that has `id` as a direct child — the direction the
    /// pane is currently divided along. Used to add a neighbour on the *cross*
    /// axis so splits alternate the way a tiling window manager does. `nil` when
    /// `id` is a lone pane with no enclosing branch.
    func branchDirection(childLeaf id: Session.ID) -> SplitDirection? {
        switch self {
        case .leaf:
            return nil
        case .split(let branch):
            if branch.first == .leaf(id) || branch.second == .leaf(id) {
                return branch.direction
            }
            return branch.first.branchDirection(childLeaf: id)
                ?? branch.second.branchDirection(childLeaf: id)
        }
    }

    /// Replaces the `target` leaf with a split of it and `newLeaf`. The default
    /// slot puts the new pane second/trailing, matching "Split Right"/"Split
    /// Down"; a drag-drop passes `.first` to land it on the leading side.
    /// `newShare` is the fraction the *new* pane takes; naming one pins the
    /// divider (see `SplitBranch.pinned`), leaving it unnamed splits at half
    /// and lets `equalized()` redistribute. A miss returns the tree unchanged.
    func splitting(leaf target: Session.ID, direction: SplitDirection,
                   adding newLeaf: Session.ID, slot: SplitSlot = .second,
                   newShare: Double? = nil) -> SplitNode {
        switch self {
        case .leaf(let id) where id == target:
            return .split(SplitBranch(direction: direction, adding: .leaf(newLeaf), at: slot,
                                      share: newShare, to: .leaf(id)))
        case .leaf:
            return self
        case .split(var branch):
            branch.first = branch.first.splitting(leaf: target, direction: direction,
                                                  adding: newLeaf, slot: slot, newShare: newShare)
            branch.second = branch.second.splitting(leaf: target, direction: direction,
                                                    adding: newLeaf, slot: slot, newShare: newShare)
            return .split(branch)
        }
    }

    /// Adds `newLeaf` on the far side of `target`'s divider: finds the branch
    /// that has `target` as a direct child and splits the *sibling* subtree on
    /// the cross axis, so `target`'s own pane keeps its full extent. This is the
    /// spawn placement rule — an agent that keeps spawning companions stays
    /// full-height while the companions stack up opposite it. A miss returns
    /// the tree unchanged.
    func splitting(oppositeLeaf target: Session.ID, adding newLeaf: Session.ID,
                   newShare: Double? = nil) -> SplitNode {
        switch self {
        case .leaf:
            return self
        case .split(var branch):
            let cross: SplitDirection = branch.direction == .horizontal ? .vertical : .horizontal
            if branch.first == .leaf(target) {
                branch.second = .split(SplitBranch(direction: cross, adding: .leaf(newLeaf),
                                                   at: .second, share: newShare, to: branch.second))
            } else if branch.second == .leaf(target) {
                branch.first = .split(SplitBranch(direction: cross, adding: .leaf(newLeaf),
                                                  at: .second, share: newShare, to: branch.first))
            } else {
                branch.first = branch.first.splitting(oppositeLeaf: target, adding: newLeaf,
                                                      newShare: newShare)
                branch.second = branch.second.splitting(oppositeLeaf: target, adding: newLeaf,
                                                        newShare: newShare)
            }
            return .split(branch)
        }
    }

    /// Trades the positions of two leaves, leaving the tree's shape and every
    /// divider ratio untouched — the "Move Pane" primitive (tmux's swap-pane).
    /// Swapping is what keeps moving a one-click menu action: the layout offers
    /// no ambiguous drop targets to negotiate, panes only change places.
    func swapping(_ a: Session.ID, and b: Session.ID) -> SplitNode {
        // Both leaves must be present, or the rewrite below would *replace* the
        // present one with the absent one — a dangling pane, not a swap.
        guard contains(a), contains(b) else { return self }
        return swapped(a, b)
    }

    private func swapped(_ a: Session.ID, _ b: Session.ID) -> SplitNode {
        switch self {
        case .leaf(a): return .leaf(b)
        case .leaf(b): return .leaf(a)
        case .leaf: return self
        case .split(var branch):
            branch.first = branch.first.swapped(a, b)
            branch.second = branch.second.swapped(a, b)
            return .split(branch)
        }
    }

    /// Removes a leaf, collapsing its parent branch into the surviving sibling
    /// (muxy's unwrap-one-level close). Returns `nil` when the removal consumes
    /// the whole tree.
    func removing(leaf target: Session.ID) -> SplitNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(var branch):
            let first = branch.first.removing(leaf: target)
            let second = branch.second.removing(leaf: target)
            switch (first, second) {
            case (nil, nil): return nil
            case (nil, let survivor?), (let survivor?, nil): return survivor
            case (let first?, let second?):
                branch.first = first
                branch.second = second
                return .split(branch)
            }
        }
    }

    /// Writes a divider's ratio (clamped), leaving the rest of the tree intact.
    /// A dragged divider is pinned: the user chose this ratio, so `equalized()`
    /// must not overwrite it when the group's shape next changes.
    func updatingRatio(branchID: UUID, to ratio: Double) -> SplitNode {
        switch self {
        case .leaf:
            return self
        case .split(var branch):
            if branch.id == branchID {
                branch.ratio = SplitBranch.clampedRatio(ratio)
                branch.pinned = true
            } else {
                branch.first = branch.first.updatingRatio(branchID: branchID, to: ratio)
                branch.second = branch.second.updatingRatio(branchID: branchID, to: ratio)
            }
            return .split(branch)
        }
    }

    /// Redistributes every *unpinned* divider so the panes of a same-direction
    /// run share its span evenly — split right twice gives thirds, not
    /// 1/2 + 1/4 + 1/4, and a spawn stack of three companions reads as three
    /// equal rows. A divider's weight is how many chain segments each side
    /// holds (a cross-axis subtree counts as one segment, so a lone divider
    /// stays at half). Pinned dividers keep their ratio; their subtrees still
    /// equalize within whatever space the pin allots them. Idempotent — the
    /// store can call it after every structural mutation.
    func equalized() -> SplitNode {
        switch self {
        case .leaf:
            return self
        case .split(var branch):
            if !branch.pinned {
                let first = branch.first.segmentCount(along: branch.direction)
                let second = branch.second.segmentCount(along: branch.direction)
                branch.ratio = SplitBranch.clampedRatio(Double(first) / Double(first + second))
            }
            branch.first = branch.first.equalized()
            branch.second = branch.second.equalized()
            return .split(branch)
        }
    }

    /// How many side-by-side segments this subtree contributes to a run along
    /// `direction`: same-direction branches flatten into their children's
    /// counts, anything else — a leaf or a cross-axis split — is one segment.
    private func segmentCount(along direction: SplitDirection) -> Int {
        switch self {
        case .leaf:
            return 1
        case .split(let branch):
            guard branch.direction == direction else { return 1 }
            return branch.first.segmentCount(along: direction)
                + branch.second.segmentCount(along: direction)
        }
    }

    // MARK: - Layout

    /// One divider the view should draw and make draggable, in the same
    /// coordinate space `layout(in:)` was given.
    struct DividerSpec: Identifiable, Hashable {
        /// The owning branch's id — what `updatingRatio` is keyed by.
        let id: UUID
        let direction: SplitDirection
        /// The visible divider line (thickness `dividerThickness`).
        let frame: CGRect
        /// The branch's full span along its axis, for translating a drag delta
        /// into a ratio delta.
        let span: CGFloat
        /// The ratio at layout time — the drag's anchor value.
        let ratio: Double
    }

    struct PaneLayout {
        var frames: [Session.ID: CGRect] = [:]
        var dividers: [DividerSpec] = []
    }

    /// Computes every pane's rect and every divider from the tree — the muxy
    /// `areaFrames` idea, extended to also emit the dividers. The view layer
    /// stays a flat ZStack (fyolo's surfaces must never be structurally
    /// re-parented), so this is the *only* place split geometry exists.
    /// `dividerThickness: 0` yields normalized frames for focus scoring.
    func layout(in rect: CGRect, dividerThickness: CGFloat = 1) -> PaneLayout {
        var result = PaneLayout()
        accumulateLayout(in: rect, dividerThickness: dividerThickness, into: &result)
        return result
    }

    /// Every grouped pane's frame across *all* the groups, laid out in the same
    /// rect — the geometry a pane has whether or not its group is the one on
    /// screen. `TerminalPane` sizes mounted surfaces from this rather than from
    /// the selected group's layout alone: a group's panes then keep their frames
    /// while hidden, so switching sessions never resizes a surface it is merely
    /// hiding or revealing (issue #245). A session in no group is absent — the
    /// pane lays those out at its full bounds, the size they have when selected.
    static func paneFrames(of groups: [SplitNode], in rect: CGRect) -> [Session.ID: CGRect] {
        var frames: [Session.ID: CGRect] = [:]
        for group in groups {
            // A session belongs to at most one group, so no key can collide.
            frames.merge(group.layout(in: rect).frames) { current, _ in current }
        }
        return frames
    }

    private func accumulateLayout(in rect: CGRect, dividerThickness: CGFloat,
                                  into result: inout PaneLayout) {
        switch self {
        case .leaf(let id):
            result.frames[id] = rect
        case .split(let branch):
            let horizontal = branch.direction == .horizontal
            let span = horizontal ? rect.width : rect.height
            let usable = max(0, span - dividerThickness)
            let firstSpan = usable * CGFloat(branch.ratio)
            let secondSpan = usable - firstSpan

            let firstRect: CGRect
            let dividerRect: CGRect
            let secondRect: CGRect
            if horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstSpan, height: rect.height)
                dividerRect = CGRect(x: rect.minX + firstSpan, y: rect.minY,
                                     width: dividerThickness, height: rect.height)
                secondRect = CGRect(x: dividerRect.maxX, y: rect.minY,
                                    width: secondSpan, height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstSpan)
                dividerRect = CGRect(x: rect.minX, y: rect.minY + firstSpan,
                                     width: rect.width, height: dividerThickness)
                secondRect = CGRect(x: rect.minX, y: dividerRect.maxY,
                                    width: rect.width, height: secondSpan)
            }
            if dividerThickness > 0 {
                result.dividers.append(DividerSpec(id: branch.id, direction: branch.direction,
                                                   frame: dividerRect, span: span, ratio: branch.ratio))
            }
            branch.first.accumulateLayout(in: firstRect, dividerThickness: dividerThickness, into: &result)
            branch.second.accumulateLayout(in: secondRect, dividerThickness: dividerThickness, into: &result)
        }
    }

    // MARK: - Directional focus

    /// The best pane to move focus to from `focused` in `direction`, judged on
    /// normalized frames (muxy's scoring: candidates strictly on that side,
    /// preferring cross-axis overlap, then the smallest gap, then the nearest
    /// center). `nil` when there is nothing that way.
    func pane(_ direction: PaneFocusDirection, of focused: Session.ID) -> Session.ID? {
        let frames = layout(in: CGRect(x: 0, y: 0, width: 1, height: 1), dividerThickness: 0).frames
        guard let from = frames[focused] else { return nil }

        var best: (id: Session.ID, score: (Int, CGFloat, CGFloat))?
        for (id, frame) in frames where id != focused {
            guard isCandidate(frame, from: from, direction: direction) else { continue }
            let score = score(frame, from: from, direction: direction)
            if best == nil || score < best!.score { best = (id, score) }
        }
        return best?.id
    }

    private func isCandidate(_ candidate: CGRect, from: CGRect,
                             direction: PaneFocusDirection) -> Bool {
        let epsilon: CGFloat = 0.001
        switch direction {
        case .left: return candidate.maxX <= from.minX + epsilon
        case .right: return candidate.minX >= from.maxX - epsilon
        case .up: return candidate.maxY <= from.minY + epsilon
        case .down: return candidate.minY >= from.maxY - epsilon
        }
    }

    private func score(_ candidate: CGRect, from: CGRect,
                       direction: PaneFocusDirection) -> (Int, CGFloat, CGFloat) {
        let horizontal = direction == .left || direction == .right
        let overlap = horizontal
            ? min(candidate.maxY, from.maxY) - max(candidate.minY, from.minY)
            : min(candidate.maxX, from.maxX) - max(candidate.minX, from.minX)
        let gap: CGFloat
        switch direction {
        case .left: gap = from.minX - candidate.maxX
        case .right: gap = candidate.minX - from.maxX
        case .up: gap = from.minY - candidate.maxY
        case .down: gap = candidate.minY - from.maxY
        }
        let centerDistance = hypot(candidate.midX - from.midX, candidate.midY - from.midY)
        return (overlap > 0 ? 0 : 1, max(0, gap), centerDistance)
    }
}
