import AppKit
import SwiftUI

/// The disclosure tree: a native `NSOutlineView` whose items are the model's own
/// `DeviceFileNode`s.
///
/// It used to be SwiftUI's `List(children:)`, which keeps its own copy of the
/// rows and hands the outline a folder's children only on an update pass — and
/// each pass re-walked every realized row of the tree. Opening a folder in code
/// therefore took a pass per level, so revealing a file seven folders deep in a
/// big checkout took seconds, and every graft from the device's `fs:` watch paid
/// for the whole tree. Here the outline asks the model directly: a folder's rows
/// are there the moment it expands, a reveal is one synchronous walk, and a
/// reload re-reads only the folders that are open.
///
/// The rows are still SwiftUI — the label and the sidebar's highlight, hosted in
/// AppKit cells — so the tree looks the same as every other list in the app.
///
/// One tree for every machine. The rows come from `DeviceFileTreeModel`, which
/// reads `fs.list` on whichever device the checkout lives on. What differs is
/// what may be *done* to it: drag, drop and the row menu move bytes through this
/// process, so a checkout on another device gets none of them.
struct FileTreeList: NSViewRepresentable {
    let model: DeviceFileTreeModel
    /// The model's revision, read here so a graft re-runs `updateNSView`.
    let revision: Int
    /// Collapse All: each bump closes every folder.
    let collapseGeneration: Int
    /// The decorations' revision, read here so a recolor re-runs `updateNSView`.
    let decorationRevision: Int
    @Binding var selection: String?
    let settings: AppSettings
    /// The write verbs, or `nil` for a checkout on another device.
    let writes: FileTreeWrites?
    /// A file was clicked, or reached with the arrow keys.
    let onOpen: (DeviceFileNode) -> Void
    let onQuickLook: () -> Void
    /// Hands the controller up to `FileBrowserView`, which reveals through it.
    let captureController: (FileOutlineController?) -> Void

    func makeCoordinator() -> FileOutlineController {
        FileOutlineController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        configure(controller)

        let outline = FileOutlineView()
        let column = NSTableColumn(identifier: FileOutlineController.columnIdentifier)
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // The column stays the pane's width. Left on, the outline widens it to
        // fit a deep folder's indentation, and the tree then scrolls sideways
        // with every name cut off at its left edge.
        outline.autoresizesOutlineColumn = false
        // The row view paints the selection, as the sidebar does.
        outline.selectionHighlightStyle = .none
        outline.backgroundColor = .clear
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 14
        outline.draggingDestinationFeedbackStyle = .none
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.every, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Names truncate in the middle instead; a sideways swipe has nothing to show.
        scroll.horizontalScrollElasticity = .none

        controller.attach(outline, collapseGeneration: collapseGeneration)
        captureController(controller)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let controller = context.coordinator
        configure(controller)
        controller.update(collapseGeneration: collapseGeneration, decorationRevision: decorationRevision)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: FileOutlineController) {
        coordinator.detach()
    }

    private func configure(_ controller: FileOutlineController) {
        controller.settings = settings
        controller.writes = writes
        controller.selection = $selection
        controller.onOpen = onOpen
        controller.onQuickLook = onQuickLook
    }
}

/// The outline's data source and delegate, answering from the model directly.
@MainActor
final class FileOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let columnIdentifier = NSUserInterfaceItemIdentifier("file")
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("file.cell")
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("file.row")

    let model: DeviceFileTreeModel
    private(set) weak var outline: NSOutlineView?
    /// `nil` in a test, where nothing is drawn.
    var settings: AppSettings?
    var writes: FileTreeWrites?
    var selection: Binding<String?> = .constant(nil)
    var onOpen: (DeviceFileNode) -> Void = { _ in }
    var onQuickLook: () -> Void = {}

    /// The model revision the outline last re-read.
    private var listedRevision: Int?
    /// The decorations' revision the visible rows were last drawn at.
    private var decoratedRevision: Int?
    /// Until when a folder opening or closing may still be animating. A full reload
    /// inside that window hands the row views sliding aside to other rows, and they
    /// glide into place from wherever they were — siblings visibly re-sorting from
    /// the bottom. A folder's listing now lands well inside the animation, so a
    /// reload that arrives then waits for it to finish.
    private var settlingUntil = ContinuousClock.now
    private var reloadPending = false
    /// AppKit's expand and collapse take a quarter second; this clears it.
    private static let settleDuration = Duration.milliseconds(300)
    private var collapseGeneration = 0
    /// Set while this side moves the outline's selection, so the delegate does
    /// not report it back as the user's.
    private var applyingSelection = false
    private var hoveredRow = -1
    /// The folder a drag would land in, when it is a row.
    private var dropTargetPath: String?
    /// Held while its menu is up: menu items keep their target weakly.
    private var menuOwner: FileRowMenu?

    init(model: DeviceFileTreeModel) {
        self.model = model
    }

    func attach(_ outline: NSOutlineView, collapseGeneration: Int) {
        self.outline = outline
        self.collapseGeneration = collapseGeneration
        (outline as? FileOutlineView)?.controller = self
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        applyRowHeight()
        reload()
        restoreExpansion()
        syncSelection()
    }

    func detach() {
        outline?.dataSource = nil
        outline?.delegate = nil
        outline = nil
    }

    func update(collapseGeneration: Int, decorationRevision: Int) {
        if collapseGeneration != self.collapseGeneration {
            self.collapseGeneration = collapseGeneration
            collapseAll()
        }
        applyRowHeight()
        if listedRevision != model.revision {
            reloadWhenSettled()
        } else {
            syncSelection()
            if decoratedRevision != decorationRevision { redecorateVisibleRows() }
        }
        decoratedRevision = decorationRevision
    }

    /// Redraws the rows on screen with their current decorations. A row scrolled into
    /// view later is drawn fresh, so only these can be showing an old color.
    private func redecorateVisibleRows() {
        guard let outline, let settings else { return }
        let visible = outline.rows(in: outline.visibleRect)
        for row in visible.lowerBound..<visible.upperBound {
            guard let node = outline.item(atRow: row) as? DeviceFileNode else { continue }
            let decoration = model.decorations.decoration(for: node)
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileOutlineCell)?
                .show(FileRowLabel(row: FileRowSnapshot(node, decoration: decoration), settings: settings))
            rowView(at: row)?.decoration = decoration
        }
    }

    /// `reload`, once no folder is mid-animation. The listings that land meanwhile —
    /// a spinner, the rows, the spinner gone — fold into the one reload after it.
    private func reloadWhenSettled() {
        guard ContinuousClock.now >= settlingUntil else {
            guard !reloadPending else { return }
            reloadPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(until: settlingUntil)
                reloadPending = false
                if listedRevision != model.revision { reloadWhenSettled() }
            }
            return
        }
        reload()
    }

    /// Re-reads the open folders. Expansion survives because the model reuses a
    /// node for a path that is still there, and the outline keys on the object.
    func reload() {
        guard let outline else { return }
        listedRevision = model.revision
        applyingSelection = true
        outline.reloadData()
        applyingSelection = false
        syncSelection()
    }

    /// Opens every folder on the way to `path`, selects it without opening it,
    /// and scrolls it into view — one synchronous walk, since each folder's rows
    /// are the model's the moment it expands. A path the tree does not have
    /// (inside a hidden folder, or deleted) lands on its deepest folder that is.
    @discardableResult
    func reveal(_ path: String) -> Bool {
        guard let outline else { return false }
        if listedRevision != model.revision { reload() }
        let chain = (model.folders(leadingTo: path) + [path])
            .lazy
            .map { self.model.node(at: $0) }
            .prefix { $0 != nil }
            .compactMap { $0 }
        guard let target = chain.last else { return false }
        for folder in chain.dropLast() where !outline.isItemExpanded(folder) {
            outline.expandItem(folder)
        }
        let row = outline.row(forItem: target)
        guard row >= 0 else { return false }
        applyingSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        applyingSelection = false
        selection.wrappedValue = target.path
        scrollIntoView(row)
        return true
    }

    /// Brings an off-screen row up near the top, two rows of its folder above
    /// it so it reads in place; a row already in view stays where it is.
    private func scrollIntoView(_ row: Int) {
        guard let outline else { return }
        outline.tile()
        let rowRect = outline.rect(ofRow: row)
        guard let scrollView = outline.enclosingScrollView else {
            outline.scrollRowToVisible(row)
            return
        }
        let clip = scrollView.contentView
        guard !clip.documentVisibleRect.contains(rowRect) else { return }
        let highest = max(0, outline.bounds.height - clip.bounds.height)
        let top = min(max(0, rowRect.minY - rowRect.height * 2), highest)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: top))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Puts the outline's selection where the binding says, when that row is
    /// on screen; a selection inside a closed folder simply shows no row.
    private func syncSelection() {
        guard let outline else { return }
        let row = selection.wrappedValue
            .flatMap { model.node(at: $0) }
            .map { outline.row(forItem: $0) } ?? -1
        guard row != outline.selectedRow else { return }
        applyingSelection = true
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        applyingSelection = false
    }

    private func collapseAll() {
        model.expandedPaths.removeAll()
        outline?.collapseItem(nil, collapseChildren: true)
    }

    /// Reopens the folders that were open when this checkout's tree was last on
    /// screen — the pane is rebuilt per checkout, the model is kept.
    private func restoreExpansion() {
        guard let outline else { return }
        let paths = model.expandedPaths.sorted {
            $0.count(where: { $0 == "/" }) < $1.count(where: { $0 == "/" })
        }
        for path in paths {
            guard let node = model.node(at: path), node.isDirectory else { continue }
            outline.expandItem(node)
        }
    }

    private func applyRowHeight() {
        guard let outline, let settings else { return }
        let height = Self.rowHeight(for: settings)
        guard outline.rowHeight != height else { return }
        outline.rowHeight = height
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< outline.numberOfRows))
    }

    /// The label's line, or its icon when that is taller, plus the 2pt the rows
    /// have always had above and below.
    private static func rowHeight(for settings: AppSettings) -> CGFloat {
        let size = CGFloat(settings.interfaceFontSize)
        let font = settings.interfaceFontFamily.isEmpty
            ? NSFont.systemFont(ofSize: size)
            : NSFont(name: settings.interfaceFontFamily, size: size) ?? .systemFont(ofSize: size)
        let line = ceil(font.ascender - font.descender + font.leading)
        return max(line, 16) + 6
    }

    // MARK: Clicks and keys

    /// A click on a row: a folder opens or closes, a file opens — including the
    /// file already selected, which is how one is reopened after its editor
    /// closed. A click on the disclosure triangle never gets here.
    @objc private func rowClicked() {
        guard let outline, outline.clickedRow >= 0,
              let node = outline.item(atRow: outline.clickedRow) as? DeviceFileNode,
              node.notice == nil
        else { return }
        guard node.isDirectory else {
            onOpen(node)
            return
        }
        if outline.isItemExpanded(node) {
            outline.animator().collapseItem(node)
        } else {
            outline.animator().expandItem(node)
        }
    }

    /// Quick Look previews a file on this Mac; a row on another device has
    /// nothing local to hand the panel.
    fileprivate func quickLook() -> Bool {
        guard writes != nil, selection.wrappedValue != nil else { return false }
        onQuickLook()
        return true
    }

    // MARK: Data source

    private func children(of item: Any?) -> [DeviceFileNode] {
        guard let node = item as? DeviceFileNode else { return model.rootNodes }
        // The getter starts the listing of a folder never opened before; the
        // outline only asks for the children of folders it is showing open.
        return node.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let rows = children(of: item)
        // The count was read a moment ago from the same array; a mismatch means
        // a listing landed in between, and the reload it published re-asks.
        return rows.indices.contains(index) ? rows[index] : (item ?? NSNull())
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DeviceFileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Dragged out as its file URL: the terminal inserts the quoted path, a
        // folder row moves the file in. A row on another device has no URL here.
        guard let node = item as? DeviceFileNode, node.notice == nil else { return nil }
        return node.localURL as NSURL?
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard writes != nil else { return [] }
        let folder = dropFolder(for: item as? DeviceFileNode)
        outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        setDropTarget(folder?.path)
        return (info.draggingSource as AnyObject?) === outlineView ? .move : .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
        item: Any?, childIndex index: Int
    ) -> Bool {
        setDropTarget(nil)
        guard let writes else { return false }
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let destination = (item as? DeviceFileNode)?.localURL ?? writes.rootURL
        return writes.onDrop(urls, destination)
    }

    /// The folder a drop lands in: the folder under the pointer, or the folder
    /// holding the file under it — VS Code's explorer — and `nil` for the root.
    private func dropFolder(for node: DeviceFileNode?) -> DeviceFileNode? {
        guard let node else { return nil }
        if node.isDirectory { return node.localURL == nil ? nil : node }
        return model.node(at: (node.path as NSString).deletingLastPathComponent)
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let settings, let node = item as? DeviceFileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? FileOutlineCell
            ?? FileOutlineCell(identifier: Self.cellIdentifier)
        cell.show(FileRowLabel(
            row: FileRowSnapshot(node, decoration: model.decorations.decoration(for: node)),
            settings: settings))
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let settings else { return nil }
        let rowView = outlineView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? FileOutlineRowView
            ?? FileOutlineRowView(settings: settings, identifier: Self.rowIdentifier)
        rowView.beginPlacement()
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? FileOutlineRowView else { return }
        rowView.decoration = (outlineView.item(atRow: row) as? DeviceFileNode)
            .map { model.decorations.decoration(for: $0) }
        rowView.isHovered = row == hoveredRow
        rowView.isDropTarget = dropTargetPath != nil
            && (outlineView.item(atRow: row) as? DeviceFileNode)?.path == dropTargetPath
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        // The note a shortened listing carries runs to two lines.
        (item as? DeviceFileNode)?.notice == nil ? outlineView.rowHeight : max(outlineView.rowHeight, 34)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? DeviceFileNode)?.notice == nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, let outline else { return }
        let node = outline.item(atRow: outline.selectedRow) as? DeviceFileNode
        selection.wrappedValue = node?.path
        // A click opens through `rowClicked`; the arrow keys send no click, and
        // walking the tree with them opens each file as it is reached.
        if let node, !node.isDirectory, NSApp.currentEvent?.type == .keyDown {
            onOpen(node)
        }
    }

    // Every way a folder opens or closes passes through these — a row click, the
    // disclosure triangle, the arrow keys.
    func outlineViewItemWillExpand(_ notification: Notification) {
        settlingUntil = .now + Self.settleDuration
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        settlingUntil = .now + Self.settleDuration
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DeviceFileNode else { return }
        model.expandedPaths.insert(node.path)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DeviceFileNode else { return }
        model.expandedPaths.remove(node.path)
    }

    // MARK: Hover, drop target, menus

    fileprivate func setHoveredRow(_ row: Int) {
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        rowView(at: previous)?.isHovered = false
        rowView(at: row)?.isHovered = true
    }

    fileprivate func setDropTarget(_ path: String?) {
        guard path != dropTargetPath, let outline else { return }
        for old in [dropTargetPath, path].compactMap({ $0 }) {
            guard let node = model.node(at: old) else { continue }
            rowView(at: outline.row(forItem: node))?.isDropTarget = old == path
        }
        dropTargetPath = path
    }

    private func rowView(at row: Int) -> FileOutlineRowView? {
        guard row >= 0, let outline, row < outline.numberOfRows else { return nil }
        return outline.rowView(atRow: row, makeIfNecessary: false) as? FileOutlineRowView
    }

    /// The row's menu, or the root's for the empty area below the rows. Every
    /// item moves or reveals a file through this process, so a checkout on
    /// another device gets no menu rather than one where each item refuses.
    fileprivate func showMenu(for event: NSEvent) {
        guard let outline, let writes else { return }
        let point = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: point)
        let owner: FileRowMenu
        if row >= 0 {
            guard let node = outline.item(atRow: row) as? DeviceFileNode,
                  node.notice == nil, let url = node.localURL
            else { return }
            owner = FileRowMenu(
                target: url, isDirectory: node.isDirectory,
                symbolicLinkTarget: node.resolvedSymbolicLinkTarget, writes: writes)
        } else {
            owner = FileRowMenu(rootOf: writes)
        }
        menuOwner = owner
        owner.menu().popUp(positioning: nil, at: point, in: outline)
    }
}

/// The outline with the AppKit events the tree handles itself: hover, the
/// right-click menu, Quick Look's space bar, and the end of a drag over it.
final class FileOutlineView: NSOutlineView {
    weak var controller: FileOutlineController?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        trackHover(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.setHoveredRow(-1)
    }

    /// Scrolling moves rows under a pointer that did not move.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        if let window { trackHover(at: window.mouseLocationOutsideOfEventStream) }
    }

    private func trackHover(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        controller?.setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    }

    /// Popped up here rather than through `menu(for:)`, which rings the clicked
    /// row in an accent outline that cannot be styled off.
    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            controller?.showMenu(for: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", controller?.quickLook() == true { return }
        super.keyDown(with: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        controller?.setDropTarget(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        controller?.setDropTarget(nil)
    }
}

/// A row's background: the left sidebar's own highlight, so both side panels
/// mark selection, hover and a drop target identically.
private final class FileOutlineRowView: NSTableRowView {
    var isHovered = false { didSet { if isHovered != oldValue { refresh() } } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { refresh() } } }
    var decoration: FileDecoration? { didSet { if decoration != oldValue { refresh() } } }
    override var isSelected: Bool { didSet { if isSelected != oldValue { refresh() } } }

    private let settings: AppSettings
    private let highlight: NSHostingView<FileRowHighlight>
    /// Set while the table is putting this view on a row — new, or recycled from
    /// another. A reload hands every row view back out, rarely to the row it came
    /// from, then corrects each one's selection: faded, the old row's grey visibly
    /// slid off one row down and back. Those corrections describe where the view
    /// now is, not a change anyone made, so they land at once; the user's own
    /// selections still fade.
    private var isBeingPlaced = true

    init(settings: AppSettings, identifier: NSUserInterfaceItemIdentifier) {
        self.settings = settings
        highlight = NSHostingView(rootView: FileRowHighlight(
            isSelected: false, isHovering: false, decoration: nil, animatesSelection: false,
            settings: settings))
        super.init(frame: .zero)
        self.identifier = identifier
        highlight.sizingOptions = []
        highlight.frame = bounds
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight)
    }

    /// Called each time the outline asks for this view for a row. The table places a
    /// view and sets its state in the same pass; the next turn of the run loop is the
    /// first moment a change is the user's.
    func beginPlacement() {
        isBeingPlaced = true
        Task { @MainActor [weak self] in self?.isBeingPlaced = false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawSelection(in dirtyRect: NSRect) {}

    private func refresh() {
        highlight.rootView = FileRowHighlight(
            isSelected: isSelected || isDropTarget, isHovering: isHovered,
            decoration: decoration, animatesSelection: !isBeingPlaced, settings: settings)
    }
}

private struct FileRowHighlight: View {
    let isSelected: Bool
    let isHovering: Bool
    let decoration: FileDecoration?
    /// Whether a change of `isSelected` fades. Off while the table places the row.
    let animatesSelection: Bool
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = FileTreePalette.resolve(settings: settings, colorScheme: colorScheme)
        SidebarRowHighlight(
            isSelected: isSelected,
            isHovering: isHovering,
            chrome: settings.chromeTheme(for: colorScheme)
        )
        .overlay {
            // On top of the highlight rather than behind it: without a theme, selection
            // and hover are a material that hides whatever is beneath, and a test file
            // has to read as one whatever state its row is in.
            if let decoration, let layer = palette.layer(for: decoration) {
                rowShape(Color(nsColor: layer))
            }
        }
        // The highlight's own 6pt leading inset is cancelled so its lift reaches
        // the disclosure triangle rather than crowding it.
        .padding(.leading, -6)
        .animation(animatesSelection ? .easeInOut(duration: 0.12) : nil, value: isSelected)
        // No animation on hover: a fade is latency on a cue whose job is to
        // track the pointer.
        .animation(nil, value: isHovering)
    }

    /// The highlight's own shape and insets, so a selected test file reads as one row
    /// rather than a pill inside a band.
    private func rowShape(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }
}

/// A cell holding one row's SwiftUI label.
private final class FileOutlineCell: NSTableCellView {
    private var hosting: NSHostingView<FileRowLabel>?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ label: FileRowLabel) {
        if let hosting {
            hosting.rootView = label
            return
        }
        let hosting = NSHostingView(rootView: label)
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        self.hosting = hosting
    }
}

/// What a row draws, copied off its node: the node is a class the outline
/// shares, so a label holding it would not see that it changed.
struct FileRowSnapshot: Equatable {
    let url: URL
    let name: String
    let notice: String?
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let symbolicLinkTarget: String?
    let isIgnored: Bool
    let isLoading: Bool
    let decoration: FileDecoration
    /// Whether clicking it does anything. A folder expands; a file on this Mac
    /// opens whatever it is; a file on another device opens only if the host
    /// will serve it as bytes. A socket, a device node, a link the host will not
    /// follow reads as unavailable rather than as a row that ignores the click.
    let isActivatable: Bool

    @MainActor
    init(_ node: DeviceFileNode, decoration: FileDecoration = FileDecoration()) {
        self.decoration = decoration
        url = node.url
        name = node.name
        notice = node.notice
        isDirectory = node.isDirectory
        isSymbolicLink = node.isSymbolicLink
        symbolicLinkTarget = node.symbolicLinkTarget
        isIgnored = node.isIgnored
        isLoading = node.isLoading
        isActivatable = node.isDirectory || node.canPreview || node.localURL != nil
    }
}

/// One row's label: the folder glyph or the file's type icon, the name, and a
/// spinner while a folder waits on its listing.
private struct FileRowLabel: View {
    let row: FileRowSnapshot
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }
    private var palette: FileTreePalette { FileTreePalette.resolve(settings: settings, colorScheme: colorScheme) }

    private var ignoredForeground: Color? {
        guard settings.dimIgnoredFiles, row.isIgnored else { return nil }
        return Palette.color(.grey)
    }

    /// The name's ink: how the file differs from the branch's base, else dimmed when
    /// ignored, else brown when generated, else the theme's own foreground. A change
    /// outranks being generated — a lockfile this branch rewrote is news.
    private var nameForeground: Color {
        if let change = row.decoration.change {
            return Color(nsColor: palette.ink(for: change, on: row.decoration))
        }
        if let ignoredForeground { return ignoredForeground }
        if row.decoration.kind == .generated { return Color(nsColor: palette.generatedInk) }
        return chrome?.foreground ?? .primary
    }

    var body: some View {
        if let notice = row.notice {
            // Not a file: no icon column, no highlight, no affordance. A quiet
            // line in the folder it belongs to, which is where a listing that
            // stopped short has to say so — the rows above it look complete.
            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            label
        }
    }

    private var label: some View {
        // One HStack for both kinds, so names line up down the tree: a folder
        // leads with the sidebar's folder glyph, a file with its type icon, in
        // the same 16-wide column.
        HStack(spacing: 5) {
            if row.isDirectory {
                // Static — the disclosure triangle already carries open/closed.
                // A symlinked folder gets its own glyph rather than a badge,
                // which stays legible at 15pt where a composited badge does not.
                HugeIconView(
                    icon: row.isSymbolicLink ? .folderSymlink : .folder,
                    size: 15,
                    color: ignoredForeground ?? chrome?.foreground ?? .primary
                )
                .frame(width: 16, alignment: .leading)
            } else {
                // The file's language/tool logo (a Devicon mark) when bundled,
                // else a tinted SF Symbol. Boxed below the folder's 15 because
                // Devicon marks fill their box edge to edge while HugeIcons ink
                // only ~75% of theirs — 12 brings the ink widths level. Only the
                // last path component is read, so a device path's synthetic URL
                // is enough.
                FileIconView(url: row.url, size: 12, symbolSize: 11, ink: chrome?.foreground ?? .primary, foregroundOverride: ignoredForeground)
                    .frame(width: 16, alignment: .leading)
            }
            Text(row.name)
                .foregroundStyle(nameForeground)
                .font(settings.interfaceFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .overlay(alignment: .bottom) {
                    if row.decoration.hasError {
                        ZigZagUnderline()
                            .stroke(Color(nsColor: palette.errorInk(on: row.decoration)),
                                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                            .frame(height: 3)
                            .offset(y: 2)
                            .accessibilityHidden(true)
                    }
                }
            // A folder waiting on its listing would otherwise draw as an empty
            // folder, the one thing it is not.
            if row.isLoading {
                // No `scaleEffect`: an animating layer under a transform
                // re-rasterizes every frame, which beachballed the sidebar once.
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Where a symlink points — the one fact about a link no badge can carry.
        .modifier(SymbolicLinkTooltip(target: row.symbolicLinkTarget))
        .opacity(row.isActivatable ? 1 : 0.55)
        .help(row.isActivatable ? "" : localized("Special files can’t be previewed"))
    }
}

/// The squiggle an editor draws under an error, sized to the text it sits under.
private struct ZigZagUnderline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = rect.height
        var x = rect.minX
        var high = false
        path.move(to: CGPoint(x: x, y: rect.maxY))
        while x < rect.maxX {
            x = min(x + step, rect.maxX)
            high.toggle()
            path.addLine(to: CGPoint(x: x, y: high ? rect.minY : rect.maxY))
        }
        return path
    }
}

/// The file tree's colors, all drawn from `Palette` against the terminal background the
/// tree sits on. Test files are the one kind marked with a background — a light green
/// layer — and everything else speaks through the name's ink, held to a legible contrast
/// against whatever it is drawn over.
struct FileTreePalette {
    private let background: NSColor
    private let isDark: Bool
    private let test: NSColor

    init(background: NSColor, isDark: Bool) {
        self.background = background
        self.isDark = isDark
        test = Palette.fill(.green, .tint, on: background, dark: isDark)
    }

    /// One palette per background, rebuilt only when the theme moves: every row
    /// asks for it, and the inks walk a contrast check.
    @MainActor private static var cache: (key: String, palette: FileTreePalette)?

    @MainActor
    static func resolve(settings: AppSettings, colorScheme: ColorScheme) -> FileTreePalette {
        let resolved = settings.paletteBackground(for: colorScheme)
        let key = "\(resolved.color.usingColorSpace(.sRGB)?.description ?? "")|\(resolved.isDark)"
        if let cache, cache.key == key { return cache.palette }
        let palette = FileTreePalette(background: resolved.color, isDark: resolved.isDark)
        cache = (key, palette)
        return palette
    }

    /// What a test row's background comes to over the plain pane — the surface its
    /// name's ink is held legible against — or `nil` for every other row.
    func fill(for decoration: FileDecoration) -> NSColor? {
        decoration.kind == .test ? test : nil
    }

    /// A test row's light green, as the translucent layer drawn over it. Translucent
    /// rather than mixed like `fill`, because it sits over whatever highlight the row
    /// has — none, hover, or a selection material that is not one known color.
    func layer(for decoration: FileDecoration) -> NSColor? {
        guard decoration.kind == .test else { return nil }
        return Palette.base(.green, dark: isDark).withAlphaComponent(Palette.Strength.tint.amount(dark: isDark))
    }

    func ink(for change: FileDecoration.Change, on decoration: FileDecoration) -> NSColor {
        let surface = fill(for: decoration) ?? background
        switch change {
        case .added:
            return Palette.ink(.green, on: surface, dark: isDark)
        case .modified:
            // The same green, a step back toward the background — still green, and
            // still legible, but quieter than a file that is new outright.
            let added = Palette.ink(.green, on: surface, dark: isDark)
            return Palette.legible(Palette.mix(added, surface, 0.35), on: surface, dark: isDark, minimumContrast: 3)
        case .cosmetic:
            return Palette.ink(.blue, on: surface, dark: isDark)
        }
    }

    /// A lockfile's or a generator's output's name: brown, so it reads as machine-made.
    var generatedInk: NSColor { Palette.ink(.brown, on: background, dark: isDark) }

    func errorInk(on decoration: FileDecoration) -> NSColor {
        Palette.ink(.red, on: fill(for: decoration) ?? background, dark: isDark, minimumContrast: 3)
    }
}

/// The right-click menu for a row on this Mac, or for the empty area below the
/// rows (New File / New Folder at the root). AppKit `NSMenu` rather than
/// SwiftUI's `.contextMenu`, which rings the row in an accent outline.
@MainActor
private final class FileRowMenu: NSObject {
    private let target: URL
    private let isDirectory: Bool
    /// Where this row's symlink lands; gates Show Original.
    private let symbolicLinkTarget: URL?
    private let isRoot: Bool
    private let writes: FileTreeWrites

    init(target: URL, isDirectory: Bool, symbolicLinkTarget: URL?, writes: FileTreeWrites) {
        self.target = target
        self.isDirectory = isDirectory
        self.symbolicLinkTarget = symbolicLinkTarget
        self.isRoot = false
        self.writes = writes
    }

    init(rootOf writes: FileTreeWrites) {
        self.target = writes.rootURL
        self.isDirectory = true
        self.symbolicLinkTarget = nil
        self.isRoot = true
        self.writes = writes
    }

    private var actions: FileTreeActions { writes.actions }

    func menu() -> NSMenu {
        let menu = NSMenu()
        if isRoot {
            menu.addItem(item(localized("New File"), #selector(newFile)))
            menu.addItem(item(localized("New Folder"), #selector(newFolder)))
            return menu
        }
        // Cursor's explorer verb, leading the menu: the row lands in the agent's
        // prompt as a shell-quoted path. Asked at open time; a plain shell has
        // no chat to add to.
        if actions.canAddToChat() {
            menu.addItem(item(localized("Add to Chat"), #selector(addToChat)))
            menu.addItem(.separator())
        }
        if isDirectory {
            menu.addItem(item(localized("New File"), #selector(newFile)))
            menu.addItem(item(localized("New Folder"), #selector(newFolder)))
            menu.addItem(.separator())
        }
        // The Finder's verb for an alias, directly above Reveal in Finder so the
        // pair reads as "the original" versus "this link".
        if symbolicLinkTarget != nil {
            menu.addItem(item(localized("Show Original"), #selector(showOriginal)))
        }
        menu.addItem(item(localized("Reveal in Finder"), #selector(revealInFinder)))
        menu.addItem(item(localized("Open in Integrated Terminal"), #selector(openInTerminal)))
        if !isDirectory, let task = actions.wholeFileTask(target) {
            let run = item(localized("Run in Integrated Terminal"), #selector(runInTerminal(_:)))
            run.representedObject = task
            run.image = Self.runImage
            menu.addItem(run)
        }
        menu.addItem(.separator())
        menu.addItem(item(localized("Copy Path"), #selector(copyPath)))
        menu.addItem(item(localized("Copy Relative Path"), #selector(copyRelativePath)))
        menu.addItem(.separator())
        menu.addItem(item(localized("Rename…"), #selector(rename)))
        menu.addItem(item(localized("Delete"), #selector(deleteItem)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func addToChat() { actions.addToChat(target) }
    @objc private func newFile() { actions.newFile(target) }
    @objc private func newFolder() { actions.newFolder(target) }
    @objc private func rename() { actions.rename(target) }
    @objc private func deleteItem() { actions.delete(target) }
    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// A folder opens in itself; a file opens in the folder that holds it.
    @objc private func openInTerminal() {
        actions.openInTerminal(isDirectory ? target : target.deletingLastPathComponent())
    }

    @objc private func runInTerminal(_ sender: NSMenuItem) {
        guard let task = sender.representedObject as? RunTask else { return }
        actions.runTask(task)
    }

    /// The green ▶ the editor's gutter draws for the same run.
    private static let runImage: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
        return NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }()

    /// Reveals what the link points at — the Finder selects the target in its
    /// own folder, which is where "where does this actually live" is answered.
    @objc private func showOriginal() {
        guard let symbolicLinkTarget else { return }
        NSWorkspace.shared.activateFileViewerSelecting([symbolicLinkTarget])
    }

    @objc private func copyPath() {
        setPasteboard(target.path)
    }

    /// The path relative to the project root — the form agents and build tools
    /// take; the absolute path for anything outside the root.
    @objc private func copyRelativePath() {
        let rootPath = writes.rootURL.standardizedFileURL.path
        let path = target.standardizedFileURL.path
        setPasteboard(path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path)
    }

    private func setPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

/// Hover text naming a symlink's target, applied only when there is one — `.help("")`
/// still arms an AppKit tooltip, which would flash an empty bubble over every ordinary
/// row in the tree.
private struct SymbolicLinkTooltip: ViewModifier {
    let target: String?

    func body(content: Content) -> some View {
        if let target {
            content.help(localized("Alias → \(target)"))
        } else {
            content
        }
    }
}

/// A zero-size helper that finds the `NSTableView`/`NSOutlineView` backing a List
/// (by walking up from its own placement inside a row) and corrects two AppKit-layer
/// details SwiftUI gets wrong for our lists. Re-applied on every update because each
/// row mounts one, so any list rebuild reasserts both. Shared by the left sidebar,
/// this file tree, and the Issues / PR-files / git-changes lists.
///
/// - `selectionHighlightStyle = .none` strips the source list's blue accent fill
///   while leaving selection itself intact — the List keeps native, drag-friendly
///   selection and `SidebarRowHighlight` is the only thing that paints it.
/// - `verticalLineScroll = 24` restores mouse-wheel scrolling. These lists all set
///   `defaultMinListRowHeight` to 1 so rows self-size, but SwiftUI writes that
///   minimum into `NSTableView.rowHeight`, and AppKit mirrors `rowHeight` into the
///   enclosing scroll view's `verticalLineScroll` — the per-line increment every
///   non-precise (physical wheel) scroll event is multiplied by. At 1pt a wheel
///   notch barely moves the list; 24 is what a default-height List gets, so wheels
///   feel like every other Mac list. Trackpads send precise pixel deltas and never
///   consult it.
struct OutlineViewFixups: NSViewRepresentable {
    /// Overrides the table's style. Left `nil` everywhere the source list's own
    /// metrics are wanted; the settings sidebar passes `.fullWidth` because
    /// `.sourceList` reserves a leading strip for a disclosure column that a flat
    /// list never uses, and that strip is not reachable from `listRowInsets` —
    /// it lands *outside* them, so the rows can only ever start further right
    /// than the traffic lights they should line up under.
    var style: NSTableView.Style?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(from: view, style: style) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(from: nsView, style: style) }
    }

    /// Reasserts the wheel increment on an outline captured earlier (see
    /// `OutlineViewCapture`) — for callers that know a specific update just reset
    /// it, like the inspector's tab switch covering the always-mounted file tree.
    static func assertWheelIncrement(on outline: NSOutlineView?) {
        guard let scroll = outline?.enclosingScrollView, scroll.verticalLineScroll != 24 else { return }
        scroll.verticalLineScroll = 24
    }

    private static func apply(from view: NSView, style: NSTableView.Style?) {
        var ancestor = view.superview
        while let current = ancestor {
            // NSOutlineView is an NSTableView subclass, so this catches the tree.
            if let table = current as? NSTableView {
                if table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
                if let style, table.style != style {
                    table.style = style
                    // The other half of the same strip: an outline indents every
                    // row by one level's worth even when nothing is nested.
                    (table as? NSOutlineView)?.indentationPerLevel = 0
                }
                if let scroll = table.enclosingScrollView {
                    if scroll.verticalLineScroll != 24 {
                        scroll.verticalLineScroll = 24
                    }
                    enforce(scroll)
                }
                return
            }
            ancestor = current.superview
        }
    }

    /// SwiftUI re-configures the List's scroll view on some structural updates
    /// (covering the pane with another tab's overlay is one), resetting
    /// `verticalLineScroll` back to the 1pt it mirrors from `rowHeight` — and a
    /// property-less representable gets no `updateNSView` afterward to re-run
    /// `apply`, so a one-shot write stays clobbered on an always-mounted list.
    /// This observer watches the clip view's bounds (they change on every scroll)
    /// and re-asserts the increment the moment a reset scroll view first moves, so
    /// a wheel is never slow for more than its first notch. One observer per
    /// scroll view; the token dies with the scroll view it's associated to.
    private static func enforce(_ scroll: NSScrollView) {
        guard objc_getAssociatedObject(scroll, &enforcementKey) == nil else { return }
        scroll.contentView.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: nil
        ) { [weak scroll] _ in
            // `queue: nil` delivers on the posting thread, and AppKit posts a clip
            // view's bounds change on main — the isolation the scroll view's own
            // properties require.
            MainActor.assumeIsolated {
                guard let scroll, scroll.verticalLineScroll != 24 else { return }
                scroll.verticalLineScroll = 24
            }
        }
        objc_setAssociatedObject(scroll, &enforcementKey, token, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// Unique address keying the enforcement token onto its scroll view. Only its
/// address is ever taken; the value itself is never read or written.
nonisolated(unsafe) private var enforcementKey: UInt8 = 0
