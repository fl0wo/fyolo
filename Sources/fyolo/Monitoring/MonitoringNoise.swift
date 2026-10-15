import Foundation

// MARK: - Similarity

/// Text normalization and similarity, the base of every "like this" in the pane.
enum MonitorNoise {
    /// The message with its variable parts masked: numbers, ids, hashes, IPs,
    /// URLs and emails become placeholders, so `order 812 timed out after 30s`
    /// and `order 977 timed out after 31s` read as one thing.
    static func template(_ text: String) -> String {
        var words: [String] = []
        for word in text.lowercased().split(whereSeparator: \.isWhitespace) {
            words.append(mask(String(word)))
        }
        return words.joined(separator: " ")
    }

    private static let separators: Set<Character> = ["=", ":", ",", ";", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "/", "|", "`"]

    private static func mask(_ word: String) -> String {
        if word.contains("://") { return "<url>" }
        if isEmail(word) { return "<email>" }
        var output = ""
        var segment = ""
        func flush() {
            output += maskSegment(segment)
            segment = ""
        }
        for character in word {
            if separators.contains(character) {
                flush()
                output.append(character)
            } else {
                segment.append(character)
            }
        }
        flush()
        return output
    }

    private static func maskSegment(_ segment: String) -> String {
        guard !segment.isEmpty else { return "" }
        if isIdentifier(segment) { return "<id>" }
        // Digit runs, with the dots and commas between them (versions, IPs,
        // 1,204.5), become one placeholder; the letters around them stay.
        var output = ""
        var inNumber = false
        var pending: Character?
        for character in segment {
            if character.isNumber {
                if !inNumber {
                    output += "<n>"
                    inNumber = true
                }
                pending = nil
            } else if inNumber, character == "." || character == ",", pending == nil {
                pending = character
            } else {
                if let held = pending {
                    output.append(held)
                    pending = nil
                }
                inNumber = false
                output.append(character)
            }
        }
        if let held = pending { output.append(held) }
        return output
    }

    /// A UUID, a trace or span id, a hash: long hex, or a hex run of at least
    /// eight characters that has both letters and digits.
    private static func isIdentifier(_ segment: String) -> Bool {
        let body = segment.hasPrefix("0x") ? Substring(segment.dropFirst(2)) : Substring(segment)
        let hex = body.filter { $0 != "-" }
        guard hex.count >= 8, hex.allSatisfy(\.isHexDigit) else { return false }
        if segment.hasPrefix("0x") || hex.count >= 16 { return true }
        return hex.contains(where: \.isNumber) && hex.contains(where: \.isLetter)
    }

    private static func isEmail(_ word: String) -> Bool {
        guard let at = word.firstIndex(of: "@"), at != word.startIndex else { return false }
        return word[word.index(after: at)...].contains(".")
    }

    /// Character bigrams with their counts, keyed by the pair of scalars.
    static func bigrams(_ text: String) -> [UInt64: Int] {
        var counts: [UInt64: Int] = [:]
        var previous: UInt32?
        for scalar in text.unicodeScalars {
            if let previous {
                counts[UInt64(previous) << 32 | UInt64(scalar.value), default: 0] += 1
            }
            previous = scalar.value
        }
        return counts
    }

    /// Sørensen–Dice over bigram multisets: 2·shared / (total a + total b),
    /// from 0 (nothing in common) to 1 (the same text).
    static func dice(_ first: [UInt64: Int], _ second: [UInt64: Int]) -> Double {
        let total = first.values.reduce(0, +) + second.values.reduce(0, +)
        guard total > 0 else { return 1 }
        let (smaller, larger) = first.count <= second.count ? (first, second) : (second, first)
        var shared = 0
        for (bigram, count) in smaller {
            if let other = larger[bigram] { shared += min(count, other) }
        }
        return 2 * Double(shared) / Double(total)
    }

    /// How alike two texts are once their variable parts are masked.
    static func similarity(_ first: String, _ second: String) -> Double {
        let left = template(first)
        let right = template(second)
        if left == right { return 1 }
        return dice(bigrams(left), bigrams(right))
    }

    /// The similarity slider, 0…100, as a Dice threshold. Unrelated sentences
    /// share common bigrams and score around 0.1–0.3, so 0 — "even slightly
    /// similar" — starts just above that floor; 100 asks for almost the same text.
    static func threshold(strength: Int) -> Double {
        0.30 + 0.69 * Double(min(max(strength, 0), 100)) / 100
    }
}

// MARK: - Rules

/// Anything a rule can judge: a grouped log line, an incident, a table row, a
/// service. The pane turns each into one of these.
struct MonitorSubject: Sendable {
    var tab: MonitorTab
    var panel: String?
    var source: String?
    var service: String?
    var severity: MonitorSeverity?
    var text: String
    var attributes: [String: String]

    /// What pins and dedupes the item across refreshes and sources.
    let fingerprint: String
    let template: String

    init(
        tab: MonitorTab, panel: String? = nil, source: String? = nil, service: String? = nil,
        severity: MonitorSeverity? = nil, text: String, attributes: [String: String] = [:]
    ) {
        self.tab = tab
        self.panel = panel
        self.source = source
        self.service = service
        self.severity = severity
        self.text = text
        self.attributes = attributes
        self.template = MonitorNoise.template(text)
        self.fingerprint = "\(tab.rawValue)|\(service ?? "")|\(template)"
    }
}

/// What the rules decided for one item.
struct MonitorVerdict: Equatable, Sendable {
    enum Placement: Equatable, Sendable {
        case shown, hidden, pinned
    }

    var placement: Placement = .shown
    var group: String?
    var notifies = false
    /// The rule that hid the item, so "N hidden" can say why.
    var hiddenBy: String?
}

/// Runs a profile's rules over items. Two axes — where an item appears, and
/// whether it may notify — each decided by the first rule that matches on it.
/// Nothing is hidden and nothing notifies unless a rule says so.
struct MonitorRuleEngine: Sendable {
    let rules: [MonitorRule]
    /// The example texts' bigrams, worked out once rather than per item.
    private let exampleBigrams: [String: [UInt64: Int]]

    init(rules: [MonitorRule]) {
        self.rules = rules
        var bigrams: [String: [UInt64: Int]] = [:]
        for rule in rules {
            if let example = rule.match.similarTo {
                bigrams[rule.id] = MonitorNoise.bigrams(MonitorNoise.template(example.text))
            }
        }
        exampleBigrams = bigrams
    }

    func verdict(for subject: MonitorSubject, pinnedItems: Set<String> = []) -> MonitorVerdict {
        var verdict = MonitorVerdict()
        var placed = false
        var notificationDecided = false
        let subjectBigrams = MonitorNoise.bigrams(subject.template)
        for rule in rules {
            if placed, notificationDecided { break }
            let axisDecided = rule.action.isNotification ? notificationDecided : placed
            if axisDecided { continue }
            guard matches(rule, subject, subjectBigrams: subjectBigrams) else { continue }
            switch rule.action {
            case .hide:
                verdict.placement = .hidden
                verdict.hiddenBy = rule.id
                placed = true
            case .show:
                placed = true
            case .pin:
                verdict.placement = .pinned
                placed = true
            case .group:
                verdict.group = rule.group ?? rule.name
                placed = true
            case .notify:
                verdict.notifies = true
                notificationDecided = true
            case .mute:
                notificationDecided = true
            }
        }
        // A pin made by hand outranks a rule that would hide the item.
        if pinnedItems.contains(subject.fingerprint) {
            verdict.placement = .pinned
            verdict.hiddenBy = nil
        }
        return verdict
    }

    func matches(_ rule: MonitorRule, _ subject: MonitorSubject) -> Bool {
        matches(rule, subject, subjectBigrams: MonitorNoise.bigrams(subject.template))
    }

    private func matches(_ rule: MonitorRule, _ subject: MonitorSubject, subjectBigrams: [UInt64: Int]) -> Bool {
        let match = rule.match
        if let tab = match.tab, tab != subject.tab { return false }
        if let panel = match.panel, panel != subject.panel { return false }
        if let source = match.source, source != subject.source { return false }
        if let service = match.service, !Self.glob(service, subject.service) { return false }
        if let minimum = match.minimumSeverity {
            guard let severity = subject.severity, severity >= minimum else { return false }
        }
        if let needle = match.contains, !needle.isEmpty,
           subject.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        for (field, pattern) in match.attributes ?? [:] where !Self.glob(pattern, subject.attributes[field]) {
            return false
        }
        if let example = match.similarTo {
            let score = exampleBigrams[rule.id].map { MonitorNoise.dice($0, subjectBigrams) }
                ?? MonitorNoise.similarity(example.text, subject.text)
            if score < MonitorNoise.threshold(strength: example.strength) { return false }
        }
        return true
    }

    /// Case-insensitive equality, or a prefix when the pattern ends in `*`.
    static func glob(_ pattern: String, _ value: String?) -> Bool {
        guard let value else { return false }
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            return value.lowercased().hasPrefix(pattern.dropLast().lowercased())
        }
        return value.caseInsensitiveCompare(pattern) == .orderedSame
    }
}
