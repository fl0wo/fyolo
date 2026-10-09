import AppKit

/// The replace half of the find bar, written as pure functions over the buffer so the two things
/// that are easy to get quietly wrong — what `$1` means, and how many undo steps a Replace All is —
/// are pinned by tests rather than by a window. The matches come from `TextFindEngine`, so what the
/// bar counts and what Replace acts on can never drift apart.
enum FindReplace {
    /// One match and the text that takes its place.
    struct Replacement: Equatable {
        var range: NSRange
        var text: String
    }

    /// Every match of `query`, paired with what `template` turns it into.
    ///
    /// In regex mode the template is expanded the way `NSRegularExpression` does it: `$1`…`$9`
    /// insert capture groups, `$0` the whole match, and `\$` a literal dollar — the same `$1` VS
    /// Code's find widget supports. In literal mode a `$1` is just those two characters. There are
    /// no groups to name without a pattern, and eating a dollar sign out of replaced text would be
    /// a worse answer than not offering the feature.
    static func plan(
        query: String, options: FindOptions, template: String, in text: NSString
    ) -> [Replacement] {
        guard !query.isEmpty, text.length > 0 else { return [] }
        guard options.regex,
              let regex = TextFindEngine.regularExpression(for: query, options: options) else {
            return TextFindEngine.matches(of: query, options: options, in: text)
                .map { Replacement(range: $0, text: template) }
        }
        // Same filter as `TextFindEngine.matches`, so the ranges here are the very ranges the bar
        // is counting — only the results are kept as well, since expanding a capture group needs
        // the match, not just where it sat.
        return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .filter { $0.range.length > 0 }
            .filter { !options.wholeWord || TextFindEngine.isWordBoundary($0.range, in: text) }
            .map { result in
                Replacement(
                    range: result.range,
                    text: regex.replacementString(
                        for: result, in: text as String, offset: 0, template: template))
            }
    }

    /// The single edit that lands every replacement at once: one range reaching from the first
    /// match's start to the last match's end, with the untouched text between them stitched back
    /// in. Replace All has to be one `replaceCharacters` — one edit is one undo step, and undoing
    /// a hundred replacements a hundred times is not what ⌘Z means here. Nil when there is nothing
    /// to replace.
    static func coalesced(_ replacements: [Replacement], in text: NSString) -> Replacement? {
        guard let first = replacements.first, let last = replacements.last else { return nil }
        let span = NSRange(location: first.range.location,
                           length: NSMaxRange(last.range) - first.range.location)
        guard span.location >= 0, NSMaxRange(span) <= text.length else { return nil }

        var stitched = ""
        var cursor = span.location
        // Matches arrive in document order and never overlap, so each one starts at or after the
        // previous one's end; the condition only keeps a malformed list from asking for a
        // negative-length substring.
        for replacement in replacements where replacement.range.location >= cursor {
            stitched += text.substring(
                with: NSRange(location: cursor, length: replacement.range.location - cursor))
            stitched += replacement.text
            cursor = NSMaxRange(replacement.range)
        }
        return Replacement(range: span, text: stitched)
    }

    /// Which match takes the focus after an edit: the first one starting at or after `location`,
    /// wrapping to the top when the edit consumed the last one. `location` is the end of what was
    /// just inserted, so replacing `foo` with `foobar` steps past the replacement instead of
    /// landing back inside it and replacing itself forever.
    static func focusIndex(startingAt location: Int, in matches: [NSRange]) -> Int {
        matches.firstIndex { $0.location >= location } ?? 0
    }
}

/// The bridge from the find bar's Replace buttons to the buffer they act on.
///
/// Replace cannot go through the editor's `text` binding: assigning it replaces the whole document,
/// which drops the undo stack and throws the caret to the top. So the edit is made on the text view
/// through `replaceAsOneEdit` — the same one-edit-one-undo-step shape Tab and Return already use —
/// and the editor hands this controller down to `HighlightedTextView`, which attaches its view.
///
/// Nothing here repaints or recounts: the edit fires `textDidChange`, which is already where the
/// match list is rebuilt and the "n of m" counter refreshed, so the bar stays honest for free.
@MainActor
final class FindReplaceController {
    private weak var textView: SavingTextView?

    func attach(_ textView: SavingTextView) {
        self.textView = textView
    }

    /// The selection in this controller's own text view, when that view holds the keyboard — what
    /// ⌘E turns into the find query. Nil when the editor isn't focused (the find field is, or
    /// another overlay is), so a broadcast verb can't pull text out of a buffer nobody is in.
    func focusedSelection() -> String? {
        guard let textView, let window = textView.window,
              window.isKeyWindow, window.firstResponder === textView else { return nil }
        let range = textView.selectedRange()
        let text = textView.string as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }

    /// Replaces the focused match and reports which match should take the focus next. Nil when
    /// nothing was replaced — no such match, a read-only buffer, or a refused edit.
    func replaceCurrent(
        at index: Int, query: String, options: FindOptions, template: String
    ) -> Int? {
        guard let textView, textView.isEditable else { return nil }
        let plan = FindReplace.plan(
            query: query, options: options, template: template, in: textView.string as NSString)
        guard plan.indices.contains(index) else { return nil }
        let replacement = plan[index]
        guard textView.replaceAsOneEdit(replacement.range, with: replacement.text, selection: nil)
        else { return nil }

        let landed = replacement.range.location + (replacement.text as NSString).length
        let remaining = TextFindEngine.matches(
            of: query, options: options, in: textView.string as NSString)
        let next = FindReplace.focusIndex(startingAt: landed, in: remaining)
        reveal(remaining.indices.contains(next) ? remaining[next] : nil, in: textView)
        return next
    }

    /// Replaces every match as one edit. Returns how many matches it landed.
    @discardableResult
    func replaceAll(query: String, options: FindOptions, template: String) -> Int {
        guard let textView, textView.isEditable else { return 0 }
        let text = textView.string as NSString
        let plan = FindReplace.plan(query: query, options: options, template: template, in: text)
        guard let edit = FindReplace.coalesced(plan, in: text),
              textView.replaceAsOneEdit(edit.range, with: edit.text, selection: nil) else { return 0 }
        return plan.count
    }

    /// Scrolls the match that inherits the focus into view and pulses the find indicator over it.
    /// The repaint after an edit deliberately never scrolls (the user is typing, not navigating),
    /// but a replace *is* navigation — the next match is usually somewhere else on the page.
    private func reveal(_ range: NSRange?, in textView: NSTextView) {
        guard let range, NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }
}
