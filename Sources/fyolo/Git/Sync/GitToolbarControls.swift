import AppKit
import SwiftUI

/// The toolbar's git glyphs, right of the project name: **±** with the count of
/// uncommitted files, and a **cloud** that says which way the branch would sync. Either
/// opens the git pane's Inspect tab at its section; the up-to-date cloud checks the
/// remote instead. Read-only — the commit, push, or pull itself stays in the terminal.
///
/// Both sit in one capsule drawn like the pinned workflow chip's (`ToolbarCapsuleChrome`),
/// so the toolbar's chips read as one family. Each glyph is fixed-width, because a control that measured its own count would hand
/// NSToolbar a new intrinsic width on every edit an agent makes, and the toolbar
/// answers by re-laying out the whole band (see `WorkspaceSwitcherToolbarView`).
struct GitToolbarControls: View {
    @EnvironmentObject var store: FyoloStore
    @ObservedObject var model: GitSyncModel

    @Environment(\.controlActiveState) private var controlActive

    private static let height = InspectorTabsToolbar.controlHeight
    private static let changesWidth: CGFloat = 32
    private static let cloudWidth: CGFloat = 22
    private static let spacing: CGFloat = 4
    private static let inset: CGFloat = 10
    /// What the capsule takes from the title's toolbar item at most, the gap to the title included.
    static let reservedWidth: CGFloat = changesWidth + spacing + cloudWidth + inset * 2 + 7

    var body: some View {
        if let status = model.status {
            HStack(spacing: Self.spacing) {
                changes(status)
                if let sync = status.sync { cloud(sync, status: status) }
            }
            .padding(.horizontal, Self.inset)
            .frame(height: Self.height)
            .background { ToolbarCapsuleChrome() }
            .fixedSize()
        }
    }

    // MARK: Changes

    private func changes(_ status: GitSyncStatus) -> some View {
        let count = status.changedFiles
        return Button {
            inspect(.uncommitted)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Image(systemName: "plusminus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(count > 0 ? ink : secondaryInk)
                if count > 0 {
                    Text(count > 99 ? "99+" : String(count))
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(secondaryInk)
                }
            }
            .frame(width: Self.changesWidth, height: Self.height, alignment: .center)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(changesHelp(status))
        .accessibilityLabel(localized("Inspect changes"))
        .accessibilityValue(changesHelp(status))
    }

    private func changesHelp(_ status: GitSyncStatus) -> String {
        let total = status.changedFiles
        guard total > 0 else { return localized("Nothing to commit") }
        let edited = total - status.addedFiles - status.deletedFiles
        var parts: [String] = []
        if edited > 0 { parts.append(localized("\(edited) edited")) }
        if status.addedFiles > 0 { parts.append(localized("\(status.addedFiles) new")) }
        if status.deletedFiles > 0 { parts.append(localized("\(status.deletedFiles) removed")) }
        return localized("Uncommitted: \(parts.joined(separator: ", "))")
    }

    // MARK: Cloud

    private func cloud(_ sync: GitSyncStatus.Sync, status: GitSyncStatus) -> some View {
        let upstream = status.upstream ?? ""
        let symbol: String
        let help: String
        let action: () -> Void
        switch sync {
        case .upToDate:
            symbol = "checkmark.icloud"
            help = model.isFetching
                ? localized("Checking \(upstream) for new commits…")
                : localized("Up to date with \(upstream). Click to check for new commits.")
            action = { model.fetch() }
        case .pull(let behind):
            symbol = "icloud.and.arrow.down"
            help = localized("\(behind) commits to pull from \(upstream)")
            action = { inspect(.incoming) }
        case .push(let ahead):
            symbol = "icloud.and.arrow.up"
            help = localized("\(ahead) commits to push to \(upstream)")
            action = { inspect(.outgoing) }
        case .diverged(let behind, let ahead):
            // No cloud carries both arrows; this is the system's own "sync both ways".
            symbol = "arrow.triangle.2.circlepath.icloud"
            help = localized("\(behind) to pull and \(ahead) to push with \(upstream)")
            action = { inspect(.incoming) }
        case .publish(let remote):
            symbol = "icloud.and.arrow.up"
            help = localized("This branch is not on \(remote) yet")
            action = { inspect(.outgoing) }
        }
        let quiet = sync == .upToDate
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(quiet ? secondaryInk : ink)
                .symbolEffect(.pulse, isActive: model.isFetching)
                .frame(width: Self.cloudWidth, height: Self.height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(quiet && model.isFetching)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Shared

    private var ink: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
    }

    private var secondaryInk: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .secondary
    }

    /// Opens the inspector on the git pane's Inspect tab, at `section`.
    private func inspect(_ section: GitInspectSection) {
        model.requestInspect(section)
        store.inspectorTab = .changes
        if !store.inspectorVisible {
            NSApp.sendAction(#selector(AppDelegate.toggleFilesInspector(_:)), to: nil, from: nil)
        }
    }
}
