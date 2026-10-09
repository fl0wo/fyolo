import AppKit

/// What the occurrence wash is chasing: the text to look for, where that text already sits (so its
/// own spot stays unwashed), and whether it may only match on word boundaries.
struct OccurrenceTarget: Equatable {
    let text: String
    let range: NSRange
    let wholeWord: Bool

    /// Past this a selection is a block of text being moved, not a name being read — VS Code draws
    /// the same line, and chasing a paragraph through the document would wash half the screen.
    static let maximumSelectionLength = 200

    /// The target for `selection`, or `nil` when nothing about it is worth chasing: an empty
    /// selection, one that crosses lines, one of nothing but whitespace, or one too long to be a
    /// name.
    ///
    /// A bare caret is deliberately nothing to chase. VS Code lights up the symbol under the caret
    /// through `editor.occurrencesHighlight`, but that is answered by a language service's
    /// document-highlight provider — with none installed, as in a YAML or a plain config file,
    /// clicking to place the caret highlights nothing at all. What survives without one is
    /// `editor.selectionHighlight`: matches similar to *the selection*. This editor has no language
    /// service by design, so it implements the half that stands on its own. Lighting the document
    /// up on a click meant to park the caret was noise, not information.
    static func resolve(selection: NSRange, in text: NSString) -> OccurrenceTarget? {
        guard text.length > 0, selection.location >= 0,
              selection.location + selection.length <= text.length else { return nil }
        guard selection.length > 0, selection.length <= maximumSelectionLength else { return nil }
        let candidate = text.substring(with: selection)
        guard !candidate.contains(where: \.isNewline),
              candidate.contains(where: { !$0.isWhitespace }) else { return nil }
        // A selection that covers exactly one word is bounded like one, so double-clicking `set`
        // doesn't light up every `settings`. Anything else — half a word, `foo.bar` — matches
        // literally, since that is what the user pointed at.
        let wholeWord = wordRange(at: selection.location, in: text) == selection
        return OccurrenceTarget(text: candidate, range: selection, wholeWord: wholeWord)
    }

    /// The word containing `location`. Used only to ask whether a selection lands exactly on a word,
    /// so the position is read the way a selection's own start is: the character before it wins when
    /// it sits between a word and anything else.
    static func wordRange(at location: Int, in text: NSString) -> NSRange? {
        var anchor = -1
        if isWordCharacter(at: location - 1, in: text) {
            anchor = location - 1
        } else if isWordCharacter(at: location, in: text) {
            anchor = location
        }
        guard anchor >= 0 else { return nil }
        var start = anchor
        while start > 0, isWordCharacter(at: start - 1, in: text) { start -= 1 }
        var end = anchor + 1
        while end < text.length, isWordCharacter(at: end, in: text) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isWordCharacter(at index: Int, in text: NSString) -> Bool {
        guard index >= 0, index < text.length,
              let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
        return TextFindEngine.wordCharacters.contains(scalar)
    }
}

/// VS Code's `editor.selectionHighlight`: select a name — a double-click is enough — and every
/// other place it appears takes a faint wash, so reading what an agent just wrote shows where that
/// name is used without typing it into find. This editor is read far more than it is typed in,
/// which is what earns a passive hint its cost. A bare caret washes nothing; see
/// `OccurrenceTarget.resolve`.
///
/// It rides the machinery the find bar already has: `TextFindEngine` finds the matches and paints
/// them as temporary layout attributes. Only the trigger (a selection change instead of a query)
/// and the color (weaker, so a passive hint never reads as a search result) differ.
@MainActor
final class OccurrenceHighlighter {
    /// Ranges currently washed, so the next pass lifts exactly its own paint.
    private var painted: [NSRange] = []
    /// What `painted` was computed for — re-selecting the same text repaints nothing.
    private var appliedTarget: OccurrenceTarget?
    /// The document length that memo was taken at. An edit can leave the selection untouched while
    /// adding or removing an occurrence, which the target alone can't see.
    private var appliedLength = -1
    private var pending: Task<Void, Never>?
    /// The same matcher the find bar drives, kept per highlighter so the two never share state.
    private let matcher = TextFindEngine()

    /// A document this long already renders as plain text (`FileEditorView.highlightByteLimit`,
    /// the same figure counted in UTF-16 units here) because whole-document work on it janks. A
    /// scan per selection change is exactly that work, so past this the wash stays off.
    private static let documentLimit = 256 * 1024
    /// A ceiling on washes from one word: a common token in a large file would otherwise put
    /// thousands of temporary attributes on the layout manager for a hint nobody can read.
    private static let matchLimit = 1_000
    /// Long enough that dragging a selection across a line scans once at the end rather than at every
    /// step, short enough that the wash still feels like it belongs to what you just selected.
    private static let debounce: UInt64 = 150_000_000

    /// Re-derive the wash after a selection change. `findActive` hands the highlight layer to the
    /// find bar; a clear `color` turns the behavior off entirely.
    func update(in textView: NSTextView, color: NSColor, findActive: Bool) {
        pending?.cancel()
        pending = nil
        guard !findActive, color.alphaComponent > 0 else {
            clear(in: textView)
            return
        }
        pending = Task { [weak self, weak textView] in
            try? await Task.sleep(nanoseconds: Self.debounce)
            guard !Task.isCancelled, let self, let textView else { return }
            self.apply(in: textView, color: color)
        }
    }

    private func apply(in textView: NSTextView, color: NSColor) {
        let text = textView.string as NSString
        guard text.length <= Self.documentLimit,
              let target = OccurrenceTarget.resolve(
                selection: textView.selectedRange(), in: text)
        else {
            clear(in: textView)
            return
        }
        guard target != appliedTarget || text.length != appliedLength else { return }
        clear(in: textView)
        matcher.recompute(
            query: target.text,
            options: FindOptions(caseSensitive: true, wholeWord: target.wholeWord, regex: false),
            in: textView)
        // The target's own spot is where the eye already is; washing it would just restate the
        // selection, so only the *other* occurrences light up.
        painted = Array(matcher.matches
            .filter { $0.location != target.range.location }
            .prefix(Self.matchLimit))
        TextFindEngine.addHighlight(painted, color: color, in: textView)
        appliedTarget = target
        appliedLength = text.length
    }

    private func clear(in textView: NSTextView) {
        appliedTarget = nil
        appliedLength = -1
        guard !painted.isEmpty else { return }
        TextFindEngine.removeHighlight(painted, in: textView)
        painted = []
    }
}
