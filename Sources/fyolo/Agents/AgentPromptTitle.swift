import Foundation

/// Turns an agent hook's raw user prompt into a quiet sidebar fallback. This is
/// intentionally deterministic: hooks run before the model, so the title must be
/// available immediately without another request or a transcript-format dependency.
enum AgentPromptTitle {
    static let maximumLength = 64

    /// Markdown a prompt often opens with. It decorates; it never names the topic.
    private static let decoration: Set<Character> = ["#", ">", "*", "-", "•", "`"]

    static func normalized(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: isNoise).joined(separator: " ")
        let title = collapsed.drop { decoration.contains($0) || $0 == " " }
        guard !title.isEmpty else { return nil }
        guard title.count > maximumLength else { return String(title) }
        return bounded(title) + "…"
    }

    /// A control character travels in a prompt as literally as a newline does, and on
    /// one sidebar line both are noise rather than text.
    private static func isNoise(_ character: Character) -> Bool {
        character.isWhitespace
            || character.unicodeScalars.allSatisfy(CharacterSet.controlCharacters.contains)
    }

    /// Cuts to fit, preferring a word boundary — but only one past the halfway mark,
    /// so a long opening word cannot shrink the label to a syllable.
    private static func bounded(_ title: Substring) -> String {
        let head = title.prefix(maximumLength - 1)
        guard let lastSpace = head.lastIndex(of: " "),
              head.distance(from: head.startIndex, to: lastSpace) >= maximumLength / 2
        else { return String(head) }
        return String(head[..<lastSpace])
    }
}
