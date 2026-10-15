import Foundation

// MARK: - JSON

/// An untyped JSON value. NRQL rows have no fixed shape — their keys are the
/// query's own aliases — so results stay in this form instead of decoding into
/// structs, and a profile can carry them too.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        if case .string(let value) = self { return Double(value) }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    /// The value as a person reads it; `nil` for null and for structures.
    var text: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return MonitorFormat.plain(value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let values):
            let parts = values.compactMap(\.text)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .null, .object: return nil
        }
    }
}

// MARK: - Vocabulary

/// The three sub-tabs. Every panel and every rule belongs to one of them.
enum MonitorTab: String, Codable, CaseIterable, Sendable {
    case observability, metrics, incidents

    var title: String {
        switch self {
        case .observability: return localized("Observability")
        case .metrics: return localized("Metrics")
        case .incidents: return localized("Incidents")
        }
    }
}

/// One severity ladder for every backend. Log levels, OpenTelemetry severity
/// numbers and incident priorities all land here, so one rule ("error and up")
/// reads the same across sources.
enum MonitorSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case trace, debug, info, warning, error, critical

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Reads the level names the common logging libraries write.
    init?(text: String) {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "trace", "finest", "verbose": self = .trace
        case "debug", "fine", "finer": self = .debug
        case "info", "information", "notice", "informational": self = .info
        case "warn", "warning": self = .warning
        case "error", "err", "severe": self = .error
        case "fatal", "critical", "crit", "alert", "emergency", "emerg", "panic": self = .critical
        default: return nil
        }
    }

    /// OpenTelemetry's `severity.number`: 1–4 trace … 21–24 fatal.
    init(openTelemetryNumber number: Double) {
        switch number {
        case ..<5: self = .trace
        case ..<9: self = .debug
        case ..<13: self = .info
        case ..<17: self = .warning
        case ..<21: self = .error
        default: self = .critical
        }
    }
}

// MARK: - Normalized records

/// One row of a query result. Nested values (`lat: {"95": 0.4}`) are flattened
/// to dotted keys (`lat.95`), so a column names any value with one string.
struct MonitorRow: Equatable, Sendable {
    var facets: [String]
    var values: [String: JSONValue]

    /// `facet` is the joined facet values, the way the row is named.
    func text(_ field: String) -> String? {
        if field == "facet" { return facets.isEmpty ? nil : facets.joined(separator: " · ") }
        return values[field]?.text
    }

    func number(_ field: String) -> Double? { values[field]?.number }

    /// Every key of the row, facet first, for a table with no declared columns.
    var fields: [String] {
        (facets.isEmpty ? [] : ["facet"]) + values.keys.sorted()
    }
}

struct MonitorTable: Equatable, Sendable {
    var facetNames: [String]
    var rows: [MonitorRow]

    static let empty = MonitorTable(facetNames: [], rows: [])
}

/// A log line or an errored span, from any source.
struct MonitorEvent: Identifiable, Equatable, Sendable {
    let id: String
    var time: Date?
    var severity: MonitorSeverity
    var service: String?
    var message: String
    var attributes: [String: String]
    var traceID: String?
    var source: String
    /// The message with its variable parts masked: what groups, dedupes and
    /// compares lines across sources.
    let template: String

    init(
        id: String, time: Date?, severity: MonitorSeverity, service: String?, message: String,
        attributes: [String: String] = [:], traceID: String? = nil, source: String
    ) {
        self.id = id
        self.time = time
        self.severity = severity
        self.service = service
        self.message = message
        self.attributes = attributes
        self.traceID = traceID
        self.source = source
        self.template = MonitorNoise.template(message)
    }

    var fingerprint: String { "\(service ?? "")|\(template)" }
}

/// Lines that say the same thing, counted. Sources merge here: the same error
/// from New Relic and from a later Datadog connector is one group.
struct MonitorEventGroup: Identifiable, Equatable, Sendable {
    var fingerprint: String
    var latest: MonitorEvent
    var count: Int
    var firstSeen: Date?
    var lastSeen: Date?
    var severity: MonitorSeverity
    var sources: [String]

    var id: String { fingerprint }

    /// Most frequent first; ties go to the most recent.
    static func grouping(_ events: [MonitorEvent]) -> [MonitorEventGroup] {
        var groups: [String: MonitorEventGroup] = [:]
        var order: [String] = []
        for event in events {
            let key = event.fingerprint
            if var group = groups[key] {
                group.count += 1
                group.severity = max(group.severity, event.severity)
                if let time = event.time {
                    if (group.lastSeen ?? .distantPast) < time {
                        group.lastSeen = time
                        group.latest = event
                    }
                    if (group.firstSeen ?? .distantFuture) > time { group.firstSeen = time }
                }
                if !group.sources.contains(event.source) { group.sources.append(event.source) }
                groups[key] = group
            } else {
                order.append(key)
                groups[key] = MonitorEventGroup(
                    fingerprint: key, latest: event, count: 1, firstSeen: event.time,
                    lastSeen: event.time, severity: event.severity, sources: [event.source])
            }
        }
        return order.compactMap { groups[$0] }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast)
        }
    }
}

struct MonitorIncident: Identifiable, Equatable, Sendable {
    enum Priority: String, Codable, CaseIterable, Sendable {
        case critical, high, warning, info

        /// New Relic says critical / high / medium / low; others say warning.
        init(text: String?) {
            switch text?.lowercased() {
            case "critical", "p1", "sev1": self = .critical
            case "high", "p2", "sev2": self = .high
            case "medium", "warning", "p3", "sev3": self = .warning
            default: self = .info
            }
        }

        var severity: MonitorSeverity {
            switch self {
            case .critical: return .critical
            case .high: return .error
            case .warning: return .warning
            case .info: return .info
            }
        }
    }

    enum State: String, Codable, Sendable {
        case open, acknowledged, closed
    }

    /// `<source>:<the backend's own id>`, unique across connectors.
    let id: String
    var title: String
    var priority: Priority
    var state: State
    var openedAt: Date?
    var closedAt: Date?
    var service: String?
    var condition: String?
    var policy: String?
    var link: URL?
    var source: String

    var isOpen: Bool { state != .closed }
}

/// A service as its backend's health model sees it — New Relic's entity alert
/// severity, for one.
struct MonitorService: Identifiable, Equatable, Sendable {
    enum Health: String, Sendable {
        case critical, warning, healthy, unknown
    }

    let id: String
    var name: String
    var health: Health
    var isReporting: Bool
    /// Whatever golden numbers the backend has for it, keyed by column field.
    var values: [String: Double]
    var link: URL?
    var source: String
}

// MARK: - Sources

/// What one query asked of a source came back as: a table, or why not.
struct MonitorQueryResult: Equatable, Sendable {
    var table: MonitorTable
    var error: String?

    static func failure(_ message: String) -> MonitorQueryResult {
        MonitorQueryResult(table: .empty, error: message)
    }
}

/// One backend. Queries go in in the backend's own language (NRQL for New
/// Relic) and come out normalized: the shapes above are all the pane knows.
protocol MonitorSource: Sendable {
    /// Every query in as few round trips as the backend allows. One result per
    /// query, in order; a failed query never fails its neighbours.
    func run(_ queries: [String]) async -> [MonitorQueryResult]
    /// Open incidents, and those closed within `sinceMinutes`.
    func incidents(filter: String?, sinceMinutes: Int) async throws -> [MonitorIncident]
    func services(filter: String?) async throws -> [MonitorService]
}

// MARK: - Formatting

/// How a column prints its number. Declared per column in the profile.
enum MonitorFormat: String, Codable, Sendable {
    case number, count, percent, seconds, milliseconds, bytes, money, text

    func string(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        switch self {
        case .count: return Self.compact(value)
        case .percent: return value < 10 ? String(format: "%.2f%%", value) : String(format: "%.1f%%", value)
        case .seconds: return value < 1 ? String(format: "%.0fms", value * 1000) : String(format: "%.2fs", value)
        case .milliseconds: return value < 1000 ? String(format: "%.0fms", value) : String(format: "%.2fs", value / 1000)
        case .bytes: return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
        case .money: return "$" + Self.compact(value)
        case .number, .text: return Self.plain(value)
        }
    }

    /// 1234 → 1.2k, the way a glance wants it.
    static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if magnitude >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if magnitude >= 10_000 { return String(format: "%.0fk", value / 1000) }
        if magnitude >= 1000 { return String(format: "%.1fk", value / 1000) }
        return plain(value)
    }

    static func plain(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return abs(value) < 10 ? String(format: "%.2f", value) : String(format: "%.1f", value)
    }
}
