import AppKit

/// The editor's line commands — VS Code's `editor.action.commentLine`, `moveLines*` and
/// `copyLines*` — written as pure functions over the buffer for the same reason
/// `EditorIndentation` is: every one of them is a keystroke whose behavior should be pinned by
/// tests rather than by a window. Offsets are `NSString` UTF-16 code units throughout, the unit
/// `NSTextView` selections use.
enum EditorLineCommands {
    /// Which way a move or copy sends the touched lines.
    enum Direction {
        case up
        case down
    }

    /// What a keystroke asks the editor to do to the touched lines.
    enum Command: Equatable {
        case toggleComment
        case move(Direction)
        case copy(Direction)
    }

    // MARK: Keys

    private static let upArrow = String(utf16CodeUnits: [unichar(NSUpArrowFunctionKey)], count: 1)
    private static let downArrow = String(utf16CodeUnits: [unichar(NSDownArrowFunctionKey)], count: 1)

    /// The command `modifiers` and `key` (an event's `charactersIgnoringModifiers`) ask for, or
    /// `nil` for every other keystroke.
    ///
    /// Arrow keys carry `.function` and `.numericPad` alongside whatever the user is holding, and
    /// Caps Lock rides along on anything at all. None of the three change which command was asked
    /// for, so they come off before the match — matching the raw flags would mean Option-Up never
    /// fired.
    static func command(for modifiers: NSEvent.ModifierFlags, key: String) -> Command? {
        let held = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        switch (held, key) {
        case (.command, "/"): return .toggleComment
        case (.option, upArrow): return .move(.up)
        case (.option, downArrow): return .move(.down)
        case ([.option, .shift], upArrow): return .copy(.up)
        case ([.option, .shift], downArrow): return .copy(.down)
        default: return nil
        }
    }

    // MARK: Comment markers

    /// Line-comment markers keyed by the grammar `FileEditorView.highlightLanguage(for:)` resolves
    /// — the same string `HighlightedTextView` hands the text storage, so one table serves every
    /// file type the editor colors.
    ///
    /// A grammar missing from this table simply has no ⌘/. Languages whose only comment form is a
    /// block (`css`, `xml`, `markdown`) or that have none at all (`json`, `diff`) are left out
    /// rather than guessed at: a marker the language doesn't know turns working code into a
    /// syntax error.
    private static let markers: [String: String] = [
        "swift": "//",
        "javascript": "//",
        "typescript": "//",
        "go": "//",
        "rust": "//",
        "c": "//",
        "cpp": "//",
        "objectivec": "//",
        "csharp": "//",
        "java": "//",
        "kotlin": "//",
        "scala": "//",
        "dart": "//",
        "php": "//",
        "protobuf": "//",
        "scss": "//",
        "less": "//",
        "python": "#",
        "ruby": "#",
        "perl": "#",
        "r": "#",
        "elixir": "#",
        "graphql": "#",
        "bash": "#",
        "powershell": "#",
        "yaml": "#",
        "makefile": "#",
        "dockerfile": "#",
        "cmake": "#",
        "nginx": "#",
        "properties": "#",
        // The `ini` grammar stands in for TOML, `.env` and `.conf` as well as classic INI, and all
        // but the last of those comment with `#` — the `;` form is the minority the grammar covers.
        "ini": "#",
        "lua": "--",
        "haskell": "--",
        "sql": "--",
        "erlang": "%",
        "clojure": ";",
    ]

    /// The marker ⌘/ toggles for a document, or `nil` when the language has none to offer.
    static func commentMarker(for language: String?) -> String? {
        guard let language else { return nil }
        return markers[language]
    }

    // MARK: Comment toggling

    /// Toggles a line comment across every line the selection touches. Already-commented lines
    /// come back uncommented, but only when *all* of them are — a partly commented block finishes
    /// the job instead, which is what makes the keystroke a toggle rather than a flip.
    ///
    /// The marker lands at the shallowest indent among the touched lines rather than at column
    /// zero, so a commented block keeps the shape it had.
    static func toggleComment(
        _ selection: NSRange, in text: NSString, marker: String
    ) -> EditorIndentation.BlockEdit? {
        let touched = lines(touchedBy: selection, in: text)
        guard !touched.isEmpty else { return nil }

        // Blank lines ride along untouched — a marker on one leaves nothing but trailing
        // whitespace — unless the selection holds nothing else, where the keystroke still has to
        // do something.
        let content = touched.filter { !EditorIndentation.isBlank($0, in: text) }
        let commentsBlankLines = content.isEmpty
        let targets = commentsBlankLines ? touched : content

        let column = targets
            .map { EditorIndentation.leading(of: $0, in: text).length }
            .min() ?? 0
        let allCommented = targets.allSatisfy {
            let start = $0.location + EditorIndentation.leading(of: $0, in: text).length
            return hasMarker(marker, at: start, in: text)
        }

        let transform: (String) -> String = { line in
            guard commentsBlankLines || !line.allSatisfy(\.isWhitespace) else { return line }
            return allCommented
                ? uncommented(line, marker: marker)
                : commented(line, marker: marker, at: column)
        }
        let edit = EditorIndentation.rewrite(selection, in: text, transform: transform)

        // A caret standing at its line's first column rides the marker across. `rewrite` leaves an
        // offset sitting exactly at a line start where it is — right for a whole-line selection,
        // whose start must stay at the start — but a caret there belongs after the marker it just
        // typed, not in front of it.
        let caret = min(max(selection.location, 0), text.length)
        let caretLine = text.lineRange(for: NSRange(location: caret, length: 0))
        guard selection.length == 0, caret == caretLine.location else { return edit }
        let grown = (transform(text.substring(with: caretLine)) as NSString).length - caretLine.length
        return EditorIndentation.BlockEdit(
            range: edit.range,
            replacement: edit.replacement,
            selection: NSRange(location: edit.selection.location + max(0, grown), length: 0)
        )
    }

    /// `marker + " "` at `column`, which the caller has already established is inside the line's
    /// leading whitespace — the space is what separates the marker from the code, and what
    /// `uncommented` takes back off.
    private static func commented(_ line: String, marker: String, at column: Int) -> String {
        let text = line as NSString
        let insertion = min(max(column, 0), text.length)
        return text.substring(to: insertion) + marker + " " + text.substring(from: insertion)
    }

    private static func uncommented(_ line: String, marker: String) -> String {
        let text = line as NSString
        let start = EditorIndentation.leading(of: NSRange(location: 0, length: text.length), in: text).length
        guard hasMarker(marker, at: start, in: text) else { return line }
        var removed = (marker as NSString).length
        // One space after the marker comes off with it, so commenting and uncommenting a line
        // returns it to exactly what it was.
        if start + removed < text.length, text.character(at: start + removed) == 0x20 { removed += 1 }
        return text.substring(to: start) + text.substring(from: start + removed)
    }

    private static func hasMarker(_ marker: String, at offset: Int, in text: NSString) -> Bool {
        let length = (marker as NSString).length
        guard offset >= 0, offset + length <= text.length else { return false }
        return text.substring(with: NSRange(location: offset, length: length)) == marker
    }

    // MARK: Moving and copying lines

    /// The touched lines swapped with the line above or below them, the selection riding along.
    /// Returns `nil` at the ends of the buffer, where there is nothing to swap with.
    static func moveLines(
        _ selection: NSRange, in text: NSString, direction: Direction
    ) -> EditorIndentation.BlockEdit? {
        let block = EditorIndentation.lineBlock(for: selection, in: text)
        guard block.length > 0 else { return nil }
        let blockText = text.substring(with: block)
        let blockTerminator = terminator(of: block, in: text)

        let range: NSRange
        let replacement: String
        let shift: Int
        switch direction {
        case .up:
            guard block.location > 0 else { return nil }
            let above = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let aboveText = text.substring(with: above)
            if blockTerminator.isEmpty {
                // The block is the last line and ends the buffer without a terminator, so it takes
                // over the one that used to end the line above — which now ends the buffer itself.
                let carried = terminator(of: above, in: text)
                let body = (aboveText as NSString).substring(to: above.length - (carried as NSString).length)
                replacement = blockText + carried + body
            } else {
                replacement = blockText + aboveText
            }
            range = NSRange(location: above.location, length: above.length + block.length)
            shift = -above.length
        case .down:
            guard NSMaxRange(block) < text.length else { return nil }
            let below = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            let belowText = text.substring(with: below)
            if terminator(of: below, in: text).isEmpty {
                // The mirror of the case above: the last line has no terminator, so the block
                // hands over its own on the way past.
                let carriedLength = (blockTerminator as NSString).length
                let body = (blockText as NSString).substring(to: block.length - carriedLength)
                replacement = belowText + blockTerminator + body
                shift = below.length + carriedLength
            } else {
                replacement = belowText + blockText
                shift = below.length
            }
            range = NSRange(location: block.location, length: block.length + below.length)
        }
        return EditorIndentation.BlockEdit(
            range: range, replacement: replacement, selection: moved(selection, by: shift, in: text)
        )
    }

    /// The touched lines duplicated above or below themselves. Copying up leaves the selection on
    /// the upper copy — where it already sits — and copying down carries it onto the new lines, so
    /// either keystroke can be held down to stack copies.
    static func copyLines(
        _ selection: NSRange, in text: NSString, direction: Direction
    ) -> EditorIndentation.BlockEdit? {
        let block = EditorIndentation.lineBlock(for: selection, in: text)
        guard block.length > 0 else { return nil }
        let blockText = text.substring(with: block)

        let replacement: String
        let step: Int
        if terminator(of: block, in: text).isEmpty {
            // A last line with no terminator needs one between the copies; borrowing the line
            // above's keeps a CRLF file CRLF.
            let borrowed = block.location > 0
                ? terminator(of: text.lineRange(for: NSRange(location: block.location - 1, length: 0)), in: text)
                : ""
            let separator = borrowed.isEmpty ? "\n" : borrowed
            replacement = blockText + separator + blockText
            step = block.length + (separator as NSString).length
        } else {
            replacement = blockText + blockText
            step = block.length
        }
        return EditorIndentation.BlockEdit(
            range: block,
            replacement: replacement,
            selection: moved(selection, by: direction == .up ? 0 : step, in: text)
        )
    }

    // MARK: Line geometry

    /// Every full line `selection` touches, in buffer order.
    private static func lines(touchedBy selection: NSRange, in text: NSString) -> [NSRange] {
        let block = EditorIndentation.lineBlock(for: selection, in: text)
        var touched: [NSRange] = []
        var location = block.location
        while location < NSMaxRange(block) {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            touched.append(lineRange)
            location = NSMaxRange(lineRange)
        }
        return touched
    }

    /// The terminator `lineRange` ends with — empty for the last line of a buffer that ends
    /// without one. Carried through moves and copies rather than normalized, so a CRLF file keeps
    /// its endings.
    static func terminator(of lineRange: NSRange, in text: NSString) -> String {
        let end = NSMaxRange(lineRange)
        guard end > lineRange.location, end <= text.length else { return "" }
        let last = text.character(at: end - 1)
        guard isLineBreak(last) else { return "" }
        if last == 0x0A, end - 1 > lineRange.location, text.character(at: end - 2) == 0x0D { return "\r\n" }
        return String(utf16CodeUnits: [last], count: 1)
    }

    /// Every code unit `lineRange(for:)` treats as ending a line — vertical tab and form feed and
    /// the Unicode separators included, so a file using one doesn't lose it in a move.
    private static func isLineBreak(_ unit: unichar) -> Bool {
        switch unit {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// `selection` carried by `shift`. The moved and copied blocks travel as a unit, so both of
    /// its endpoints move by the same amount.
    private static func moved(_ selection: NSRange, by shift: Int, in text: NSString) -> NSRange {
        let start = min(max(selection.location, 0), text.length)
        let end = min(max(NSMaxRange(selection), start), text.length)
        return NSRange(location: max(0, start + shift), length: end - start)
    }
}

extension SavingTextView {
    /// The line commands arrive here rather than as standard actions because AppKit binds Option-Up
    /// to a *pair* of selectors (`moveBackward:` then `moveToBeginningOfParagraph:`), so overriding
    /// either one would still let the caret move first; ⌘/ has no standard action at all and
    /// reaches `keyDown` once no menu item claims it.
    override func keyDown(with event: NSEvent) {
        if isEditable, !hasMarkedText(), performLineCommand(with: event) { return }
        super.keyDown(with: event)
    }

    /// Whether `event` was one of the line commands and has been applied. An unknown key, or a
    /// command with nothing to do (a language with no comment marker, a move against the end of
    /// the buffer), falls through to AppKit untouched.
    private func performLineCommand(with event: NSEvent) -> Bool {
        guard let command = EditorLineCommands.command(
            for: event.modifierFlags, key: event.charactersIgnoringModifiers ?? ""
        ) else { return false }
        let text = string as NSString
        let selection = selectedRange()

        let edit: EditorIndentation.BlockEdit?
        switch command {
        case .toggleComment:
            guard let marker = EditorLineCommands.commentMarker(for: language) else { return false }
            edit = EditorLineCommands.toggleComment(selection, in: text, marker: marker)
        case .move(let direction):
            edit = EditorLineCommands.moveLines(selection, in: text, direction: direction)
        case .copy(let direction):
            edit = EditorLineCommands.copyLines(selection, in: text, direction: direction)
        }

        guard let edit, NSMaxRange(edit.range) <= text.length else { return false }
        replaceAsOneEdit(edit.range, with: edit.replacement, selection: edit.selection)
        // A moved or copied block usually leaves the viewport with the caret still on it.
        scrollRangeToVisible(selectedRange())
        return true
    }
}
