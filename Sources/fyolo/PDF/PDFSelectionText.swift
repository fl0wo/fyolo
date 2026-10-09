import Foundation

/// Turns PDF-extracted text back into prose.
///
/// A PDF has no paragraphs — only typeset lines — so `PDFSelection.string` comes back with
/// a hard break at every line ending and words split across a hyphen at the margin. Pasted
/// into an agent's prompt that reads as forty ragged fragments, which is what makes quoting
/// a paper into a terminal miserable. This rejoins the lines the typesetter broke and leaves
/// alone the ones the author wrote.
enum PDFSelectionText {
    /// The selection as prose: wrapped lines rejoined, hyphenated words healed, blank lines
    /// kept as paragraph breaks, and list items kept on their own lines.
    static func unwrapped(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Each block is a paragraph or a list item; list items stay on adjacent lines
        // while paragraphs are separated by a blank one.
        var blocks: [(text: String, item: Bool)] = []
        var current = ""
        var currentIsItem = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { blocks.append((trimmed, currentIsItem)) }
            current = ""
            currentIsItem = false
        }

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = collapseSpaces(rawLine.trimmingCharacters(in: .whitespaces))
            if line.isEmpty {
                flush()
                continue
            }
            if current.isEmpty {
                current = line
                currentIsItem = startsListItem(line)
                continue
            }
            // A line the author started — a bullet, a numbered item — is not a wrap.
            if startsListItem(line) {
                flush()
                current = line
                currentIsItem = true
                continue
            }
            if let healed = dehyphenating(current, joining: line) {
                current = healed
            } else {
                current += " " + line
            }
        }
        flush()
        return blocks.enumerated().reduce(into: "") { text, entry in
            let (index, block) = entry
            if index > 0 {
                text += block.item && blocks[index - 1].item ? "\n" : "\n\n"
            }
            text += block.text
        }
    }

    /// A word broken at the margin (`inter-` + `pretation`) is rejoined without the hyphen.
    /// A line ending in a hyphen followed by a capital or a digit is left alone: that is a
    /// real hyphen the author typed (`Anti-` `Bayesian`, `COVID-` `19`), not a break.
    private static func dehyphenating(_ current: String, joining next: String) -> String? {
        guard current.hasSuffix("-") || current.hasSuffix("\u{2010}") else { return nil }
        guard let first = next.first, first.isLowercase else { return nil }
        // A double hyphen (`--`) is punctuation, not a break.
        let body = String(current.dropLast())
        guard !body.hasSuffix("-") else { return nil }
        return body + next
    }

    private static func startsListItem(_ line: String) -> Bool {
        if let first = line.first, "•‣◦-*–—".contains(first) {
            // "- item" is a bullet; "-3.4 dB" is a number that happens to lead with a dash.
            return line.dropFirst().first == " "
        }
        // "1. ", "2) ", "iv. " — an enumerated item.
        let head = line.prefix(while: { $0.isNumber })
        guard !head.isEmpty, head.count <= 3 else { return false }
        let rest = line.dropFirst(head.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        return rest.dropFirst().first == " "
    }

    /// A passage reduced to the characters that survive re-typesetting: no case, no
    /// whitespace, no hyphens. Comparing two quotes this way is what lets a mark recognise
    /// its own words after the page they sit on has been re-laid out — where the same
    /// sentence comes back with different line breaks and a hyphen in a different place.
    static func squashed(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && $0 != "-" && $0 != "\u{2010}" && $0 != "\u{00AD}"
        }.map(String.init).joined()
    }

    /// Where a passage sits inside a page's text, ignoring how either one is laid out.
    ///
    /// `findString` is no use for this: PDF text carries a newline at every typeset line and
    /// a hyphen at every broken word, and a search matches across neither. So both sides are
    /// squashed to their surviving characters, the match is made there, and the answer is
    /// mapped back to a range in the original text — which is what `PDFPage` needs to hand
    /// back a selection.
    ///
    /// The mapping walks composed characters, and every position it records is a UTF-16
    /// offset, because that is the only domain `NSRange` and PDFKit understand. An earlier
    /// version counted the squashed side in Swift Characters and the source side in UTF-16
    /// units: the two agree for ASCII and diverge the moment a page carries a combining
    /// accent or an emoji, which shifted the range by a character or lost it entirely.
    static func locate(_ quote: String, in text: String) -> NSRange? {
        let squashedQuote = squashed(quote)
        guard !squashedQuote.isEmpty else { return nil }
        let source = text as NSString
        var flattened: [Character] = []
        // One entry per flattened character: the UTF-16 range of the source character it
        // came from. A character can flatten to several (lowercasing "İ" yields two), so
        // they all point back at the same source range.
        var origins: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length),
                                   options: [.byComposedCharacterSequences]) { piece, range, _, _ in
            guard let piece else { return }
            for character in squashed(piece) {
                flattened.append(character)
                origins.append(range)
            }
        }
        guard !flattened.isEmpty else { return nil }
        let quoteCharacters = Array(squashedQuote)
        guard let start = firstIndex(of: quoteCharacters, in: flattened) else { return nil }
        let first = origins[start]
        let last = origins[start + quoteCharacters.count - 1]
        return NSRange(location: first.location,
                       length: last.location + last.length - first.location)
    }

    /// Plain substring search over characters — `range(of:)` would put us back in String
    /// index space, which is the domain confusion this function exists to avoid.
    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    private static func collapseSpaces(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
