import AppKit
import SwiftUI
import FyoloShared

/// The workspace rows, in the order every surface shows them: one item per
/// workspace, the one on screen checked, the first nine carrying ⌘1…9.
///
/// One builder for both menus that draw them — the sidebar switcher and File ▸
/// Workspace — because the digit is positional. Two menus numbering their own
/// rows could disagree about which workspace ⌘2 reaches, and a number that lies
/// is worse than no number at all.
enum WorkspaceMenu {
    /// `representedObject` carries the workspace's uuid string, which is what
    /// `action` reads back — the one thing both callers' handlers share.
    ///
    /// The key equivalents are live only in the menu bar's copy: AppKit matches a
    /// keystroke against the main menu, so the same items in a pull-down draw the
    /// glyphs without claiming ⌘1…9 a second time.
    @MainActor
    static func rows(in store: FyoloStore, target: AnyObject, action: Selector) -> [NSMenuItem] {
        let shortcuts = KeybindingStore.workspaceShortcuts
        return store.orderedWorkspaces.enumerated().map { index, workspace in
            let item = NSMenuItem(title: workspace.name, action: action, keyEquivalent: "")
            if index < shortcuts.count {
                item.keyEquivalent = shortcuts[index].keyEquivalent
                item.keyEquivalentModifierMask = shortcuts[index].keyEquivalentModifierMask
            }
            item.target = target
            item.representedObject = workspace.id.uuidString
            item.state = workspace.id == store.currentWorkspaceID ? .on : .off
            // Which machine, in words, and only when the name does not already
            // say it — an auto-created workspace *is* named after its alias.
            // In words rather than as a mark: a machine's name is the thing a
            // person types, and the row has the room for it.
            if let alias = workspace.deviceAlias,
               !workspace.name.localizedCaseInsensitiveContains(alias) {
                item.attributedTitle = titled(workspace.name, on: alias)
            }
            return item
        }
    }

    /// The row's title with the machine trailing it in the secondary colour, so
    /// the name still reads as the name.
    @MainActor
    private static func titled(_ name: String, on alias: String) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: name,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        title.append(NSAttributedString(
            string: "  " + alias,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        return title
    }
}

/// The workspace switcher, in the sidebar's own toolbar region: which scope you
/// are in, and the control that changes it. It sits in the strip above the list
/// rather than in a row of its own, next to the navigator toggle and the
/// sidebar's other actions — the band belongs to the column below it, and a first
/// row that is not a session is a row the tree has to explain.
///
/// Quiet by design — it names the workspace and nothing else — and absent
/// entirely while there is only one, so a user who never makes a second never
/// sees it.
struct WorkspaceSwitcherToolbarView: View {
    @EnvironmentObject var store: FyoloStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.controlActiveState) private var controlActive

    /// Whether the pointer is over the name, or its menu is open. Reported by the
    /// AppKit overlay below, which is the view the pointer actually lands on.
    @State private var isHighlighted = false

    /// One fixed box, wide enough for an ordinary name and narrow enough to leave the
    /// sort and `+` buttons clear of NSToolbar's `»` overflow at the navigator's 240pt
    /// minimum (the toggle, this box and those two buttons come to roughly 220).
    ///
    /// Fixed, not sized to the string. A label that measures its own text hands the
    /// toolbar item a new intrinsic width on every switch, and NSToolbar answers by
    /// re-laying out the region — which is what was seen as the name flicking and
    /// shifting as the scope changed. That relayout belongs to AppKit, below SwiftUI,
    /// so the deliberately un-animated transaction in `switchToWorkspace` cannot reach
    /// it. Holding the width constant means there is nothing to re-lay out: no name,
    /// of any length, can put the toolbar back into motion.
    ///
    /// A floor would have hidden this for short names and let it back for long ones.
    /// Measuring the widest name and sizing to that keeps the box honest but needs
    /// text metrics, a font bridge and a re-measure on every rename — machinery in
    /// exchange for slack the flexible space beside it already absorbs.
    ///
    /// Ten points of it are the hover chip's inset now (`chipInset` below), so the
    /// item as a whole is exactly as wide as it was and the `»` budget is untouched.
    private static let nameWidth: CGFloat = 94

    /// What the hover chip puts around the name. Real padding, not a background
    /// drawn outside the label's bounds: the toolbar item is only as large as this
    /// view asks to be, so anything painted past that edge is at the mercy of the
    /// hosting view's clip — and a chip clipped on one side looks like a bug rather
    /// than a control.
    ///
    /// The leading half is given back as negative padding on the whole box (see
    /// `body`), so the name still starts at the x the toggle beside it was spaced
    /// for. Only the trailing half is new width, and it comes out of `nameWidth`.
    private static let chipInset: CGFloat = 5

    var body: some View {
        // The single-workspace collapse. Not "hidden but present": with one scope
        // there is no switch to make, and a control that always reads the same
        // word is a label for a decision the user never took.
        if store.hasMultipleWorkspaces {
            let current = store.currentWorkspace
            // The name and nothing else. No device mark — the rows below already say
            // which machine they are on — and no menu chevron: the toolbar band is
            // three glyphs wide, and every point this control spends on decoration is
            // a point the name truncates at.
            Text(current.name)
                // The very font the sidebar's rows and section headers use — not a copy of its
                // definition, which is what this was and what let the two drift on paper. The band
                // and the column below it share an x-height and read as one thing: this names that
                // column, and a size step would separate it from what it names. Rank comes from
                // weight instead — a label larger than the window title beside it is what makes a
                // titlebar look mis-scaled.
                .font(settings.interfaceFont)
                .fontWeight(.medium)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                // Leading, so every name starts at the same x. Centred, a short one would
                // sit in the middle of the box and the label's left edge would move on each
                // switch — the same shift by a different route.
                .frame(width: Self.nameWidth, alignment: .leading)
                .padding(.horizontal, Self.chipInset)
                .padding(.vertical, 3)
                .background(highlight)
                // The inset given back, so the name keeps the x it had before there
                // was a chip: the toggle's 6pt of spacing now holds 5pt of chip and
                // 1pt of gap, and the two controls still read as one band.
                .padding(.leading, -Self.chipInset)
                // The overlay owns the press, the hover, the tooltip, and the
                // accessibility of this control — it is the view under the pointer, so a
                // `.help()` here would be shadowed by it and a SwiftUI accessibility
                // element here would hide it. See `WorkspaceMenuHost`.
                .overlay(WorkspaceMenuPopper(store: store, highlighted: $isHighlighted))
                .accessibilityHidden(true)
        }
    }

    // Matched to the sidebar toolbar's native glyphs (the `+` new-terminal item, the
    // sort pull-down): those are bordered `NSToolbarItem`s, which tint their template
    // symbol at full-strength `labelColor`, so the name sits at `.primary` to read as
    // one control band with them rather than a dimmer `.secondary` label.
    private var color: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
    }

    /// The chip under the name while the pointer is on it — the one thing that says
    /// this word is a control. Without it the switcher was a label, and it was read
    /// as one: people ran a whole session without finding out the workspace could be
    /// changed from here.
    ///
    /// Present at every size, not conditional: it is the fill that changes, so the
    /// box never resizes on hover and no name can be re-truncated by the pointer
    /// arriving.
    ///
    /// A neutral fill of the foreground, the same rounded lift the sidebar's own hover
    /// controls use, not an accent wash — this is a pointer cue, not a selection.
    private var highlight: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(isHighlighted ? 0.10 : 0))
            // Hover cues snap: they paint on the next frame and clear on the next
            // frame. A fade here would still be arriving after the pointer had moved
            // on, which is what reads as lag.
            .animation(nil, value: isHighlighted)
    }
}

/// Opens the switcher's menu on click, over the label above it.
///
/// AppKit rather than SwiftUI's `Menu` because only `NSMenuItem` draws both halves
/// a row needs at once: a checkmark in the state column for the workspace on
/// screen, and the ⌘-digit that reaches it, right-aligned in the column macOS puts
/// shortcuts in. SwiftUI offers one or the other — an inline `Picker` checkmarks,
/// a `Button` takes `.keyboardShortcut` — and `.keyboardShortcut` would also
/// *claim* ⌘1…9 for as long as this view is mounted, a second live binding racing
/// File ▸ Workspace for the same keystroke.
private struct WorkspaceMenuPopper: NSViewRepresentable {
    let store: FyoloStore
    /// Driven by the host below: the pointer entering or leaving, and the menu
    /// being up. Hover is answered here rather than by a SwiftUI `.onHover` on the
    /// label, for the same reason the tooltip is — this view is the one the pointer
    /// hits, so the label underneath never learns the pointer arrived.
    @Binding var highlighted: Bool

    /// The name as well as the sentence, because the label above draws in a fixed box and
    /// a name too long for it is middle-truncated with nowhere else to be read in place.
    private static func toolTip(for store: FyoloStore) -> String {
        "\(store.currentWorkspace.name) — \(localized("The sidebar shows this workspace"))"
    }

    func makeNSView(context: Context) -> WorkspaceMenuHost {
        let view = WorkspaceMenuHost()
        view.store = store
        view.onHighlight = { highlighted = $0 }
        view.toolTip = Self.toolTip(for: store)
        return view
    }

    func updateNSView(_ nsView: WorkspaceMenuHost, context: Context) {
        nsView.store = store
        // Rebound every update: the closure captures this struct's binding, and a
        // stale one writes to a view tree that has been replaced.
        nsView.onHighlight = { highlighted = $0 }
        // Set here too: the scope changes far more often than this view is made.
        nsView.toolTip = Self.toolTip(for: store)
    }
}

/// The click target, and the target of the menu it pops. One class rather than a
/// view plus a coordinator: the menu is built when it opens, out of the store this
/// view already holds, so there is no second place for its contents to live.
private final class WorkspaceMenuHost: NSView {
    weak var store: FyoloStore?

    /// Reports the pointer cue back to the view drawing it. See `highlight`.
    var onHighlight: ((Bool) -> Void)?

    private var hoverTracking: NSTrackingArea?

    /// Flipped so the anchor below reads in the direction the menu opens, rather
    /// than depending on whichever convention the hosting view happens to use.
    override var isFlipped: Bool { true }

    /// A click in a background window opens the menu rather than only raising the
    /// window — the switcher is often the reason the window is being reached for.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    // MARK: - Hover
    //
    // Only while the app is active: hovering a background window highlights
    // nothing on macOS, and the name is drawn in the disabled colour there anyway.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHighlight?(true) }

    override func mouseExited(with event: NSEvent) { onHighlight?(false) }

    /// Whether the pointer is over this view right now, asked rather than
    /// remembered — the tracking area is silent while a menu holds the event loop,
    /// so this is how the cue is settled once the menu has gone.
    private var isUnderPointer: Bool {
        guard let location = window?.mouseLocationOutsideOfEventStream else { return false }
        return bounds.contains(convert(location, from: nil))
    }

    // MARK: - Accessibility
    //
    // The element is this view rather than the `Text` beneath it. A SwiftUI
    // `.accessibilityAddTraits(.isButton)` only sets a trait — nothing there answers
    // a press — so the control announced itself as a button and then did nothing,
    // which the `Menu` it replaced did not do. Answering here gives the press a real
    // implementation and one description that cannot disagree with the label drawn.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? { localized("Workspace") }
    override func accessibilityValue() -> Any? { store?.currentWorkspace.name }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    private func showMenu() {
        guard let store else { return }
        let menu = NSMenu()
        for row in WorkspaceMenu.rows(in: store, target: self, action: #selector(switchToWorkspace(_:))) {
            menu.addItem(row)
        }
        // This Mac, without asking: the device submenu belongs to the menus that
        // already carry one (File ▸ Workspace and the sidebar `+`), and growing a
        // third here would put a machine list in the switcher, which is the "go to
        // a computer" mode the workspace replaced.
        addAction(localized("New Workspace…"), to: menu, #selector(newWorkspace))
        menu.addItem(.separator())
        // Renaming and removing are in Settings ▸ Workspaces. Creating stays here
        // because it is the one verb that does not need the user to pick which
        // workspace it acts on — the other two do, and this menu can only ever
        // offer them for the row it already shows checked.
        addAction(localized("Workspace Settings…"), to: menu, #selector(openWorkspaceSettings))
        // No device verb here, deliberately. A machine you can *go to* is the
        // mode this scope replaced: it made the sidebar answer "which computer"
        // when the question is "which work". A device is a place a new thing is
        // put — New Terminal on it, Clone to it, File ▸ Connect to… for a box
        // never reached — never a place the window travels to.

        // Held highlighted for as long as the menu is up, the way a pull-down stays
        // pressed under its own menu. `popUp` runs a nested event loop and returns
        // once the menu closes, so the cue is settled on the line after it — from
        // where the pointer actually is, since no exit was delivered while the menu
        // had the loop.
        onHighlight?(true)
        // Anchored under the label the way a pull-down opens, rather than at the
        // pointer the way a context menu does.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        onHighlight?(isUnderPointer)
    }

    private func addAction(_ title: String, to menu: NSMenu, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func switchToWorkspace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        store?.switchToWorkspace(id)
    }

    @objc private func newWorkspace() {
        store?.presentNewWorkspacePanel(on: .thisMac)
    }

    @objc private func openWorkspaceSettings() {
        NSApp.sendAction(#selector(AppDelegate.openWorkspaceSettings(_:)), to: nil, from: nil)
    }
}
