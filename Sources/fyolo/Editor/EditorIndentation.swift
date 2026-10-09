import AppKit

/// The editor's indentation rules — VS Code's defaults (`editor.autoIndent`,
/// `editor.action.indentLines` / `outdentLines`, `editor.detectIndentation`) — written as pure
/// functions over the buffer so the behavior is pinned by tests rather than by a window.
/// Offsets are `NSString` UTF-16 code units throughout, the unit `NSTextView` selections use,
/// so nothing here transcodes.
enum EditorIndentation {
    /// What one level of indentation is in a given buffer.
    struct Unit: Equatable {
        /// Tabs only when the buffer plainly indents with tabs; spaces otherwise.
        var usesTabs: Bool
        /// Spaces per level — also how far one outdent strips a space-indented line.
        var width: Int

        var text: String { usesTabs ? "\t" : String(repeating: " ", count: width) }
    }

    /// Used when the buffer shows no indentation to learn from — a new file, or one that never
    /// nests.
    static let fallbackWidth = 4

    /// Only the first lines are sampled: detection runs on every Return and Tab, and a file's
    /// style is settled long before this many lines.
    private static let sampleLineLimit = 2_000

    /// Wider steps than this are continuation alignment (a wrapped argument list), not a level.
    private static let maximumDetectedWidth = 8

    // MARK: Line scanning

    /// The leading spaces and tabs of one line: how many characters they span, and how many of
    /// those were tabs.
    struct Leading: Equatable {
        var length: Int
        var tabs: Int
    }

    /// Scans the indentation `lineRange` opens with. The range may carry its line terminator —
    /// the scan stops at the first character that is neither a space nor a tab, so a range taken
    /// straight from `lineRange(for:)` can be passed in unchanged.
    ///
    /// Shared with `IndentGuideRenderer`, which asks the same question of the same buffer on every
    /// draw. Character-by-character rather than through `substring`: detection runs on every Return
    /// and Tab over up to `sampleLineLimit` lines, and a String per line is a real allocation on a
    /// keypress path.
    static func leading(of lineRange: NSRange, in text: NSString) -> Leading {
        var length = 0
        var tabs = 0
        for index in lineRange.location..<NSMaxRange(lineRange) {
            switch text.character(at: index) {
            case 0x20: break
            case 0x09: tabs += 1
            default: return Leading(length: length, tabs: tabs)
            }
            length += 1
        }
        return Leading(length: length, tabs: tabs)
    }

    /// Whether `lineRange` holds nothing but whitespace. Line terminators count as blank, so a
    /// range straight from `lineRange(for:)` needs no trimming first.
    static func isBlank(_ lineRange: NSRange, in text: NSString) -> Bool {
        for index in lineRange.location..<NSMaxRange(lineRange) {
            switch text.character(at: index) {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            default: return false
            }
        }
        return true
    }

    // MARK: Detection

    /// The indent unit `text` already uses. Spaces win ties, so a file with no indentation at
    /// all — or one whose leading whitespace is inconsistent — comes back as
    /// `fallbackWidth` spaces.
    static func detected(in text: NSString) -> Unit {
        var tabIndentedLines = 0
        var spaceIndentedLines = 0
        var votes: [Int: Int] = [:]
        var previousSpaces: Int?
        var location = 0
        var scannedLines = 0

        while location < text.length, scannedLines < sampleLineLimit {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            scannedLines += 1

            // A blank or whitespace-only line says nothing about the file's style, and a run of
            // them must not look like a jump back to column zero either.
            guard !isBlank(lineRange, in: text) else { continue }
            let indent = leading(of: lineRange, in: text)
            let leading = indent.length

            if indent.tabs > 0 {
                tabIndentedLines += 1
                previousSpaces = nil
                continue
            }
            if leading > 0 { spaceIndentedLines += 1 }
            if let previous = previousSpaces {
                let step = abs(leading - previous)
                if step > 0, step <= maximumDetectedWidth { votes[step, default: 0] += 1 }
            }
            previousSpaces = leading
        }

        // Most-voted step wins; on a tie the narrower one does, since a file indented by two
        // also produces plenty of four-wide jumps across nested blocks.
        let best = votes.max { left, right in
            left.value != right.value ? left.value < right.value : left.key > right.key
        }
        return Unit(usesTabs: tabIndentedLines > spaceIndentedLines, width: best?.key ?? fallbackWidth)
    }

    // MARK: Return

    /// What Return inserts: the newline plus the indentation the new line opens at — the leading
    /// whitespace of the text before the caret, one level deeper when that text opens a block.
    static func newlineInsertion(at selection: NSRange, in text: NSString, unit: Unit) -> String {
        let caret = min(max(selection.location, 0), text.length)
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let prefix = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        var indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
        // Only what is left of the caret opens a block: pressing Return before a brace should
        // not indent past it.
        if let last = prefix.last(where: { !$0.isWhitespace }), "{[(".contains(last) {
            indent += unit.text
        }
        return "\n" + indent
    }

    // MARK: Tab and Shift-Tab

    /// One line-block rewrite, as data so the caller can land the whole thing as a single
    /// undoable edit.
    struct BlockEdit: Equatable {
        /// The full lines being replaced.
        var range: NSRange
        var replacement: String
        /// Where the selection sits afterwards, its endpoints carried along by the whitespace
        /// added or removed ahead of them.
        var selection: NSRange
    }

    /// Whether `selection` reaches across a line break — the split VS Code draws between Tab
    /// typing an indent and Tab indenting the selected lines.
    static func spansLines(_ selection: NSRange, in text: NSString) -> Bool {
        guard selection.length > 0, NSMaxRange(selection) <= text.length else { return false }
        return text.rangeOfCharacter(from: .newlines, range: selection).location != NSNotFound
    }

    /// Every line the selection touches, one level deeper.
    static func indent(_ selection: NSRange, in text: NSString, unit: Unit) -> BlockEdit {
        rewrite(selection, in: text) { line in
            // An empty line gains nothing from a deeper indent, and the trailing spaces it would
            // leave behind are exactly what a diff flags.
            line.allSatisfy(\.isWhitespace) ? line : unit.text + line
        }
    }

    /// Every line the selection touches, one level shallower. Lines already at column zero are
    /// left alone, so an outdent can never eat a line's first character.
    static func outdent(_ selection: NSRange, in text: NSString, unit: Unit) -> BlockEdit {
        rewrite(selection, in: text) { line in
            var remaining = Substring(line)
            // A tab is one level whatever the detected width is; spaces come off up to a level's
            // worth, so a half-indented line snaps back to column zero rather than staying odd.
            if remaining.first == "\t" { return String(remaining.dropFirst()) }
            var removed = 0
            while removed < unit.width, remaining.first == " " {
                remaining = remaining.dropFirst()
                removed += 1
            }
            return String(remaining)
        }
    }

    /// The full lines `selection` touches. A selection ending exactly at a line start belongs to
    /// the line above it — without the step back, selecting whole lines would take in the
    /// untouched line below them too.
    static func lineBlock(for selection: NSRange, in text: NSString) -> NSRange {
        let start = min(max(selection.location, 0), text.length)
        let end = min(max(NSMaxRange(selection), start), text.length)
        return text.lineRange(for: NSRange(location: start, length: end > start ? end - start - 1 : 0))
    }

    /// Every line the selection touches, rewritten by `transform` (which receives the line with
    /// its terminator), as one replacement with the selection carried through it.
    static func rewrite(
        _ selection: NSRange, in text: NSString, transform: (String) -> String
    ) -> BlockEdit {
        let start = min(max(selection.location, 0), text.length)
        let end = min(max(NSMaxRange(selection), start), text.length)
        let block = lineBlock(for: selection, in: text)

        var lines: [(range: NSRange, delta: Int)] = []
        var replacement = ""
        var location = block.location
        while location < NSMaxRange(block) {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let transformed = transform(text.substring(with: lineRange))
            replacement += transformed
            lines.append((lineRange, (transformed as NSString).length - lineRange.length))
            location = NSMaxRange(lineRange)
        }

        let movedStart = shift(start, through: lines)
        let movedEnd = shift(end, through: lines)
        return BlockEdit(
            range: block,
            replacement: replacement,
            selection: NSRange(location: movedStart, length: max(0, movedEnd - movedStart))
        )
    }

    /// `offset` moved by the whitespace the rewrite added or removed ahead of it. An offset
    /// standing inside removed whitespace lands at its line's start instead of before it.
    private static func shift(_ offset: Int, through lines: [(range: NSRange, delta: Int)]) -> Int {
        var moved = offset
        for line in lines {
            if offset >= NSMaxRange(line.range) {
                moved += line.delta
            } else if offset > line.range.location {
                moved += max(line.delta, line.range.location - offset)
                break
            } else {
                break
            }
        }
        return moved
    }
}

extension SavingTextView {
    /// Detected per keypress rather than cached: the buffer is the only source of truth about
    /// its own style, and it changes under every edit. The scan is bounded (`sampleLineLimit`).
    private var indentUnit: EditorIndentation.Unit {
        EditorIndentation.detected(in: string as NSString)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return super.insertNewline(sender) }
        let insertion = EditorIndentation.newlineInsertion(
            at: selectedRange(), in: string as NSString, unit: indentUnit
        )
        replaceAsOneEdit(selectedRange(), with: insertion, selection: nil)
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return super.insertTab(sender) }
        let text = string as NSString
        let selection = selectedRange()
        guard EditorIndentation.spansLines(selection, in: text) else {
            replaceAsOneEdit(selection, with: indentUnit.text, selection: nil)
            return
        }
        apply(EditorIndentation.indent(selection, in: text, unit: indentUnit))
    }

    override func insertBacktab(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return super.insertBacktab(sender) }
        let text = string as NSString
        apply(EditorIndentation.outdent(selectedRange(), in: text, unit: indentUnit))
    }

    private func apply(_ edit: EditorIndentation.BlockEdit) {
        let text = string as NSString
        guard NSMaxRange(edit.range) <= text.length,
              text.substring(with: edit.range) != edit.replacement else { return }
        replaceAsOneEdit(edit.range, with: edit.replacement, selection: edit.selection)
    }

    /// One undo step per keypress. `shouldChangeText` is what registers the undo, so a whole
    /// multi-line indent lands as a single edit there, and `breakUndoCoalescing` on both sides
    /// stops AppKit folding it into the run of typing around it — ⌘Z steps back exactly one
    /// indent. The replacement carries `typingAttributes` because the buffer's line metrics live
    /// in them: plain text would lay out at the font's natural height and the block would jump
    /// until the highlighter caught up.
    ///
    /// Shared with `EditorLineCommands` and with the find bar's Replace, which both need exactly
    /// this shape — hence the returned flag: a caller that steps the find focus forward must know
    /// whether the edit actually landed, since `shouldChangeText` can refuse.
    @discardableResult
    func replaceAsOneEdit(_ range: NSRange, with replacement: String, selection: NSRange?) -> Bool {
        guard let textStorage, NSMaxRange(range) <= textStorage.length,
              shouldChangeText(in: range, replacementString: replacement) else { return false }
        breakUndoCoalescing()
        textStorage.replaceCharacters(
            in: range, with: NSAttributedString(string: replacement, attributes: typingAttributes)
        )
        didChangeText()
        let inserted = (replacement as NSString).length
        setSelectedRange(selection ?? NSRange(location: range.location + inserted, length: 0))
        breakUndoCoalescing()
        return true
    }
}
