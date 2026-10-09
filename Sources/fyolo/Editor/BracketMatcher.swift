import Foundation

/// Plain text-scan bracket pairing for the editor's match highlight. A bracket inside a string
/// or comment can fool it — the classic lightweight-editor tradeoff — and the scan is bounded
/// so an unbalanced megafile can't stall caret movement.
enum BracketMatcher {
    private static let pairs: [(open: unichar, close: unichar)] = [(40, 41), (91, 93), (123, 125)] // () [] {}
    private static let scanLimit = 100_000

    /// The offset of the bracket matching the one at `index`, or `nil` when the character there
    /// isn't a bracket or its partner isn't found within the scan bound.
    static func match(at index: Int, in text: NSString) -> Int? {
        guard index >= 0, index < text.length else { return nil }
        let character = text.character(at: index)
        if let pair = pairs.first(where: { $0.open == character }) {
            return scan(from: index, in: text, pair: pair, forward: true)
        }
        if let pair = pairs.first(where: { $0.close == character }) {
            return scan(from: index, in: text, pair: pair, forward: false)
        }
        return nil
    }

    private static func scan(
        from index: Int, in text: NSString, pair: (open: unichar, close: unichar), forward: Bool
    ) -> Int? {
        var depth = 0
        var position = index
        var steps = 0
        while steps < scanLimit {
            let character = text.character(at: position)
            if character == pair.open { depth += forward ? 1 : -1 }
            else if character == pair.close { depth += forward ? -1 : 1 }
            if depth == 0 { return position == index ? nil : position }
            position += forward ? 1 : -1
            guard position >= 0, position < text.length else { return nil }
            steps += 1
        }
        return nil
    }
}
