import Foundation

// MARK: - Profile

/// A Monitoring layout: which backends it needs, the variables its queries
/// share, the panels of each tab in order, and the team's noise rules. Holds no
/// secret, so it is the file a team exports, imports, or commits to a repo as
/// `.fyolo/monitoring.json`. What one person changes on top of it lives in a
/// `MonitoringOverlay`, so a newer team file never wipes it out.
struct MonitoringProfile: Codable, Equatable, Sendable, Identifiable {
    /// The format this build writes and the newest it reads.
    static let formatVersion = 1

    var formatVersion: Int
    var id: String
    var name: String
    var connectors: [MonitorConnectorRequirement]
    var variables: [MonitorVariable]
    var observability: [MonitorPanel]
    var metrics: [MonitorPanel]
    var incidents: [MonitorPanel]
    var rules: [MonitorRule]

    init(
        id: String, name: String, connectors: [MonitorConnectorRequirement] = [],
        variables: [MonitorVariable] = [], observability: [MonitorPanel] = [],
        metrics: [MonitorPanel] = [], incidents: [MonitorPanel] = [], rules: [MonitorRule] = []
    ) {
        self.formatVersion = Self.formatVersion
        self.id = id
        self.name = name
        self.connectors = connectors
        self.variables = variables
        self.observability = observability
        self.metrics = metrics
        self.incidents = incidents
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "fyoloMonitoring"
        case id, name, connectors, variables, observability, metrics, incidents, rules
    }

    /// Everything but the id is optional, so a hand-written file can be short.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.formatVersion
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        connectors = try container.decodeIfPresent([MonitorConnectorRequirement].self, forKey: .connectors) ?? []
        variables = try container.decodeIfPresent([MonitorVariable].self, forKey: .variables) ?? []
        observability = try container.decodeIfPresent([MonitorPanel].self, forKey: .observability) ?? []
        metrics = try container.decodeIfPresent([MonitorPanel].self, forKey: .metrics) ?? []
        incidents = try container.decodeIfPresent([MonitorPanel].self, forKey: .incidents) ?? []
        rules = try container.decodeIfPresent([MonitorRule].self, forKey: .rules) ?? []
    }

    func panels(in tab: MonitorTab) -> [MonitorPanel] {
        switch tab {
        case .observability: return observability
        case .metrics: return metrics
        case .incidents: return incidents
        }
    }

    mutating func setPanels(_ panels: [MonitorPanel], in tab: MonitorTab) {
        switch tab {
        case .observability: observability = panels
        case .metrics: metrics = panels
        case .incidents: incidents = panels
        }
    }

    var allPanels: [MonitorPanel] { observability + metrics + incidents }
}

/// A backend the profile's panels read, named by the `ref` panels use. Carries
/// what tells a teammate's connection apart (the account), never a key.
struct MonitorConnectorRequirement: Codable, Equatable, Sendable, Identifiable {
    var ref: String
    var type: MonitorConnectorType
    var accountID: Int?
    var region: String?

    var id: String { ref }

    enum CodingKeys: String, CodingKey {
        case ref, type
        case accountID = "accountId"
        case region
    }
}

enum MonitorConnectorType: String, Codable, Sendable {
    case newRelic = "newrelic"

    var title: String {
        switch self {
        case .newRelic: return "New Relic"
        }
    }
}

// MARK: - Variables

/// A value the queries share, picked from the pane's header: the environment,
/// the service, the time window. Typed so a value can never break a query.
struct MonitorVariable: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// Inserted as a quoted, escaped literal: `{{service}}` → `'checkout'`.
        case string
        /// A window like `1h`, inserted as `60 minutes ago`.
        case duration
    }

    var name: String
    var title: String?
    var kind: Kind
    var options: [String]
    var defaultValue: String

    var id: String { name }

    init(name: String, title: String? = nil, kind: Kind, options: [String] = [], defaultValue: String) {
        self.name = name
        self.title = title
        self.kind = kind
        self.options = options
        self.defaultValue = defaultValue
    }

    enum CodingKeys: String, CodingKey {
        case name, title
        case kind = "type"
        case options
        case defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        let kindName = try container.decodeIfPresent(String.self, forKey: .kind) ?? Kind.string.rawValue
        kind = Kind(rawValue: kindName) ?? .string
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue) ?? options.first ?? ""
    }
}

/// `15m`, `1h`, `7d` → minutes.
enum MonitorDuration {
    static func minutes(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last, let amount = Int(trimmed.dropLast()), amount > 0 else { return nil }
        switch unit {
        case "m": return amount
        case "h": return amount * 60
        case "d": return amount * 1440
        case "w": return amount * 10080
        default: return nil
        }
    }
}

enum MonitorQueryError: LocalizedError, Equatable {
    case unknownVariable(String)
    case invalidDuration(variable: String, value: String)

    var errorDescription: String? {
        switch self {
        case .unknownVariable(let name):
            return localized("The query uses {{\(name)}}, which this profile doesn’t define.")
        case .invalidDuration(let name, let value):
            return localized("“\(value)” isn’t a window for {{\(name)}}. Use a value like 15m, 1h or 7d.")
        }
    }
}

/// Fills `{{name}}` placeholders in a native query.
///
/// - `{{name}}`: a string becomes a quoted, escaped NRQL literal; a duration
///   becomes `N minutes ago`.
/// - `{{name:raw}}`: the escaped text without quotes, for building a literal
///   (`LIKE '{{service:raw}}-%'`); for a duration, the bare minute count.
enum MonitorQueryTemplate {
    static func render(_ query: String, variables: [MonitorVariable], values: [String: String]) throws -> String {
        var output = ""
        var rest = Substring(query)
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                output += rest[open.lowerBound...]
                return output
            }
            let token = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts.first ?? ""
            let isRaw = parts.count > 1 && parts[1] == "raw"
            guard let variable = variables.first(where: { $0.name == name }) else {
                throw MonitorQueryError.unknownVariable(name)
            }
            let value = values[name] ?? variable.defaultValue
            switch variable.kind {
            case .string:
                output += isRaw ? escape(value) : "'\(escape(value))'"
            case .duration:
                guard let minutes = MonitorDuration.minutes(value) else {
                    throw MonitorQueryError.invalidDuration(variable: name, value: value)
                }
                output += isRaw ? String(minutes) : "\(minutes) minutes ago"
            }
            rest = rest[close.upperBound...]
        }
        output += rest
        return output
    }

    /// NRQL's string escape: backslash, then the single quote.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// The window a panel's built-in fetch (incidents, services) should cover:
    /// the profile's first duration variable, else an hour.
    static func windowMinutes(variables: [MonitorVariable], values: [String: String]) -> Int {
        guard let window = variables.first(where: { $0.kind == .duration }) else { return 60 }
        return MonitorDuration.minutes(values[window.name] ?? window.defaultValue) ?? 60
    }
}

// MARK: - Panels

/// One section of a tab: a query and how to read its answer.
struct MonitorPanel: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// One line of headline numbers from a single-row query.
        case stat
        /// Faceted rows, with columns, sort and thresholds.
        case table
        /// Log lines or errored spans; grouped by message when `group` is set.
        case events
        /// Named threshold checks, worst first.
        case checks
        /// The backend's own incidents, merged across sources.
        case incidents
        /// The backend's own service list and health.
        case services
    }

    var id: String
    var title: String
    /// The kind as written. A kind this build doesn't know is kept, so the
    /// panel survives an export, and shown as unsupported.
    var kindName: String
    var source: String?
    var query: String?
    var columns: [MonitorColumn]?
    var map: MonitorEventMap?
    var group: Bool?
    var sort: String?
    var limit: Int?
    var refreshSeconds: Int?
    /// For `incidents` and `services`: a clause narrowing the built-in fetch.
    var filter: String?
    var checks: [MonitorCheck]?

    var kind: Kind? { Kind(rawValue: kindName) }

    init(
        id: String, title: String, kind: Kind, source: String? = nil, query: String? = nil,
        columns: [MonitorColumn]? = nil, map: MonitorEventMap? = nil, group: Bool? = nil,
        sort: String? = nil, limit: Int? = nil, refreshSeconds: Int? = nil, filter: String? = nil,
        checks: [MonitorCheck]? = nil
    ) {
        self.id = id
        self.title = title
        self.kindName = kind.rawValue
        self.source = source
        self.query = query
        self.columns = columns
        self.map = map
        self.group = group
        self.sort = sort
        self.limit = limit
        self.refreshSeconds = refreshSeconds
        self.filter = filter
        self.checks = checks
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case kindName = "kind"
        case source, query, columns, map, group, sort, limit
        case refreshSeconds = "refresh"
        case filter, checks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        kindName = try container.decodeIfPresent(String.self, forKey: .kindName) ?? Kind.table.rawValue
        source = try container.decodeIfPresent(String.self, forKey: .source)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        columns = try container.decodeIfPresent([MonitorColumn].self, forKey: .columns)
        map = try container.decodeIfPresent(MonitorEventMap.self, forKey: .map)
        group = try container.decodeIfPresent(Bool.self, forKey: .group)
        sort = try container.decodeIfPresent(String.self, forKey: .sort)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        refreshSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshSeconds)
        filter = try container.decodeIfPresent(String.self, forKey: .filter)
        checks = try container.decodeIfPresent([MonitorCheck].self, forKey: .checks)
    }
}

/// One column of a table or one figure of a stat line. `warn` and `crit` color
/// the value; `below` flips them for a value that is bad when low.
struct MonitorColumn: Codable, Equatable, Sendable {
    var field: String
    var title: String?
    var format: MonitorFormat?
    var warn: Double?
    var crit: Double?
    var below: Bool?

    init(
        field: String, title: String? = nil, format: MonitorFormat? = nil,
        warn: Double? = nil, crit: Double? = nil, below: Bool? = nil
    ) {
        self.field = field
        self.title = title
        self.format = format
        self.warn = warn
        self.crit = crit
        self.below = below
    }

    var displayTitle: String { title ?? (field == "facet" ? localized("Name") : field) }

    func level(of value: Double?) -> MonitorLevel {
        MonitorLevel.of(value, warn: warn, crit: crit, below: below ?? false)
    }
}

/// How a value sits against its thresholds.
enum MonitorLevel: Int, Comparable, Sendable {
    case critical, warning, noData, normal, unconfigured

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func of(_ value: Double?, warn: Double?, crit: Double?, below: Bool) -> MonitorLevel {
        guard warn != nil || crit != nil else { return .unconfigured }
        guard let value else { return .noData }
        func breaches(_ threshold: Double?) -> Bool {
            guard let threshold else { return false }
            return below ? value < threshold : value > threshold
        }
        if breaches(crit) { return .critical }
        if breaches(warn) { return .warning }
        return .normal
    }
}

/// Which row fields an `events` panel reads as what. Every field is optional:
/// an unset one is looked for under the names New Relic logs commonly use.
struct MonitorEventMap: Codable, Equatable, Sendable {
    var time: String?
    var severity: String?
    var message: String?
    var service: String?
    var trace: String?
    /// Extra fields to keep on each line, shown in its detail and matchable by rules.
    var attributes: [String]?
    /// The level for rows that carry none — `error` for a query of failed spans.
    var defaultSeverity: MonitorSeverity?

    static let defaultTime = ["timestamp"]
    static let defaultSeverity = ["severity.text", "level", "log.level", "severity.number", "loglevel"]
    static let defaultMessage = ["message", "error.message", "otel.status_description", "name"]
    static let defaultService = ["service.name", "entity.name", "appName"]
    static let defaultTrace = ["trace.id", "traceId"]
}

/// One threshold check in a `checks` panel — a line of the script's Alerts tab.
struct MonitorCheck: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var query: String
    var below: Bool?
    var warn: Double?
    var crit: Double?
    var format: MonitorFormat?
    var runbook: String?

    init(
        id: String, name: String, query: String, below: Bool? = nil, warn: Double? = nil,
        crit: Double? = nil, format: MonitorFormat? = nil, runbook: String? = nil
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.below = below
        self.warn = warn
        self.crit = crit
        self.format = format
        self.runbook = runbook
    }
}

// MARK: - Rules

/// A noise rule: what it matches and what happens to what it matches.
struct MonitorRule: Codable, Equatable, Sendable, Identifiable {
    enum Action: String, Codable, Sendable {
        case hide, show, pin, group, notify, mute

        /// Hide / show / pin / group decide where an item appears; notify / mute
        /// decide whether it may raise a notification. The axes are independent.
        var isNotification: Bool { self == .notify || self == .mute }
    }

    var id: String
    var name: String?
    var match: MonitorRuleMatch
    var action: Action
    /// The heading a `group` rule files its matches under.
    var group: String?

    init(id: String = UUID().uuidString, name: String? = nil, match: MonitorRuleMatch, action: Action, group: String? = nil) {
        self.id = id
        self.name = name
        self.match = match
        self.action = action
        self.group = group
    }
}

/// Every condition set must hold. An empty match matches everything.
struct MonitorRuleMatch: Codable, Equatable, Sendable {
    var tab: MonitorTab?
    var panel: String?
    var source: String?
    /// Exact, case-insensitive; a trailing `*` matches a prefix.
    var service: String?
    var minimumSeverity: MonitorSeverity?
    /// Case-insensitive substring of the item's text.
    var contains: String?
    /// Field → value, each exact or a `*` prefix, like `service`.
    var attributes: [String: String]?
    var similarTo: MonitorSimilarity?

    init(
        tab: MonitorTab? = nil, panel: String? = nil, source: String? = nil, service: String? = nil,
        minimumSeverity: MonitorSeverity? = nil, contains: String? = nil,
        attributes: [String: String]? = nil, similarTo: MonitorSimilarity? = nil
    ) {
        self.tab = tab
        self.panel = panel
        self.source = source
        self.service = service
        self.minimumSeverity = minimumSeverity
        self.contains = contains
        self.attributes = attributes
        self.similarTo = similarTo
    }
}

/// "Things like this": the example text and how alike an item must be, 0
/// (even slightly) to 100 (practically the same text).
struct MonitorSimilarity: Codable, Equatable, Sendable {
    var text: String
    var strength: Int
}

// MARK: - Overlay

/// One person's changes on top of a profile: hidden, collapsed and pinned
/// panels, their order, their own rules (which run before the team's), the
/// variable values last picked, and pinned items. Kept beside the profile and
/// never exported unless asked, so a newer team profile replaces the base and
/// leaves all of this alone.
struct MonitoringOverlay: Codable, Equatable, Sendable {
    struct PanelState: Codable, Equatable, Sendable {
        var hidden: Bool?
        var collapsed: Bool?
        var pinned: Bool?

        var isEmpty: Bool { hidden != true && collapsed != true && pinned != true }
    }

    var profileID: String
    var panels: [String: PanelState] = [:]
    /// Tab → panel ids, as last arranged. Ids the profile no longer has are skipped.
    var order: [String: [String]] = [:]
    var rules: [MonitorRule] = []
    var values: [String: String] = [:]
    var pinnedItems: [String] = []
    var dismissedNoiseHint: Bool?

    init(profileID: String) {
        self.profileID = profileID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(String.self, forKey: .profileID)
        panels = try container.decodeIfPresent([String: PanelState].self, forKey: .panels) ?? [:]
        order = try container.decodeIfPresent([String: [String]].self, forKey: .order) ?? [:]
        rules = try container.decodeIfPresent([MonitorRule].self, forKey: .rules) ?? []
        values = try container.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        pinnedItems = try container.decodeIfPresent([String].self, forKey: .pinnedItems) ?? []
        dismissedNoiseHint = try container.decodeIfPresent(Bool.self, forKey: .dismissedNoiseHint)
    }

    func state(of panelID: String) -> PanelState { panels[panelID] ?? PanelState() }

    mutating func update(_ panelID: String, _ change: (inout PanelState) -> Void) {
        var state = state(of: panelID)
        change(&state)
        panels[panelID] = state.isEmpty ? nil : state
    }
}

/// A panel as the overlay leaves it.
struct MonitorPlacedPanel: Identifiable, Equatable, Sendable {
    var panel: MonitorPanel
    var isHidden: Bool
    var isCollapsed: Bool
    var isPinned: Bool

    var id: String { panel.id }
}

extension MonitoringProfile {
    /// A tab's panels in the order the person sees them: pinned first, then the
    /// overlay's arrangement, then panels the team added since, in team order.
    /// Hidden panels are included, flagged, so "show hidden" can bring them back.
    func placedPanels(in tab: MonitorTab, overlay: MonitoringOverlay) -> [MonitorPlacedPanel] {
        let base = panels(in: tab)
        let byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var ordered: [MonitorPanel] = []
        for id in overlay.order[tab.rawValue] ?? [] {
            if let panel = byID[id], seen.insert(id).inserted { ordered.append(panel) }
        }
        for panel in base where seen.insert(panel.id).inserted {
            ordered.append(panel)
        }
        let placed = ordered.map { panel in
            let state = overlay.state(of: panel.id)
            return MonitorPlacedPanel(
                panel: panel, isHidden: state.hidden == true, isCollapsed: state.collapsed == true,
                isPinned: state.pinned == true)
        }
        return placed.filter(\.isPinned) + placed.filter { !$0.isPinned }
    }

    /// Personal rules first: what someone chose for themselves outranks the team default.
    func effectiveRules(with overlay: MonitoringOverlay) -> [MonitorRule] {
        overlay.rules + rules
    }

    /// The overlay's choices folded into the base, for an export that should
    /// carry one person's arrangement to the team.
    func folding(_ overlay: MonitoringOverlay) -> MonitoringProfile {
        var folded = self
        for tab in MonitorTab.allCases {
            let visible = placedPanels(in: tab, overlay: overlay).filter { !$0.isHidden }.map(\.panel)
            folded.setPanels(visible, in: tab)
        }
        folded.rules = effectiveRules(with: overlay)
        folded.variables = variables.map { variable in
            var updated = variable
            if let value = overlay.values[variable.name] { updated.defaultValue = value }
            return updated
        }
        return folded
    }
}

// MARK: - Library

enum MonitoringLibraryError: LocalizedError {
    case newerFormat(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .newerFormat(let version):
            return localized("This profile was made by a newer fyolo (format \(version)). Update fyolo to open it.")
        case .unreadable(let reason):
            return localized("This isn’t a Monitoring profile fyolo can read: \(reason)")
        }
    }
}

/// Profiles and overlays on disk, under `~/.fyolo/monitoring`: one JSON file
/// per profile in `profiles/`, one per overlay in `overlays/`. Plain files, so
/// they can live in dotfiles like `settings.json`.
enum MonitoringLibrary {
    /// Where a repository keeps the profile its team shares.
    static let repositoryPath = ".fyolo/monitoring.json"

    static var directory: URL {
        AppChannel.homeConfigDirectory.appendingPathComponent("monitoring", isDirectory: true)
    }

    private static var profilesDirectory: URL { directory.appendingPathComponent("profiles", isDirectory: true) }
    private static var overlaysDirectory: URL { directory.appendingPathComponent("overlays", isDirectory: true) }

    static func decode(_ data: Data) throws -> MonitoringProfile {
        let profile: MonitoringProfile
        do {
            profile = try JSONDecoder().decode(MonitoringProfile.self, from: data)
        } catch let error as DecodingError {
            throw MonitoringLibraryError.unreadable(describe(error))
        }
        if profile.formatVersion > MonitoringProfile.formatVersion {
            throw MonitoringLibraryError.newerFormat(profile.formatVersion)
        }
        return profile
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func profiles() -> [MonitoringProfile] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: profilesDirectory, includingPropertiesForKeys: nil)
        } catch {
            // No directory yet is the normal first-run state.
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            do {
                return try decode(Data(contentsOf: file))
            } catch {
                Log.monitoring.error("skipping unreadable profile \(file.path, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(_ profile: MonitoringProfile) throws {
        try write(encode(profile), to: profilesDirectory.appendingPathComponent(fileName(profile.id)))
    }

    static func deleteProfile(id: String) {
        for url in [profilesDirectory.appendingPathComponent(fileName(id)),
                    overlaysDirectory.appendingPathComponent(fileName(id))] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                Log.monitoring.error("removing \(url.path, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
    }

    static func overlay(for profileID: String) -> MonitoringOverlay {
        let url = overlaysDirectory.appendingPathComponent(fileName(profileID))
        guard let data = try? Data(contentsOf: url) else { return MonitoringOverlay(profileID: profileID) }
        do {
            return try JSONDecoder().decode(MonitoringOverlay.self, from: data)
        } catch {
            Log.monitoring.error("unreadable overlay for \(profileID, privacy: .public): \(error, privacy: .public)")
            return MonitoringOverlay(profileID: profileID)
        }
    }

    static func save(_ overlay: MonitoringOverlay) {
        do {
            try write(encode(overlay), to: overlaysDirectory.appendingPathComponent(fileName(overlay.profileID)))
        } catch {
            Log.monitoring.error("saving the overlay for \(overlay.profileID, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// The profile a repository shares, if it commits one. A malformed file is
    /// an error to show, not a silent absence.
    static func repositoryProfile(in projectRoot: String) -> Result<MonitoringProfile, Error>? {
        let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(repositoryPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return .success(try decode(data))
        } catch {
            return .failure(error)
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Profile ids come from files people share, so they are made safe to use
    /// as a file name rather than trusted as one.
    static func fileName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (safe.isEmpty ? "profile" : safe) + ".json"
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return localized("“\(key.stringValue)” is missing at \(path(context.codingPath)).")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return localized("the value at \(path(context.codingPath)) has the wrong type.")
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? localized("the file isn’t valid JSON.")
                : localized("the value at \(path(context.codingPath)) is unreadable.")
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let parts = codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return parts.isEmpty ? "the top level" : String(parts.drop { $0 == "." })
    }
}
