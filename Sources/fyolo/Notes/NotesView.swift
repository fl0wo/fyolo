import AppKit
import SwiftUI

// MARK: - Page

/// The notes page: which note this is, whether it is saved, and the note
/// itself. Covers the terminal and the inspector; the sidebar stays live, and
/// picking another project or session there turns the page to that note.
struct NotesPage: View {
    @ObservedObject var model: NotesModel
    @EnvironmentObject var settings: AppSettings
    let close: () -> Void

    var body: some View {
        NotesDocumentPage(document: model.document, close: close)
            .id(model.document.scope)
            .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
    }
}

private struct NotesDocumentPage: View {
    @ObservedObject var document: NoteDocument
    @EnvironmentObject var settings: AppSettings
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let copy = document.conflictCopy {
                conflictNotice(copy)
            }
            Divider().opacity(0.5)
            NotesEditor(document: document, font: font, close: close)
        }
    }

    private var font: NSFont {
        let size = max(14, settings.interfaceFontSize + 1)
        if !settings.interfaceFontFamily.isEmpty, let font = NSFont(name: settings.interfaceFontFamily, size: size) {
            return font
        }
        return .systemFont(ofSize: size)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.scope.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = document.scope.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            Text(status)
                .font(.system(size: 10.5))
                .foregroundStyle(document.saveError == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                .help(document.saveError ?? document.url.path)
            TreeHeaderButton(huge: .folder, help: localized("Show in Finder")) {
                if FileManager.default.fileExists(atPath: document.url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([document.url])
                } else {
                    NSWorkspace.shared.open(NotesLibrary.directory)
                }
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(localized("Close Notes"))
        }
        .padding(.horizontal, 16)
        .frame(height: GitChangesView.topBarHeight + 6)
    }

    private var status: String {
        if let error = document.saveError { return localized("Not saved: \(error)") }
        if document.isDirty { return localized("Editing") }
        if document.lastSaved != nil { return localized("Saved") }
        return document.text.isEmpty ? localized("Saved as you type") : ""
    }

    private func conflictNotice(_ copy: URL) -> some View {
        HStack(spacing: 8) {
            Text(localized("This note changed on disk while you were typing. Both are kept; the other version is \(copy.lastPathComponent)."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(localized("Show")) { NSWorkspace.shared.activateFileViewerSelecting([copy]) }
                .buttonStyle(MonitorChipButtonStyle())
            Button(localized("Dismiss")) { document.dismissConflict() }
                .buttonStyle(MonitorChipButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - Editor

/// The note as plain Markdown in an `NSTextView`, styled as it is typed.
private struct NotesEditor: NSViewRepresentable {
    @ObservedObject var document: NoteDocument
    let font: NSFont
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NoteScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = NoteScrollView.magnificationRange.lowerBound
        scrollView.maxMagnification = NoteScrollView.magnificationRange.upperBound
        // `scrollableTextView` builds the text stack; only its text view is swapped
        // for ours, and the scroll view for one that understands zoom.
        let template = NSTextView.scrollableTextView()
        guard let old = template.documentView as? NSTextView,
              let container = old.textContainer else { return scrollView }
        let textView = NoteTextView(frame: old.frame, textContainer: container)
        // The scroll view sets the page width itself (see `NoteScrollView`), so the
        // text view must not follow the clip view on its own.
        textView.autoresizingMask = []
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        container.widthTracksTextView = true
        // Zero padding plus the inset below puts the first character exactly under
        // the header's leading edge.
        container.lineFragmentPadding = 0
        textView.minSize = old.minSize
        textView.maxSize = old.maxSize
        scrollView.documentView = textView
        scrollView.restoreMagnification()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.baseFont = font
        textView.close = close
        textView.string = document.text
        textView.restyle()
        context.coordinator.textView = textView
        context.coordinator.startWatchingDisk()
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            textView.scrollToEndOfDocument(nil)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        textView.close = close
        if textView.baseFont != font {
            textView.baseFont = font
            textView.restyle()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopWatchingDisk()
        coordinator.document.saveNow()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: NoteDocument
        weak var textView: NoteTextView?
        private var diskTimer: Timer?

        init(document: NoteDocument) {
            self.document = document
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            document.edit(textView.string)
            textView.restyle()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL? = (link as? URL) ?? (link as? String).flatMap { NotesLibrary.resolve($0) }
            guard let url else { return false }
            NSWorkspace.shared.open(url)
            return true
        }

        /// Looks for a change made outside the page — by an agent, another
        /// editor, a sync tool — every couple of seconds while the note is open.
        func startWatchingDisk() {
            diskTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textView else { return }
                    if self.document.reloadIfChangedOnDisk() {
                        let selection = textView.selectedRange()
                        textView.string = self.document.text
                        let length = (textView.string as NSString).length
                        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                        textView.restyle()
                    }
                }
            }
        }

        func stopWatchingDisk() {
            diskTimer?.invalidate()
            diskTimer = nil
        }
    }
}

/// The note's text view: Markdown styling, files and images by drop or paste,
/// checkboxes that tick on click, and Esc to close the page.
final class NoteTextView: NSTextView {
    var baseFont: NSFont = .systemFont(ofSize: 14)
    var close: (() -> Void)?

    func restyle() {
        guard let storage = textStorage else { return }
        NotesStyler.apply(to: storage, baseFont: baseFont)
        typingAttributes = [.font: baseFont, .foregroundColor: NSColor.labelColor]
    }

    override func cancelOperation(_ sender: Any?) {
        close?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let toggle = NotesStyler.checkboxToggle(in: string, at: index) {
            insertReplacing(toggle.range, with: toggle.replacement)
            return
        }
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            insertMarkdown(urls.map { NotesLibrary.markdown(forFile: $0) }.joined(separator: "\n"))
            return
        }
        if pasteboard.string(forType: .string) == nil,
           let image = NSImage(pasteboard: pasteboard),
           let png = image.pngRepresentation,
           let path = try? NotesLibrary.storeAttachment(png, fileExtension: "png") {
            insertMarkdown("![\(localized("Pasted image"))](\(path))")
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        insertMarkdown(urls.map { NotesLibrary.markdown(forFile: $0) }.joined(separator: "\n"))
        return true
    }

    /// Inserted as typing would be, so it undoes in one step and saves.
    private func insertMarkdown(_ markdown: String) {
        insertReplacing(selectedRange(), with: markdown)
    }

    private func insertReplacing(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
    }
}

/// The note's scroll view: pinch to zoom on a trackpad, and when zoomed in,
/// two-finger scrolling moves sideways as well as up and down.
///
/// That comes from how wide the page is kept. Zoomed in, the page stays as
/// wide as the view at 100%, so it is wider than what fits and scrolls
/// sideways, with the lines wrapped where they were. Zoomed out, it widens to
/// fill the view and rewraps, so there is never an empty band at the right.
final class NoteScrollView: NSScrollView {
    static let magnificationRange: ClosedRange<CGFloat> = 0.5...4
    private static let magnificationKey = "notes.magnification"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView.postsBoundsChangedNotifications = true
        // Zooming changes the clip view's bounds, not this view's frame, so `tile`
        // alone would miss it. Selector observers are dropped with the view.
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(magnifyEnded(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        fitDocumentWidth()
    }

    @objc private func magnifyEnded(_ notification: Notification) {
        UserDefaults.standard.set(Double(magnification), forKey: Self.magnificationKey)
    }

    override func tile() {
        super.tile()
        fitDocumentWidth()
    }

    /// The last zoom used, so the notes open at the size they were read at.
    func restoreMagnification() {
        let saved = CGFloat(UserDefaults.standard.double(forKey: Self.magnificationKey))
        guard saved > 0 else { return }
        magnification = min(max(saved, Self.magnificationRange.lowerBound), Self.magnificationRange.upperBound)
        fitDocumentWidth()
    }

    private func fitDocumentWidth() {
        guard let document = documentView else { return }
        let width = max(contentView.frame.width, contentView.bounds.width)
        if abs(document.frame.width - width) > 0.5 {
            document.setFrameSize(NSSize(width: width, height: document.frame.height))
        }
    }
}

private extension NSImage {
    var pngRepresentation: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Styling

/// Markdown styling for the note, worked out from the plain text on every
/// edit. The file stays plain Markdown; only how it is drawn changes.
enum NotesStyler {
    enum Kind: Equatable {
        case heading(level: Int)
        case link(String)
        case checkbox(checked: Bool)
        case doneItem
        case quote
        case code
    }

    struct Span: Equatable {
        let range: NSRange
        let kind: Kind
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    static func spans(in text: String) -> [Span] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        var spans: [Span] = []
        regex(#"^(#{1,3})\s+\S.*$"#)?.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            spans.append(Span(range: match.range, kind: .heading(level: match.range(at: 1).length)))
        }
        regex(#"^\s*[-*]\s(\[([ xX])\])(.*)$"#)?.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            let checked = (text as NSString).substring(with: match.range(at: 2)) != " "
            spans.append(Span(range: match.range(at: 1), kind: .checkbox(checked: checked)))
            if checked { spans.append(Span(range: match.range(at: 3), kind: .doneItem)) }
        }
        regex(#"^>.*$"#)?.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            spans.append(Span(range: match.range, kind: .quote))
        }
        regex(#"`[^`\n]+`"#)?.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            spans.append(Span(range: match.range, kind: .code))
        }
        var linked: [NSRange] = []
        regex(#"!?\[[^\]\n]*\]\(([^)\s]+)\)"#)?.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            linked.append(match.range)
            spans.append(Span(range: match.range, kind: .link((text as NSString).substring(with: match.range(at: 1)))))
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match, let url = match.url,
                      !linked.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                else { return }
                spans.append(Span(range: match.range, kind: .link(url.absoluteString)))
            }
        }
        return spans
    }

    static func apply(to storage: NSTextStorage, baseFont: NSFont) {
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: whole)
        for span in spans(in: text) {
            switch span.kind {
            case .heading(let level):
                let scale: CGFloat = level == 1 ? 1.5 : level == 2 ? 1.28 : 1.12
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: baseFont.pointSize * scale, weight: .semibold), range: span.range)
            case .link(let target):
                if let url = NotesLibrary.resolve(target) {
                    storage.addAttribute(.link, value: url, range: span.range)
                }
            case .checkbox(let checked):
                storage.addAttribute(.foregroundColor, value: checked ? NSColor.secondaryLabelColor : NSColor.controlAccentColor, range: span.range)
                storage.addAttribute(.cursor, value: NSCursor.pointingHand, range: span.range)
            case .doneItem:
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: span.range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
            case .code:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.92, weight: .regular), range: span.range)
            }
        }
        storage.endEditing()
    }

    /// A click on a checkbox's `[ ]` ticks it, and on `[x]` clears it.
    static func checkboxToggle(in text: String, at index: Int) -> (range: NSRange, replacement: String)? {
        for span in spans(in: text) {
            guard case .checkbox(let checked) = span.kind,
                  index >= span.range.location, index <= NSMaxRange(span.range)
            else { continue }
            return (NSRange(location: span.range.location + 1, length: 1), checked ? " " : "x")
        }
        return nil
    }
}
