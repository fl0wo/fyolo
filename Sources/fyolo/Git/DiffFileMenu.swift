import AppKit
import SwiftUI
import FyoloShared

/// The file menu and arrow keys navigate the same set of textual diffs.
enum DiffFileMenu {
    @MainActor
    static func rows(of request: GitDiffRequest, target: AnyObject, action: Selector) -> [NSMenuItem] {
        request.walkableSiblings.map { change in
            let item = NSMenuItem(title: change.name, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = change.path
            item.state = change.path == request.change.path ? .on : .off
            item.attributedTitle = title(of: change)
            return item
        }
    }

    /// NSMenuItem supports the status and count colors used by the Changes list.
    @MainActor
    private static func title(of change: GitChange) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: change.status.letter + "  ",
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor(change.status.tint),
            ])
        title.append(NSAttributedString(
            string: change.name,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]))
        if !change.directory.isEmpty {
            title.append(NSAttributedString(
                string: "  " + change.directory,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        }
        let counts: [(count: Int, sign: String, tint: NSColor)] = [
            (change.additions, "+", .systemGreen),
            (change.deletions, "−", .systemRed),
        ]
        for count in counts where count.count > 0 {
            title.append(NSAttributedString(
                string: "  \(count.sign)\(count.count)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                            weight: .medium),
                    .foregroundColor: count.tint,
                ]))
        }
        return title
    }
}

/// The AppKit overlay owns hover, help, and accessibility because it receives the pointer events.
struct DiffFileMenuLabel<Content: View>: View {
    let request: GitDiffRequest
    let onSelect: (GitChange) -> Void
    let content: () -> Content

    @State private var isHighlighted = false

    /// The leading inset is canceled to preserve the plain label's alignment.
    private static var chipInset: CGFloat { 6 }

    init(request: GitDiffRequest,
         onSelect: @escaping (GitChange) -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.request = request
        self.onSelect = onSelect
        self.content = content
    }

    var body: some View {
        HStack(spacing: 5) {
            content()
                .lineLimit(1)
                .truncationMode(.tail)
            HugeIconView(icon: .chevronRight, size: 7.5, color: .secondary, lineWidthOverride: 1.75)
                .rotationEffect(.degrees(90))
        }
        .padding(.horizontal, Self.chipInset)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHighlighted ? 0.08 : 0))
                .animation(nil, value: isHighlighted))
        .padding(.leading, -Self.chipInset)
        .overlay(DiffFileMenuPopper(request: request, onSelect: onSelect,
                                    highlighted: $isHighlighted))
        .accessibilityHidden(true)
    }
}

private struct DiffFileMenuPopper: NSViewRepresentable {
    let request: GitDiffRequest
    let onSelect: (GitChange) -> Void
    @Binding var highlighted: Bool

    func makeNSView(context: Context) -> DiffFileMenuHost {
        let view = DiffFileMenuHost()
        view.request = request
        view.onSelect = onSelect
        view.onHighlight = { highlighted = $0 }
        view.toolTip = localized("Show another file in this diff")
        return view
    }

    func updateNSView(_ nsView: DiffFileMenuHost, context: Context) {
        nsView.request = request
        // Capture the current binding after SwiftUI replaces the view tree.
        nsView.onSelect = onSelect
        nsView.onHighlight = { highlighted = $0 }
    }
}

private final class DiffFileMenuHost: NSView {
    var request: GitDiffRequest?
    var onSelect: ((GitChange) -> Void)?
    var onHighlight: ((Bool) -> Void)?

    private var hoverTracking: NSTrackingArea?

    /// Keeps the menu anchor below the label.
    override var isFlipped: Bool { true }

    /// A click in a background window opens the menu rather than only raising the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHighlight?(true) }

    override func mouseExited(with event: NSEvent) { onHighlight?(false) }

    /// Menu tracking suppresses exit events, so query the pointer again when it closes.
    private var isUnderPointer: Bool {
        guard let location = window?.mouseLocationOutsideOfEventStream else { return false }
        return bounds.contains(convert(location, from: nil))
    }


    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }

    override func accessibilityLabel() -> String? { localized("File") }

    override func accessibilityValue() -> Any? { request?.name }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    private func showMenu() {
        guard let request else { return }
        let menu = NSMenu()
        for row in DiffFileMenu.rows(of: request, target: self, action: #selector(selectFile(_:))) {
            menu.addItem(row)
        }
        // popUp runs a nested event loop; settle hover after it returns.
        onHighlight?(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        onHighlight?(isUnderPointer)
    }

    @objc private func selectFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let change = request?.siblings.first(where: { $0.path == path })
        else { return }
        onSelect?(change)
    }
}
