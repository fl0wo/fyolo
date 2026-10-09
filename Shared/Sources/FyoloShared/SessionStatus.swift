import SwiftUI

/// A session's live activity. The four states follow the desktop model
/// (see the main app's `Models.swift`): a finished turn is `done`, *not*
/// "needs you" — `needsAttention` is reserved for an agent actually blocked
/// on the user, keeping "ready for you" (calm) distinct from "waiting on
/// you" (urgent).
public enum SessionStatus: Hashable, Sendable {
    /// Nothing pending, or the user is already looking at the session.
    case idle
    /// The agent is actively processing a turn (shown as the spinning icon).
    case working
    /// The agent finished its turn while the user was elsewhere — a calm
    /// "ready for you" cue, not a demand.
    case done
    /// The agent is blocked waiting on the user (permission prompt, or a
    /// bell / desktop notification it raised).
    case needsAttention

    /// Sort rank for mobile lists: attention first, then working.
    public var rank: Int {
        switch self {
        case .needsAttention: 0
        case .working: 1
        case .idle: 2
        case .done: 3
        }
    }
}

/// A small coloured dot trailing a session title: hidden when idle/working
/// (working is shown by the leading spinner instead), green when done,
/// orange when the session needs the user.
public struct StatusDot: View {
    let status: SessionStatus

    public init(status: SessionStatus) {
        self.status = status
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(status == .done || status == .needsAttention ? 1 : 0)
    }

    private var color: Color {
        status == .needsAttention ? .orange : .green
    }
}

/// The "agent is working" mark: a 3×3 grid of dots with a bright comet that
/// orbits the eight perimeter cells, so the small nine-square grid reads as
/// rotating. Sits in place of the session's brand icon while a turn is in
/// flight. The caller supplies the tint — the agent's brand color on iOS, and
/// monochrome ink in the Mac sidebar, where the vibrancy material would wash a
/// brand tint to grey.
public struct WorkingIndicator: View {
    let tint: Color

    /// When nil the comet self-animates via `TimelineView`; supplying a phase
    /// (0...1) renders one still frame instead, so a caller can drive the
    /// rotation with its own timer where `TimelineView` never ticks — e.g.
    /// inside an open `NSMenu`, which runs a modal event-tracking loop.
    let phase: Double?

    public init(tint: Color = .secondary, phase: Double? = nil) {
        self.tint = tint
        self.phase = phase
    }

    /// The eight perimeter cells of the 3×3 grid in clockwise order, as
    /// `(column, row)` with the center at `(1, 1)`. The comet travels this ring.
    private static let ring: [(Int, Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]
    // Dots this small read lighter than their nominal opacity, so the size and
    // the opacity ramp are tuned together: 2.5pt with a 0.5 tail floor sits at
    // the same perceived weight as the neighboring 15pt glyphs.
    private let dotSize: CGFloat = 2.5
    private let spacing: CGFloat = 3.6
    private let period: Double = 1.1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        if let phase {
            grid(phase: phase)
        } else if reduceMotion {
            // Reduce Motion: hold one frame — the mark still reads as "working"
            // from its shape, and the timeline (and its per-tick cost) is gone.
            grid(phase: 0)
        } else {
            // 30Hz, not every display frame: at 13pt with a 1.1s period the
            // comet is visually identical at 30Hz, and an uncapped timeline
            // ran this body at 120Hz per working row on ProMotion — enough to
            // saturate the main thread once a few sessions worked at once.
            //
            // `.periodic`, not `.animation`: the animation clock wraps every
            // tick in an animation transaction, and on macOS that makes the
            // hosting view re-negotiate its size each tick (FB13810482) — the
            // whole window's layout walked 30 times a second per working row.
            // A periodic tick just redraws this Canvas.
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
                let p = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                grid(phase: p)
            }
        }
    }

    /// Drawn, not built. Each tick used to hand `TimelineView` a fresh subtree —
    /// a `ZStack` over nine shaped `Circle`s, each carrying a frame, an offset, a
    /// scale and an opacity — and SwiftUI had to diff and lay all ten out again.
    /// A fixed outer frame stops the *size* escaping, but not the layout pass
    /// itself: the hosting view still had work scheduled, so one working row
    /// drove an `NSHostingView.layout()` of the whole sidebar column at 30 Hz
    /// (measured at 33-100 ms a turn — see
    /// docs/design/20260819-workspace-switch-latency.md).
    ///
    /// A `Canvas` is one leaf. Ticking it re-runs this closure and nothing else:
    /// no subtree to diff, no children to place, no invalidation to propagate.
    /// The geometry and both ramps below are unchanged, so the mark looks
    /// exactly as it did.
    private func grid(phase: Double) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let shading = GraphicsContext.Shading.color(tint)
            // A steady center anchors the spinning ring, matching the tail so
            // the grid reads as one solid mark with a swell running around it.
            draw(in: &context, at: center, opacity: 0.5, scale: 1, shading: shading)
            for (index, cell) in Self.ring.enumerated() {
                let distance = ringDistance(at: index, phase: phase)
                let point = CGPoint(
                    x: center.x + CGFloat(cell.0 - 1) * spacing,
                    y: center.y + CGFloat(cell.1 - 1) * spacing
                )
                draw(in: &context, at: point,
                     opacity: opacity(distance: distance),
                     scale: scale(distance: distance),
                     shading: shading)
            }
        }
        .frame(width: 13, height: 13)
    }

    /// One dot, centred on `point`. The swell is a radius, not a transform:
    /// inside a `Canvas` there is no layout for a size change to invalidate, so
    /// the reason the old code reached for `scaleEffect` is gone.
    private func draw(
        in context: inout GraphicsContext, at point: CGPoint,
        opacity: Double, scale: Double, shading: GraphicsContext.Shading
    ) {
        let radius = dotSize / 2 * scale
        let box = CGRect(x: point.x - radius, y: point.y - radius,
                         width: radius * 2, height: radius * 2)
        context.opacity = opacity
        context.fill(Path(ellipseIn: box), with: shading)
    }

    /// A perimeter cell's distance from the comet's head, measured the shorter
    /// way around the ring so the tail wraps.
    private func ringDistance(at index: Int, phase: Double) -> Double {
        let count = Double(Self.ring.count)
        let head = phase * count
        let raw = abs(Double(index) - head)
        return min(raw, count - raw)
    }

    /// The rotation is carried by two signals so neither has to be extreme: a
    /// brightness wave AND a size swell at the comet's head. Opacity alone
    /// needed a near-invisible tail to read as motion, which left the whole mark
    /// far paler than the full-ink glyphs beside it; with the swell doing half
    /// the work the tail floor stays at half ink and the grid keeps real weight.
    private func opacity(distance: Double) -> Double {
        max(0.5, 1 - distance / 4)
    }

    /// Size factor for a cell: the head swells a fifth and the swell dies out
    /// over the next two cells.
    private func scale(distance: Double) -> Double {
        1 + 0.2 * max(0, 1 - distance / 2)
    }
}
