import AppKit
import SwiftUI

/// The uncommitted-files badge on the toolbar's branch name. Expanded, a capsule that
/// says what kind of change is waiting — `+new −removed ~edited`; collapsed, a circle
/// with the total. Clicking switches between the two, and the choice is remembered
/// across launches. Hovering the capsule turns it into a `−`, the collapse it offers;
/// the pointer becomes an inward or outward resize arrow to say which way a click goes.
///
/// Absent on a clean tree — no badge is the "nothing to commit".
struct GitBranchBadge: View {
    let status: GitSyncStatus

    @AppStorage("git.branchBadgeExpanded") private var isExpanded = true
    @State private var isHovered = false

    @Environment(\.controlActiveState) private var controlActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 13

    var body: some View {
        Button {
            withAnimation(morph) { isExpanded.toggle() }
        } label: {
            content
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, horizontalPadding)
                // One shape for both forms: a capsule as tall as it is wide is the circle,
                // so collapsing is the capsule's width settling, not one shape swapped for
                // another.
                .frame(minWidth: Self.height, minHeight: Self.height, maxHeight: Self.height)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.24 : 0.16))
                }
                .contentShape(.capsule)
        }
        .buttonStyle(BadgePressStyle())
        .fixedSize()
        .onContinuousHover { phase in
            let hovering: Bool
            if case .active = phase { hovering = true } else { hovering = false }
            guard hovering != isHovered else { return }
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .gitPointer(isExpanded ? .collapse : .expand)
        // Counts that move while an agent works roll rather than jump.
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: status.changedFiles)
        .help(isExpanded ? localized("Show the total only") : localized("Show new, removed, and edited files"))
        .accessibilityLabel(localized("\(status.changedFiles) uncommitted files"))
        .accessibilityHint(isExpanded ? localized("Shows the total only") : localized("Shows new, removed, and edited files"))
    }

    /// A spring, so a second click mid-morph turns it around from where it is rather than
    /// restarting it. Without motion, the forms simply cross-fade.
    private var morph: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0)
    }

    private var horizontalPadding: CGFloat {
        if isExpanded { return 5 }
        return status.changedFiles > 9 ? 3.5 : 0
    }

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            // The breakdown stays laid out under the `−`, so hovering changes what the
            // capsule says and never how wide it is.
            ZStack {
                breakdown
                    .opacity(isHovered ? 0 : 1)
                    .blur(radius: isHovered && !reduceMotion ? 2 : 0)
                Image(systemName: "minus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ink)
                    .opacity(isHovered ? 1 : 0)
                    .blur(radius: !isHovered && !reduceMotion ? 2 : 0)
            }
            .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        } else {
            Text(Self.count(status.changedFiles))
                .foregroundStyle(ink)
                .contentTransition(.numericText(value: Double(status.changedFiles)))
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        }
    }

    private var breakdown: some View {
        HStack(spacing: 3) {
            if status.addedFiles > 0 {
                segment("+", status.addedFiles, controlActive == .inactive ? ink : Palette.green)
            }
            if status.deletedFiles > 0 {
                segment("−", status.deletedFiles, controlActive == .inactive ? ink : Palette.red)
            }
            if status.modifiedFiles > 0 {
                segment("~", status.modifiedFiles, ink.opacity(0.85))
            }
        }
    }

    private func segment(_ sign: String, _ value: Int, _ color: Color) -> some View {
        Text(sign + Self.count(value))
            .foregroundStyle(color)
            .contentTransition(.numericText(value: Double(value)))
    }

    private var ink: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
    }

    private static func count(_ value: Int) -> String {
        value > 99 ? "99+" : String(value)
    }
}

/// Beside the branch name while its upstream has commits the branch lacks: a capsule
/// with the count that pulls them in, the uncommitted badge's shape and size so the two
/// read as one family. Absent when there is nothing to pull.
private struct GitPullButton: View {
    @ObservedObject var model: GitSyncModel
    let status: GitSyncStatus

    @State private var isHovered = false
    @Environment(\.controlActiveState) private var controlActive

    var body: some View {
        Button {
            model.pull()
        } label: {
            HStack(spacing: 2) {
                if model.isPulling {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 7.5, weight: .bold))
                }
                Text(status.behind > 99 ? "99+" : String(status.behind))
                    .contentTransition(.numericText(value: Double(status.behind)))
            }
            .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minHeight: 13, maxHeight: 13)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.24 : 0.16))
            }
            .contentShape(.capsule)
        }
        .buttonStyle(BadgePressStyle())
        .fixedSize()
        .disabled(model.isPulling)
        .onContinuousHover { phase in
            let hovering: Bool
            if case .active = phase { hovering = true } else { hovering = false }
            guard hovering != isHovered else { return }
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .gitPointer(.link)
        .help(localized("Pull \(status.behind) commits from \(status.upstream ?? "")"))
        .accessibilityLabel(localized("Pull \(status.behind) commits from \(status.upstream ?? "")"))
    }
}

/// A press the badge acknowledges at once, before the morph it starts has moved.
private struct BadgePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The pointer over the branch name and its badge: a link hand over the name, and over
/// the badge a resize arrow pointing the way a click would take it.
enum GitPointer {
    case link, expand, collapse

    fileprivate var cursor: NSCursor {
        switch self {
        case .link: return .pointingHand
        case .expand: return .resizeRight
        case .collapse: return .resizeLeft
        }
    }

    @available(macOS 15, *)
    fileprivate var style: PointerStyle {
        switch self {
        case .link: return .link
        case .expand: return .frameResize(position: .trailing, directions: .outward)
        case .collapse: return .frameResize(position: .trailing, directions: .inward)
        }
    }
}

extension View {
    /// SwiftUI's pointer styles where the system has them; before macOS 15, the matching
    /// `NSCursor`, set on every move so the toolbar's own cursor rects cannot win.
    @ViewBuilder
    func gitPointer(_ pointer: GitPointer) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(pointer.style)
        } else {
            onContinuousHover { phase in
                if case .active = phase { pointer.cursor.set() } else { NSCursor.arrow.set() }
            }
        }
    }
}

extension GitSyncStatus {
    /// Of the uncommitted files, the ones neither new nor removed: edits, renames,
    /// conflicts.
    var modifiedFiles: Int { max(0, changedFiles - addedFiles - deletedFiles) }

    /// The branch name's tooltip: what the badge counts, in words.
    var uncommittedSummary: String {
        guard changedFiles > 0 else { return localized("Nothing to commit") }
        var parts: [String] = []
        if modifiedFiles > 0 { parts.append(localized("\(modifiedFiles) edited")) }
        if addedFiles > 0 { parts.append(localized("\(addedFiles) new")) }
        if deletedFiles > 0 { parts.append(localized("\(deletedFiles) removed")) }
        return localized("Uncommitted: \(parts.joined(separator: ", "))")
    }
}

extension FyoloStore {
    /// Opens the inspector on the git pane's Inspect tab, at `section`.
    func showGitInspect(_ section: GitInspectSection) {
        gitSync.requestInspect(section)
        inspectorTab = .changes
        if !inspectorVisible {
            NSApp.sendAction(#selector(AppDelegate.toggleFilesInspector(_:)), to: nil, from: nil)
        }
    }
}

/// The toolbar's branch name. With the git status tracked it is also the way into the
/// git pane's Inspect tab — underlined on hover like a link, with the link pointer — and
/// carries the uncommitted badge beside it. Without it (the setting off, a
/// checkout on another machine) it is plain text.
struct GitBranchLabel: View {
    @EnvironmentObject var store: FyoloStore
    @ObservedObject var model: GitSyncModel
    let branch: String
    let color: Color

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let status = model.status {
            HStack(alignment: .center, spacing: 4) {
                Button {
                    store.showGitInspect(.uncommitted)
                } label: {
                    name.underline(isHovered).contentShape(.rect)
                }
                .buttonStyle(.plain)
                // Continuous rather than `onHover`: in a toolbar item, `onHover` reported the
                // pointer inside while the item was still being laid out at launch, and with
                // no exit to follow, the name stayed underlined under a pointer nowhere near it.
                .onContinuousHover { phase in
                    if case .active = phase { isHovered = true } else { isHovered = false }
                }
                .gitPointer(.link)
                .help(localized("\(branch) · \(status.uncommittedSummary). Click to inspect."))
                if status.changedFiles > 0 {
                    GitBranchBadge(status: status)
                        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                }
                if status.upstream != nil, status.behind > 0 {
                    GitPullButton(model: model, status: status)
                        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0),
                       value: status.changedFiles > 0)
            .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0),
                       value: status.behind > 0)
        } else {
            name.help(branch)
        }
    }

    private var name: Text {
        Text(branch)
            .font(.subheadline)
            .foregroundStyle(color)
    }
}
