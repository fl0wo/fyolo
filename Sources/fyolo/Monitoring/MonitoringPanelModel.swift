import AppKit
import Combine
import Foundation

// MARK: - Results

enum MonitorPanelContent: Equatable, Sendable {
    case table(MonitorTable)
    case events([MonitorEvent])
    case incidents([MonitorIncident])
    case services([MonitorService])
    case checks([MonitorCheckResult])
}

struct MonitorPanelResult: Equatable, Sendable {
    var content: MonitorPanelContent?
    var error: String?
    var fetchedAt: Date
}

/// One threshold check, evaluated: the worst value across the query's facets.
struct MonitorCheckResult: Identifiable, Equatable, Sendable {
    var check: MonitorCheck
    var value: Double?
    var facet: String?
    var level: MonitorLevel
    var error: String?

    var id: String { check.id }

    static func evaluate(_ check: MonitorCheck, _ result: MonitorQueryResult) -> MonitorCheckResult {
        if let error = result.error {
            return MonitorCheckResult(check: check, value: nil, facet: nil, level: .noData, error: error)
        }
        let below = check.below ?? false
        let skipped: Set<String> = ["beginTimeSeconds", "endTimeSeconds", "timestamp"]
        let points = result.table.rows.compactMap { row -> (Double, String?)? in
            let value = row.values.keys.sorted().lazy
                .filter { !skipped.contains($0) }
                .compactMap { row.number($0) }
                .first
            return value.map { ($0, row.text("facet")) }
        }
        let worst = points.max { below ? $0.0 > $1.0 : $0.0 < $1.0 }
        return MonitorCheckResult(
            check: check, value: worst?.0, facet: worst?.1,
            level: MonitorLevel.of(worst?.0, warn: check.warn, crit: check.crit, below: below), error: nil)
    }
}

/// What the pane has fetched, above the per-project model, so switching tabs or
/// projects redraws from memory and revalidates behind it. Keyed by the
/// rendered query, so a changed variable or edited query never reads a stale
/// answer. Emptied when the connections change.
@MainActor
enum MonitoringCache {
    static var results: [String: MonitorPanelResult] = [:]
    private static var observer: AnyCancellable?

    static func observeConnections() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.publisher(for: MonitoringAuth.connectionsDidChange)
            .receive(on: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { results.removeAll() } }
    }
}

// MARK: - Profile choice

/// Which profile the pane shows: the generated default, one from the library,
/// or the one the project's repository commits.
enum MonitorProfileChoice: Hashable, Sendable {
    case builtIn
    case library(String)
    case repository

    init?(stored: String) {
        if stored == "default" {
            self = .builtIn
        } else if stored == "repository" {
            self = .repository
        } else if stored.hasPrefix("library:") {
            self = .library(String(stored.dropFirst("library:".count)))
        } else {
            return nil
        }
    }

    var stored: String {
        switch self {
        case .builtIn: return "default"
        case .repository: return "repository"
        case .library(let id): return "library:\(id)"
        }
    }
}

/// The profile shared by the pane and the incident watcher, and how a panel
/// finds the connection it reads.
@MainActor
enum Monitoring {
    private static let activeChoiceKey = "monitoring.activeProfile"
    private static let activeRootKey = "monitoring.activeRepositoryRoot"

    /// The last profile picked anywhere: what the watcher notifies from.
    static var activeChoice: MonitorProfileChoice {
        UserDefaults.standard.string(forKey: activeChoiceKey).flatMap(MonitorProfileChoice.init(stored:)) ?? .builtIn
    }

    static func setActive(_ choice: MonitorProfileChoice, projectRoot: String?) {
        UserDefaults.standard.set(choice.stored, forKey: activeChoiceKey)
        if choice == .repository, let projectRoot {
            UserDefaults.standard.set(projectRoot, forKey: activeRootKey)
        }
    }

    static func profile(
        for choice: MonitorProfileChoice, projectRoot: String?, connections: [MonitorConnection]
    ) -> MonitoringProfile? {
        switch choice {
        case .builtIn:
            return NewRelicDefaults.profile(for: connections)
        case .library(let id):
            return MonitoringLibrary.profiles().first { $0.id == id }
        case .repository:
            guard let root = projectRoot ?? UserDefaults.standard.string(forKey: activeRootKey),
                  case .success(let profile)? = MonitoringLibrary.repositoryProfile(in: root)
            else { return nil }
            return profile
        }
    }

    static func connection(
        for panel: MonitorPanel, in profile: MonitoringProfile, connections: [MonitorConnection]
    ) -> (ref: String, connection: MonitorConnection)? {
        guard let ref = panel.source ?? profile.connectors.first?.ref,
              let requirement = profile.connectors.first(where: { $0.ref == ref }),
              let connection = connections.first(where: { $0.satisfies(requirement) })
        else { return nil }
        return (ref, connection)
    }

    static func values(_ profile: MonitoringProfile, _ overlay: MonitoringOverlay) -> [String: String] {
        var values: [String: String] = [:]
        for variable in profile.variables {
            let picked = overlay.values[variable.name]
            values[variable.name] = picked.flatMap { variable.options.isEmpty || variable.options.contains($0) ? $0 : nil }
                ?? variable.defaultValue
        }
        return values
    }

    static func subject(_ incident: MonitorIncident, panel: String?) -> MonitorSubject {
        var attributes = ["priority": incident.priority.rawValue, "state": incident.state.rawValue]
        attributes["condition"] = incident.condition
        attributes["policy"] = incident.policy
        return MonitorSubject(
            tab: .incidents, panel: panel, source: incident.source, service: incident.service,
            severity: incident.priority.severity, text: incident.title, attributes: attributes)
    }

    static func subject(_ group: MonitorEventGroup, tab: MonitorTab, panel: String) -> MonitorSubject {
        MonitorSubject(
            tab: tab, panel: panel, source: group.latest.source, service: group.latest.service,
            severity: group.severity, text: group.latest.message, attributes: group.latest.attributes)
    }

    static func subject(_ event: MonitorEvent, tab: MonitorTab, panel: String) -> MonitorSubject {
        MonitorSubject(
            tab: tab, panel: panel, source: event.source, service: event.service, severity: event.severity,
            text: event.message, attributes: event.attributes)
    }

    static func subject(_ row: MonitorRow, table: MonitorTable, tab: MonitorTab, panel: String, source: String?) -> MonitorSubject {
        var attributes: [String: String] = [:]
        for (key, value) in row.values {
            if let text = value.text { attributes[key] = text }
        }
        for (name, value) in zip(table.facetNames, row.facets) { attributes[name] = value }
        let service = attributes["service.name"] ?? attributes["entity.name"] ?? attributes["appName"]
        return MonitorSubject(
            tab: tab, panel: panel, source: source, service: service,
            text: row.text("facet") ?? row.fields.compactMap { row.text($0) }.joined(separator: " "),
            attributes: attributes)
    }

    static func subject(_ service: MonitorService, tab: MonitorTab, panel: String) -> MonitorSubject {
        let severity: MonitorSeverity? = switch service.health {
        case .critical: .critical
        case .warning: .warning
        case .healthy: .info
        case .unknown: nil
        }
        return MonitorSubject(
            tab: tab, panel: panel, source: service.source, service: service.name, severity: severity,
            text: service.name, attributes: ["health": service.health.rawValue])
    }
}

// MARK: - Rule outcome

/// An item with what the rules made of it.
struct MonitorSifted<Item>: Identifiable {
    var item: Item
    var subject: MonitorSubject
    var verdict: MonitorVerdict
    let id: String
}

struct MonitorSifting<Item> {
    var shown: [MonitorSifted<Item>] = []
    var hidden: [MonitorSifted<Item>] = []
}

// MARK: - Pane state

/// What a detail push can show.
enum MonitorDetail: Equatable {
    case group(MonitorEventGroup, panel: String)
    case event(MonitorEvent, panel: String)
    case incident(MonitorIncident)
    case row(MonitorRow, panel: MonitorPanel)
    case service(MonitorService)
    case check(MonitorCheckResult)
}

/// State for the Monitoring pane: the connections, the chosen profile and its
/// overlay, each panel's latest result, and the rules that sift them. One per
/// project root, since a repository can bring its own profile.
@MainActor
final class MonitoringPanelModel: ObservableObject {
    enum Phase: Equatable {
        case loading, disconnected, ready
    }

    let projectRoot: String?

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var connections: [MonitorConnection] = []
    @Published private(set) var libraryProfiles: [MonitoringProfile] = []
    @Published private(set) var repositoryProfile: MonitoringProfile?
    @Published private(set) var repositoryError: String?
    @Published private(set) var choice: MonitorProfileChoice = .builtIn
    @Published private(set) var profile = MonitoringProfile(id: NewRelicDefaults.profileID, name: "")
    @Published private(set) var overlay = MonitoringOverlay(profileID: NewRelicDefaults.profileID)
    @Published private(set) var results: [String: MonitorPanelResult] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var engine = MonitorRuleEngine(rules: [])
    @Published var tab: MonitorTab = .observability
    @Published var detail: MonitorDetail?
    /// Panels whose rule-hidden items are shown anyway, dimmed.
    @Published var revealedPanels: Set<String> = []
    @Published var showsHiddenPanels = false
    @Published var filterText = ""
    @Published var message: String?

    // Connecting
    @Published private(set) var isConnecting = false
    @Published private(set) var connectError: String?
    @Published private(set) var pendingAccounts: [NerdGraphClient.Account] = []
    private var pendingKey: (key: String, region: NewRelicRegion, email: String?)?

    /// Bumped whenever what the panels ask for changes, so an answer to the
    /// old question is dropped instead of drawn.
    private var generation = 0
    private var observers: [AnyCancellable] = []

    static let defaultRefreshSeconds = 30

    init(projectRoot: String?) {
        self.projectRoot = projectRoot
        MonitoringCache.observeConnections()
        observers.append(
            NotificationCenter.default.publisher(for: MonitoringAuth.connectionsDidChange)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        Task { await self.start() }
                    }
                })
    }

    // MARK: Loading

    func start() async {
        connections = MonitoringAuth.connections()
        libraryProfiles = MonitoringLibrary.profiles()
        repositoryProfile = nil
        repositoryError = nil
        if let projectRoot {
            switch MonitoringLibrary.repositoryProfile(in: projectRoot) {
            case .success(let profile)?: repositoryProfile = profile
            case .failure(let error)?: repositoryError = error.localizedDescription
            case nil: break
            }
        }
        guard !connections.isEmpty || repositoryProfile != nil || !libraryProfiles.isEmpty else {
            phase = .disconnected
            return
        }
        var picked: MonitorProfileChoice?
        if let projectRoot, let stored = await GitService.monitoringProfile(in: projectRoot) {
            picked = MonitorProfileChoice(stored: stored)
        }
        if picked == nil, repositoryProfile != nil { picked = .repository }
        apply(picked ?? Monitoring.activeChoice, remember: false)
        phase = connections.isEmpty ? .disconnected : .ready
        await refresh(force: false)
    }

    private func apply(_ choice: MonitorProfileChoice, remember: Bool) {
        let resolved: MonitoringProfile? = switch choice {
        case .repository: repositoryProfile
        case .library(let id): libraryProfiles.first { $0.id == id }
        case .builtIn: NewRelicDefaults.profile(for: connections)
        }
        guard let resolved else {
            if choice != .builtIn { apply(.builtIn, remember: false) }
            return
        }
        self.choice = choice
        profile = resolved
        overlay = MonitoringLibrary.overlay(for: resolved.id)
        engine = MonitorRuleEngine(rules: resolved.effectiveRules(with: overlay))
        detail = nil
        generation += 1
        results = [:]
        Monitoring.setActive(choice, projectRoot: projectRoot)
        if remember, let projectRoot {
            Task { await GitService.setMonitoringProfile(choice.stored, in: projectRoot) }
        }
    }

    func choose(_ choice: MonitorProfileChoice) {
        apply(choice, remember: true)
        Task { await refresh(force: false) }
    }

    var values: [String: String] { Monitoring.values(profile, overlay) }

    /// Connectors this profile names that no connection here satisfies.
    var missingConnectors: [MonitorConnectorRequirement] {
        profile.connectors.filter { requirement in !connections.contains { $0.satisfies(requirement) } }
    }

    func placedPanels(_ tab: MonitorTab) -> [MonitorPlacedPanel] {
        profile.placedPanels(in: tab, overlay: overlay)
    }

    // MARK: Fetching

    private struct FetchSpec: Sendable {
        enum Work: Sendable {
            case queries([String])
            case incidents(filter: String?, minutes: Int)
            case services(filter: String?)
            case failure(String)
        }

        let panel: MonitorPanel
        let key: String
        let ref: String?
        let source: NewRelicSource?
        let work: Work
    }

    private func spec(for panel: MonitorPanel) -> FetchSpec {
        let resolved = Monitoring.connection(for: panel, in: profile, connections: connections)
        let source = resolved.map { NewRelicSource(connection: $0.connection, ref: $0.ref) }
        let render = { (text: String) throws -> String in
            try MonitorQueryTemplate.render(text, variables: self.profile.variables, values: self.values)
        }
        var work: FetchSpec.Work
        do {
            switch panel.kind {
            case .stat?, .table?, .events?:
                guard let query = panel.query else { throw MonitorPanelError.noQuery }
                work = .queries([try render(query)])
            case .checks?:
                work = .queries(try (panel.checks ?? []).map { try render($0.query) })
            case .incidents?:
                work = .incidents(
                    filter: try panel.filter.map(render),
                    minutes: MonitorQueryTemplate.windowMinutes(variables: profile.variables, values: values))
            case .services?:
                work = .services(filter: try panel.filter.map(render))
            case nil:
                throw MonitorPanelError.unsupported(panel.kindName)
            }
        } catch {
            work = .failure(error.localizedDescription)
        }
        if source == nil {
            // A query error says more than "not connected"; otherwise the missing
            // connection is the reason.
            if case .failure = work {} else {
                work = .failure(MonitorPanelError.noConnection(panel.source ?? "").localizedDescription)
            }
        }
        let identity: String = switch work {
        case .queries(let queries): queries.joined(separator: "\u{1F}")
        case .incidents(let filter, let minutes): "incidents|\(filter ?? "")|\(minutes)"
        case .services(let filter): "services|\(filter ?? "")"
        case .failure(let message): "failure|\(message)"
        }
        return FetchSpec(
            panel: panel, key: "\(resolved?.connection.id ?? "")|\(panel.kindName)|\(identity)",
            ref: resolved?.ref, source: source, work: work)
    }

    /// The tab's visible panels, plus every incident panel so the tab badge
    /// stays honest wherever the person is.
    private func panelsToFetch() -> [MonitorPanel] {
        var panels = placedPanels(tab).filter { !$0.isHidden && !$0.isCollapsed }.map(\.panel)
        if tab != .incidents {
            panels += placedPanels(.incidents).filter { !$0.isHidden && $0.panel.kind == .incidents }.map(\.panel)
        }
        return panels
    }

    func refresh(force: Bool) async {
        guard phase == .ready else { return }
        let specs = panelsToFetch().map(spec(for:))
        var due: [FetchSpec] = []
        let now = Date()
        for spec in specs {
            if case .failure(let message) = spec.work {
                results[spec.panel.id] = MonitorPanelResult(content: nil, error: message, fetchedAt: now)
                continue
            }
            let cached = MonitoringCache.results[spec.key]
            if let cached { results[spec.panel.id] = cached }
            let interval = Double(spec.panel.refreshSeconds ?? Self.defaultRefreshSeconds)
            if force || cached.map({ now.timeIntervalSince($0.fetchedAt) >= interval }) ?? true {
                due.append(spec)
            }
        }
        guard !due.isEmpty else { return }
        let generation = self.generation
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }

        // Every query bound for one account goes out together, so the tab costs
        // as few round trips as the batch size allows.
        var byAccount: [String: [FetchSpec]] = [:]
        var builtIns: [FetchSpec] = []
        for spec in due {
            if case .queries = spec.work {
                byAccount[spec.key.components(separatedBy: "|").first ?? "", default: []].append(spec)
            } else {
                builtIns.append(spec)
            }
        }
        let tab = self.tab
        await withTaskGroup(of: [(FetchSpec, MonitorPanelResult)].self) { group in
            for specs in byAccount.values {
                guard let source = specs.first?.source else { continue }
                group.addTask {
                    var flat: [String] = []
                    for spec in specs { if case .queries(let queries) = spec.work { flat += queries } }
                    let answers = await source.run(flat)
                    var offset = 0
                    return specs.map { spec in
                        guard case .queries(let queries) = spec.work else { return (spec, .init(content: nil, error: nil, fetchedAt: Date())) }
                        let slice = Array(answers[offset..<min(offset + queries.count, answers.count)])
                        offset += queries.count
                        return (spec, Self.result(for: spec, slice, tab: tab))
                    }
                }
            }
            for spec in builtIns {
                guard let source = spec.source else { continue }
                group.addTask {
                    do {
                        switch spec.work {
                        case .incidents(let filter, let minutes):
                            let incidents = try await source.incidents(filter: filter, sinceMinutes: minutes)
                            return [(spec, .init(content: .incidents(incidents), error: nil, fetchedAt: Date()))]
                        case .services(let filter):
                            let services = try await source.services(filter: filter)
                            return [(spec, .init(content: .services(services), error: nil, fetchedAt: Date()))]
                        case .queries, .failure:
                            return []
                        }
                    } catch {
                        return [(spec, .init(content: nil, error: error.localizedDescription, fetchedAt: Date()))]
                    }
                }
            }
            for await batch in group {
                guard generation == self.generation else { continue }
                for (spec, result) in batch {
                    // A failed refresh keeps the last good answer on screen, with the error beside it.
                    var stored = result
                    if result.error != nil, let previous = MonitoringCache.results[spec.key]?.content {
                        stored.content = previous
                    }
                    MonitoringCache.results[spec.key] = stored
                    results[spec.panel.id] = stored
                }
            }
        }
    }

    private nonisolated static func result(
        for spec: FetchSpec, _ answers: [MonitorQueryResult], tab: MonitorTab
    ) -> MonitorPanelResult {
        let now = Date()
        let panel = spec.panel
        switch panel.kind {
        case .checks?:
            let checks = zip(panel.checks ?? [], answers).map { MonitorCheckResult.evaluate($0, $1) }
                .sorted { $0.level < $1.level }
            return MonitorPanelResult(content: .checks(checks), error: nil, fetchedAt: now)
        case .events?:
            guard let answer = answers.first else { return .init(content: nil, error: nil, fetchedAt: now) }
            if let error = answer.error { return .init(content: nil, error: error, fetchedAt: now) }
            let events = NewRelicMapping.events(answer.table, map: panel.map, source: spec.ref ?? "", panel: panel.id)
            return MonitorPanelResult(content: .events(events), error: nil, fetchedAt: now)
        default:
            guard let answer = answers.first else { return .init(content: nil, error: nil, fetchedAt: now) }
            if let error = answer.error { return .init(content: nil, error: error, fetchedAt: now) }
            return MonitorPanelResult(content: .table(answer.table), error: nil, fetchedAt: now)
        }
    }

    // MARK: Sifting

    private var pinnedItems: Set<String> { Set(overlay.pinnedItems) }

    /// Runs the rules and the filter field over a panel's items: shown first
    /// (pinned at the top, grouped ones last under their heading), hidden apart.
    func sift<Item>(_ items: [Item], subject: (Item) -> MonitorSubject) -> MonitorSifting<Item> {
        let needle = filterText.trimmingCharacters(in: .whitespaces)
        let pinned = pinnedItems
        var sifting = MonitorSifting<Item>()
        var pinnedShown: [MonitorSifted<Item>] = []
        var plain: [MonitorSifted<Item>] = []
        var grouped: [MonitorSifted<Item>] = []
        for (index, item) in items.enumerated() {
            let subject = subject(item)
            if !needle.isEmpty, !Self.matches(needle, subject) { continue }
            let verdict = engine.verdict(for: subject, pinnedItems: pinned)
            let sifted = MonitorSifted(item: item, subject: subject, verdict: verdict, id: "\(index)|\(subject.fingerprint)")
            switch verdict.placement {
            case .hidden: sifting.hidden.append(sifted)
            case .pinned: pinnedShown.append(sifted)
            case .shown: if verdict.group == nil { plain.append(sifted) } else { grouped.append(sifted) }
            }
        }
        // A stable sort keeps each group's items in the panel's own order.
        let byGroup = grouped.enumerated().sorted {
            let left = $0.element.verdict.group ?? "", right = $1.element.verdict.group ?? ""
            return left == right ? $0.offset < $1.offset : left.localizedStandardCompare(right) == .orderedAscending
        }.map(\.element)
        sifting.shown = pinnedShown + plain + byGroup
        return sifting
    }

    private static func matches(_ needle: String, _ subject: MonitorSubject) -> Bool {
        let haystacks = [subject.text, subject.service ?? ""] + Array(subject.attributes.values)
        return haystacks.contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The open incidents across every visible incident panel, after rules —
    /// the Incidents tab's badge.
    var openIncidentCount: Int {
        incidentFeed().shown.filter { $0.item.isOpen }.count
    }

    /// Every visible incident panel's incidents as one feed, deduplicated.
    func incidentFeed() -> MonitorSifting<MonitorIncident> {
        var seen = Set<String>()
        var incidents: [(MonitorIncident, String)] = []
        for placed in placedPanels(.incidents) where !placed.isHidden && placed.panel.kind == .incidents {
            guard case .incidents(let list)? = results[placed.panel.id]?.content else { continue }
            for incident in list where seen.insert(incident.id).inserted {
                incidents.append((incident, placed.panel.id))
            }
        }
        let sorted = NewRelicMapping.sortedIncidents(incidents.map(\.0))
        let panelOf = Dictionary(incidents.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
        return sift(sorted) { Monitoring.subject($0, panel: panelOf[$0.id]) }
    }

    /// Items currently on screen in this tab, as rule subjects — what the rule
    /// sheet previews a rule against.
    func currentSubjects(in tab: MonitorTab) -> [MonitorSubject] {
        var subjects: [MonitorSubject] = []
        for placed in placedPanels(tab) where !placed.isHidden {
            let panel = placed.panel
            switch results[panel.id]?.content {
            case .events(let events)?:
                if panel.group == true {
                    subjects += MonitorEventGroup.grouping(events).map { Monitoring.subject($0, tab: tab, panel: panel.id) }
                } else {
                    subjects += events.map { Monitoring.subject($0, tab: tab, panel: panel.id) }
                }
            case .table(let table)?:
                subjects += table.rows.map {
                    Monitoring.subject($0, table: table, tab: tab, panel: panel.id, source: panel.source)
                }
            case .incidents(let incidents)?:
                subjects += incidents.map { Monitoring.subject($0, panel: panel.id) }
            case .services(let services)?:
                subjects += services.map { Monitoring.subject($0, tab: tab, panel: panel.id) }
            case .checks?, nil:
                break
            }
        }
        return subjects
    }

    // MARK: Overlay

    private func changeOverlay(refetch: Bool = false, _ change: (inout MonitoringOverlay) -> Void) {
        change(&overlay)
        MonitoringLibrary.save(overlay)
        engine = MonitorRuleEngine(rules: profile.effectiveRules(with: overlay))
        if refetch {
            generation += 1
            Task { await refresh(force: false) }
        }
    }

    func setValue(_ value: String, for variable: String) {
        changeOverlay(refetch: true) { $0.values[variable] = value }
    }

    func setHidden(_ hidden: Bool, panel: String) {
        changeOverlay(refetch: !hidden) { $0.update(panel) { $0.hidden = hidden } }
    }

    func setCollapsed(_ collapsed: Bool, panel: String) {
        changeOverlay(refetch: !collapsed) { $0.update(panel) { $0.collapsed = collapsed } }
    }

    func setPinned(_ pinned: Bool, panel: String) {
        changeOverlay { $0.update(panel) { $0.pinned = pinned } }
    }

    func move(_ panel: String, by offset: Int, in tab: MonitorTab) {
        var ids = placedPanels(tab).map(\.id)
        guard let index = ids.firstIndex(of: panel) else { return }
        let target = min(max(index + offset, 0), ids.count - 1)
        guard target != index else { return }
        ids.remove(at: index)
        ids.insert(panel, at: target)
        changeOverlay { $0.order[tab.rawValue] = ids }
    }

    func togglePin(item fingerprint: String) {
        changeOverlay { overlay in
            if let index = overlay.pinnedItems.firstIndex(of: fingerprint) {
                overlay.pinnedItems.remove(at: index)
            } else {
                overlay.pinnedItems.append(fingerprint)
            }
        }
    }

    func isPinned(_ fingerprint: String) -> Bool { overlay.pinnedItems.contains(fingerprint) }

    /// A personal rule, placed first so it outranks every earlier one. A new
    /// notify rule counts what is already open as told — the person is looking
    /// at it as they make the rule.
    func addRule(_ rule: MonitorRule) {
        changeOverlay { $0.rules.insert(rule, at: 0) }
        if rule.action == .notify {
            let open = incidentFeed().shown.map(\.item).filter(\.isOpen)
            MonitoringIncidentWatcher.shared.markNotified(open.filter {
                engine.matches(rule, Monitoring.subject($0, panel: nil))
            }.map(\.id))
        }
    }

    func removeRule(id: String) {
        changeOverlay { $0.rules.removeAll { $0.id == id } }
    }

    func dismissNoiseHint() {
        changeOverlay { $0.dismissedNoiseHint = true }
    }

    // MARK: Profile edits

    /// Changes the profile itself — a panel's query, a new panel. The generated
    /// default becomes the person's own copy first; a repository profile is
    /// written back to the repository, where it is reviewed and committed like
    /// any other change.
    func editProfile(_ change: (inout MonitoringProfile) -> Void) {
        var edited = profile
        change(&edited)
        do {
            switch choice {
            case .builtIn:
                let id = uniqueLibraryID("my-monitoring")
                edited.id = id
                edited.name = localized("My Profile")
                var moved = overlay
                moved.profileID = id
                MonitoringLibrary.save(moved)
                try MonitoringLibrary.save(edited)
                libraryProfiles = MonitoringLibrary.profiles()
                apply(.library(id), remember: true)
            case .library:
                try MonitoringLibrary.save(edited)
                libraryProfiles = MonitoringLibrary.profiles()
                profile = edited
            case .repository:
                guard let projectRoot else { return }
                try writeRepositoryProfile(edited, root: projectRoot)
                repositoryProfile = edited
                profile = edited
            }
            engine = MonitorRuleEngine(rules: profile.effectiveRules(with: overlay))
            generation += 1
            Task { await refresh(force: false) }
        } catch {
            message = localized("Couldn’t save the profile: \(error.localizedDescription)")
        }
    }

    private func uniqueLibraryID(_ base: String) -> String {
        let taken = Set(libraryProfiles.map(\.id))
        var id = base
        var number = 2
        while taken.contains(id) {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }

    func deleteCurrentProfile() {
        guard case .library(let id) = choice else { return }
        MonitoringLibrary.deleteProfile(id: id)
        libraryProfiles = MonitoringLibrary.profiles()
        choose(repositoryProfile == nil ? .builtIn : .repository)
    }

    // MARK: Sharing

    /// Writes the profile for a teammate: no keys ever, and with `includingMine`
    /// the person's arrangement and rules folded in.
    func export(to url: URL, includingMine: Bool) {
        let shared = includingMine ? profile.folding(overlay) : profile
        do {
            try MonitoringLibrary.encode(shared).write(to: url, options: .atomic)
        } catch {
            message = localized("Couldn’t export: \(error.localizedDescription)")
        }
    }

    /// Adds a profile file to the library. One with an id already there
    /// replaces it — that is how a team's updated profile arrives — and the
    /// person's overlay for it stays.
    func importProfile(from url: URL) {
        do {
            let imported = try MonitoringLibrary.decode(Data(contentsOf: url))
            try MonitoringLibrary.save(imported)
            libraryProfiles = MonitoringLibrary.profiles()
            choose(.library(imported.id))
            if !missingConnectors.isEmpty {
                message = localized("Imported “\(imported.name)”. Connect the accounts it names to fill it in.")
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Commits-ready: the profile, with this person's arrangement folded in, at
    /// `.fyolo/monitoring.json` in the project.
    func shareToRepository() {
        guard let projectRoot else { return }
        do {
            let shared = profile.folding(overlay)
            try writeRepositoryProfile(shared, root: projectRoot)
            repositoryProfile = shared
            message = localized("Saved to \(MonitoringLibrary.repositoryPath). Commit it to share it with the team.")
        } catch {
            message = localized("Couldn’t save to the repository: \(error.localizedDescription)")
        }
    }

    private func writeRepositoryProfile(_ profile: MonitoringProfile, root: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(MonitoringLibrary.repositoryPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MonitoringLibrary.encode(profile).write(to: url, options: .atomic)
    }

    /// The profile as a file the person can open in an editor: the library copy,
    /// or the repository's own.
    func profileFileURL() -> URL? {
        switch choice {
        case .builtIn:
            return nil
        case .library(let id):
            return MonitoringLibrary.directory
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(MonitoringLibrary.fileName(id))
        case .repository:
            return projectRoot.map {
                URL(fileURLWithPath: $0).appendingPathComponent(MonitoringLibrary.repositoryPath)
            }
        }
    }

    // MARK: Connecting

    /// Checks a pasted key. One readable account connects straight away; more
    /// than one waits for `connect(account:)`.
    func check(apiKey: String, region: NewRelicRegion) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }
        do {
            let identity = try await NerdGraphClient(apiKey: key, region: region).identity()
            guard !identity.accounts.isEmpty else {
                connectError = localized("This key can’t read any account.")
                return
            }
            pendingKey = (key, region, identity.email)
            if identity.accounts.count == 1, let only = identity.accounts.first {
                connect(account: only)
            } else {
                pendingAccounts = identity.accounts
            }
        } catch {
            connectError = error.localizedDescription
        }
    }

    func connect(account: NerdGraphClient.Account) {
        guard let pending = pendingKey else { return }
        MonitoringAuth.add(MonitorConnection(
            type: .newRelic, apiKey: pending.key, accountID: account.id, accountName: account.name,
            region: pending.region, userEmail: pending.email))
        pendingKey = nil
        pendingAccounts = []
    }

    func cancelConnecting() {
        pendingKey = nil
        pendingAccounts = []
        connectError = nil
    }

    func disconnect(_ connection: MonitorConnection) {
        MonitoringAuth.remove(id: connection.id)
    }
}

enum MonitorPanelError: LocalizedError {
    case noQuery
    case unsupported(String)
    case noConnection(String)

    var errorDescription: String? {
        switch self {
        case .noQuery: return localized("This panel has no query.")
        case .unsupported(let kind):
            return localized("“\(kind)” panels need a newer fyolo.")
        case .noConnection(let ref):
            return ref.isEmpty
                ? localized("No connected account matches this profile.")
                : localized("No connected account matches “\(ref)”.")
        }
    }
}

// MARK: - Incident watcher

/// Notifies about new incidents that a `notify` rule asks for, even with the
/// pane closed. Runs only while such a rule exists, once a minute; each
/// incident notifies once.
@MainActor
final class MonitoringIncidentWatcher {
    static let shared = MonitoringIncidentWatcher()

    private static let notifiedKey = "monitoring.notifiedIncidents"
    private static let interval: Duration = .seconds(60)
    private static let rememberedLimit = 500

    private var task: Task<Void, Never>?
    private var notified: [String]

    private init() {
        notified = UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? []
    }

    func start(isEnabled: @escaping @MainActor () -> Bool) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if isEnabled() { await self?.check() }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func markNotified(_ ids: [String]) {
        for id in ids where !notified.contains(id) { notified.append(id) }
        if notified.count > Self.rememberedLimit { notified.removeFirst(notified.count - Self.rememberedLimit) }
        UserDefaults.standard.set(notified, forKey: Self.notifiedKey)
    }

    private func check() async {
        let connections = MonitoringAuth.connections()
        guard !connections.isEmpty,
              let profile = Monitoring.profile(for: Monitoring.activeChoice, projectRoot: nil, connections: connections)
        else { return }
        let overlay = MonitoringLibrary.overlay(for: profile.id)
        let rules = profile.effectiveRules(with: overlay)
        guard rules.contains(where: { $0.action == .notify }) else { return }
        let engine = MonitorRuleEngine(rules: rules)
        let values = Monitoring.values(profile, overlay)
        let minutes = MonitorQueryTemplate.windowMinutes(variables: profile.variables, values: values)
        for placed in profile.placedPanels(in: .incidents, overlay: overlay)
        where !placed.isHidden && placed.panel.kind == .incidents {
            guard let resolved = Monitoring.connection(for: placed.panel, in: profile, connections: connections) else { continue }
            let source = NewRelicSource(connection: resolved.connection, ref: resolved.ref)
            let incidents: [MonitorIncident]
            do {
                let filter = try placed.panel.filter.map {
                    try MonitorQueryTemplate.render($0, variables: profile.variables, values: values)
                }
                incidents = try await source.incidents(filter: filter, sinceMinutes: minutes)
            } catch {
                Log.monitoring.error("incident check failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            for incident in incidents where incident.isOpen && !notified.contains(incident.id) {
                guard engine.verdict(for: Monitoring.subject(incident, panel: placed.panel.id)).notifies else { continue }
                markNotified([incident.id])
                TaskNotificationCenter.shared.postManual(
                    title: "\(incident.priority.rawValue.capitalized): \(incident.title)",
                    body: [incident.service, incident.condition].compactMap { $0 }.joined(separator: " · "),
                    project: nil, session: nil)
            }
        }
    }
}
