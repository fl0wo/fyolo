import Foundation

// MARK: - Client

enum NewRelicError: LocalizedError, Equatable {
    case keyRejected
    case status(Int)
    case graphQL(String)
    case decoding
    case network(String)

    var errorDescription: String? {
        switch self {
        case .keyRejected:
            return localized("New Relic rejected the key. Use a User key (NRAK-…) that can read this account.")
        case .status(let code): return localized("New Relic replied with HTTP \(code).")
        case .graphQL(let message): return message
        case .decoding: return localized("New Relic returned an unexpected reply.")
        case .network(let reason): return localized("Couldn’t reach New Relic: \(reason)")
        }
    }
}

/// NerdGraph, New Relic's GraphQL API, over a bare `URLSession`. Read only.
struct NerdGraphClient: Sendable {
    let apiKey: String
    let region: NewRelicRegion

    struct Account: Sendable, Hashable, Identifiable {
        let id: Int
        let name: String
    }

    struct Identity: Sendable {
        let email: String?
        let accounts: [Account]
    }

    /// Who the key belongs to and which accounts it can read — the check a
    /// pasted key goes through before it is stored.
    func identity() async throws -> Identity {
        let envelope = try await post("{ actor { user { email } accounts { id name } } }", variables: [:])
        guard let actor = envelope["data"]?["actor"] else {
            throw firstError(envelope) ?? NewRelicError.decoding
        }
        let accounts = (actor["accounts"]?.array ?? []).compactMap { account -> Account? in
            guard let id = account["id"]?.number, let name = account["name"]?.text else { return nil }
            return Account(id: Int(id), name: name)
        }
        return Identity(
            email: actor["user"]?["email"]?.text,
            accounts: accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// The whole `{ data, errors }` envelope; the caller decides which errors matter.
    func post(_ document: String, variables: [String: String]) async throws -> JSONValue {
        guard let url = region.graphQLEndpoint else { throw NewRelicError.decoding }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "API-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": document, "variables": variables])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NewRelicError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 401 || status == 403 { throw NewRelicError.keyRejected }
        let envelope: JSONValue
        do {
            envelope = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            if !(200...299).contains(status) { throw NewRelicError.status(status) }
            throw NewRelicError.decoding
        }
        if !(200...299).contains(status), envelope["data"] == nil || envelope["data"] == .null {
            throw firstError(envelope) ?? NewRelicError.status(status)
        }
        return envelope
    }

    private func firstError(_ envelope: JSONValue) -> NewRelicError? {
        guard let message = envelope["errors"]?.array?.first?["message"]?.text else { return nil }
        if message.localizedCaseInsensitiveContains("api key") { return .keyRejected }
        return .graphQL(message)
    }
}

// MARK: - Source

/// New Relic as a `MonitorSource`. NRQL goes through NerdGraph in batches —
/// several queries per request as aliased fields, a few requests in flight —
/// which is what keeps a full tab to one or two round trips.
struct NewRelicSource: MonitorSource {
    let client: NerdGraphClient
    let accountID: Int
    let ref: String

    static let batchSize = 10
    static let concurrentRequests = 4
    /// How far back an incident that is still open can have started.
    static let incidentLookbackMinutes = 30 * 1440

    init(connection: MonitorConnection, ref: String) {
        client = NerdGraphClient(apiKey: connection.apiKey, region: connection.region)
        accountID = connection.accountID
        self.ref = ref
    }

    func run(_ queries: [String]) async -> [MonitorQueryResult] {
        guard !queries.isEmpty else { return [] }
        let chunks = stride(from: 0, to: queries.count, by: Self.batchSize).map {
            Array(queries[$0..<min($0 + Self.batchSize, queries.count)])
        }
        var results = [[MonitorQueryResult]](repeating: [], count: chunks.count)
        var next = 0
        await withTaskGroup(of: (Int, [MonitorQueryResult]).self) { group in
            func launch() {
                guard next < chunks.count else { return }
                let index = next
                let chunk = chunks[index]
                next += 1
                group.addTask { (index, await runChunk(chunk)) }
            }
            for _ in 0..<Self.concurrentRequests { launch() }
            for await (index, chunkResults) in group {
                results[index] = chunkResults
                launch()
            }
        }
        return results.flatMap { $0 }
    }

    private func runChunk(_ queries: [String]) async -> [MonitorQueryResult] {
        var variables: [String: String] = [:]
        var declarations: [String] = []
        var fields: [String] = []
        for (index, query) in queries.enumerated() {
            variables["q\(index)"] = query
            declarations.append("$q\(index): Nrql!")
            fields.append("q\(index): nrql(query: $q\(index), timeout: 60) { results metadata { facets } }")
        }
        let document = "query(\(declarations.joined(separator: ", "))) { actor { account(id: \(accountID)) { \(fields.joined(separator: " ")) } } }"
        do {
            let envelope = try await client.post(document, variables: variables)
            return NewRelicMapping.results(envelope, count: queries.count)
        } catch {
            return queries.map { _ in .failure(error.localizedDescription) }
        }
    }

    func incidents(filter: String?, sinceMinutes: Int) async throws -> [MonitorIncident] {
        let query = NewRelicMapping.incidentQuery(filter: filter, lookbackMinutes: Self.incidentLookbackMinutes)
        guard let result = await run([query]).first else { return [] }
        if let error = result.error { throw NewRelicError.graphQL(error) }
        return NewRelicMapping.incidents(
            result.table, source: ref, closedWithinMinutes: sinceMinutes, now: Date(),
            webBase: client.region.webBase)
    }

    func services(filter: String?) async throws -> [MonitorService] {
        var search = "accountId = \(accountID) AND domain IN ('APM', 'EXT') AND type IN ('APPLICATION', 'SERVICE')"
        if let filter, !filter.trimmingCharacters(in: .whitespaces).isEmpty { search += " AND (\(filter))" }
        let document = """
        query($search: String!) { actor { entitySearch(query: $search) { results { entities {
          guid name alertSeverity reporting permalink
          ... on ApmApplicationEntityOutline { apmSummary { responseTimeAverage throughput } }
        } } } } }
        """
        let envelope = try await client.post(document, variables: ["search": search])
        if envelope["data"]?["actor"]?["entitySearch"] == nil || envelope["data"]?["actor"]?["entitySearch"] == .null,
           let message = envelope["errors"]?.array?.first?["message"]?.text {
            throw NewRelicError.graphQL(message)
        }
        return NewRelicMapping.services(envelope, source: ref)
    }
}

// MARK: - Mapping

/// NerdGraph replies to the normalized records. Pure, so fixtures test it.
enum NewRelicMapping {
    /// One result per aliased query `q0…qN`. An error whose path names an alias
    /// fails only that query; one that names none fails every query that came
    /// back empty.
    static func results(_ envelope: JSONValue, count: Int) -> [MonitorQueryResult] {
        let account = envelope["data"]?["actor"]?["account"]
        let errors = envelope["errors"]?.array ?? []
        return (0..<count).map { index in
            let alias = "q\(index)"
            let own = errors.first { error in
                (error["path"]?.array ?? []).contains { $0.text == alias }
            }
            guard let result = account?[alias], result != .null, own == nil else {
                let message = own?["message"]?.text ?? errors.first?["message"]?.text ?? localized("No data returned.")
                return .failure(message)
            }
            let facetNames = (result["metadata"]?["facets"]?.array ?? []).compactMap(\.text)
            return MonitorQueryResult(table: table(result["results"]?.array ?? [], facetNames: facetNames), error: nil)
        }
    }

    static func table(_ rows: [JSONValue], facetNames: [String]) -> MonitorTable {
        let facetKeys = Set(facetNames)
        let mapped = rows.compactMap { row -> MonitorRow? in
            guard case .object(let fields) = row else { return nil }
            var facets: [String] = []
            switch fields["facet"] {
            case .array(let values)?: facets = values.map { $0.text ?? "–" }
            case let value? where value != .null: facets = [value.text ?? "–"]
            default: break
            }
            var values: [String: JSONValue] = [:]
            for (key, value) in fields where key != "facet" && !facetKeys.contains(key) {
                flatten(value, into: &values, prefix: key)
            }
            return MonitorRow(facets: facets, values: values)
        }
        return MonitorTable(facetNames: facetNames, rows: mapped)
    }

    /// `{"lat": {"50": 0.1, "95": 0.4}}` → `lat.50`, `lat.95`; and a single
    /// nested number is also kept under the bare key, so `percentile(x, 95) AS
    /// 'p95'` reads as `p95`.
    private static func flatten(_ value: JSONValue, into values: inout [String: JSONValue], prefix: String) {
        guard case .object(let fields) = value else {
            values[prefix] = value
            return
        }
        for (key, nested) in fields {
            flatten(nested, into: &values, prefix: "\(prefix).\(key)")
        }
        if fields.count == 1, let only = fields.values.first, only.number != nil {
            values[prefix] = only
        }
    }

    static func events(_ table: MonitorTable, map: MonitorEventMap?, source: String, panel: String) -> [MonitorEvent] {
        func first(_ row: MonitorRow, _ explicit: String?, _ fallbacks: [String]) -> JSONValue? {
            for field in [explicit].compactMap({ $0 }) + fallbacks {
                if let value = row.values[field], value != .null { return value }
            }
            return nil
        }
        let consumed = Set(
            [map?.time, map?.message, map?.trace].compactMap { $0 }
                + MonitorEventMap.defaultTime + MonitorEventMap.defaultTrace)
        return table.rows.enumerated().map { index, row in
            let timeValue = first(row, map?.time, MonitorEventMap.defaultTime)?.number
            let severity: MonitorSeverity = {
                let fallback = map?.defaultSeverity ?? .info
                guard let value = first(row, map?.severity, MonitorEventMap.defaultSeverity) else { return fallback }
                if case .number(let number) = value { return MonitorSeverity(openTelemetryNumber: number) }
                return value.text.flatMap(MonitorSeverity.init(text:)) ?? fallback
            }()
            let message = first(row, map?.message, MonitorEventMap.defaultMessage)?.text
                ?? row.text("facet") ?? localized("(no message)")
            var attributes: [String: String] = [:]
            for (key, value) in row.values where !consumed.contains(key) {
                if let text = value.text, text != message { attributes[key] = text }
            }
            if !row.facets.isEmpty { attributes["facet"] = row.text("facet") }
            return MonitorEvent(
                id: "\(panel).\(index).\(timeValue.map { String(Int64($0)) } ?? "")",
                time: timeValue.map { Date(timeIntervalSince1970: $0 / 1000) },
                severity: severity,
                service: first(row, map?.service, MonitorEventMap.defaultService)?.text,
                message: message,
                attributes: attributes,
                traceID: first(row, map?.trace, MonitorEventMap.defaultTrace)?.text,
                source: source)
        }
    }

    static func incidentQuery(filter: String?, lookbackMinutes: Int) -> String {
        let condition = filter.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : " WHERE \($0)" } ?? ""
        return "SELECT latest(event) AS 'event', latest(priority) AS 'priority', latest(title) AS 'title', "
            + "latest(conditionName) AS 'condition', latest(policyName) AS 'policy', latest(entity.name) AS 'entity', "
            + "latest(runbookUrl) AS 'runbook', latest(muted) AS 'muted', min(openTime) AS 'openTime', "
            + "max(closeTime) AS 'closeTime' FROM NrAiIncident\(condition) FACET incidentId "
            + "SINCE \(lookbackMinutes) minutes ago LIMIT MAX"
    }

    /// Open incidents, and those closed within the window. Incidents New Relic
    /// itself muted are left out: a muting rule is someone already saying
    /// "not this".
    static func incidents(
        _ table: MonitorTable, source: String, closedWithinMinutes: Int, now: Date, webBase: URL?
    ) -> [MonitorIncident] {
        let cutoff = now.addingTimeInterval(-Double(closedWithinMinutes) * 60)
        let incidents = table.rows.compactMap { row -> MonitorIncident? in
            guard let id = row.facets.first else { return nil }
            if row.values["muted"] == .bool(true) { return nil }
            let closed = row.text("event")?.lowercased() == "close"
            let closedAt = row.number("closeTime").map { Date(timeIntervalSince1970: $0 / 1000) }
            if closed, (closedAt ?? .distantPast) < cutoff { return nil }
            let condition = row.text("condition")
            return MonitorIncident(
                id: "\(source):\(id)",
                title: row.text("title") ?? condition ?? id,
                priority: .init(text: row.text("priority")),
                state: closed ? .closed : .open,
                openedAt: row.number("openTime").map { Date(timeIntervalSince1970: $0 / 1000) },
                closedAt: closed ? closedAt : nil,
                service: row.text("entity"),
                condition: condition,
                policy: row.text("policy"),
                link: row.text("runbook").flatMap(URL.init(string:)) ?? webBase,
                source: source)
        }
        return sortedIncidents(incidents)
    }

    /// Open before closed, then the worst first, then the newest.
    static func sortedIncidents(_ incidents: [MonitorIncident]) -> [MonitorIncident] {
        incidents.sorted {
            if $0.isOpen != $1.isOpen { return $0.isOpen }
            if $0.priority.severity != $1.priority.severity { return $0.priority.severity > $1.priority.severity }
            return ($0.openedAt ?? .distantPast) > ($1.openedAt ?? .distantPast)
        }
    }

    static func services(_ envelope: JSONValue, source: String) -> [MonitorService] {
        let entities = envelope["data"]?["actor"]?["entitySearch"]?["results"]?["entities"]?.array ?? []
        let services = entities.compactMap { entity -> MonitorService? in
            guard let guid = entity["guid"]?.text, let name = entity["name"]?.text else { return nil }
            let health: MonitorService.Health
            switch entity["alertSeverity"]?.text {
            case "CRITICAL": health = .critical
            case "WARNING": health = .warning
            case "NOT_ALERTING": health = .healthy
            default: health = .unknown
            }
            var values: [String: Double] = [:]
            if let summary = entity["apmSummary"] {
                values["throughput"] = summary["throughput"]?.number
                values["responseTime"] = summary["responseTimeAverage"]?.number
            }
            return MonitorService(
                id: "\(source):\(guid)", name: name, health: health,
                isReporting: entity["reporting"] != .bool(false), values: values,
                link: entity["permalink"]?.text.flatMap(URL.init(string:)), source: source)
        }
        let rank: [MonitorService.Health: Int] = [.critical: 0, .warning: 1, .unknown: 2, .healthy: 3]
        return services.sorted {
            if $0.health != $1.health { return rank[$0.health, default: 4] < rank[$1.health, default: 4] }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Default profile

/// What the pane shows before anyone customizes it: everything the connected
/// accounts have, in the panels most teams start from. Generated, never saved
/// until the person changes something.
enum NewRelicDefaults {
    static let profileID = "default"

    static func profile(for connections: [MonitorConnection]) -> MonitoringProfile {
        let newRelic = connections.filter { $0.type == .newRelic }
        var profile = MonitoringProfile(
            id: profileID, name: localized("Everything"),
            variables: [MonitorVariable(
                name: "window", title: localized("Window"), kind: .duration,
                options: ["15m", "1h", "3h", "24h", "7d"], defaultValue: "1h")])
        for (index, connection) in newRelic.enumerated() {
            let ref = index == 0 ? "nr" : "nr\(index + 1)"
            let suffix = newRelic.count > 1 ? " · \(connection.accountName)" : ""
            profile.connectors.append(MonitorConnectorRequirement(
                ref: ref, type: .newRelic, accountID: connection.accountID, region: connection.region.rawValue))
            profile.observability += [
                MonitorPanel(id: "\(ref)-services", title: localized("Services") + suffix, kind: .services, source: ref),
                MonitorPanel(
                    id: "\(ref)-log-errors", title: localized("Log Errors") + suffix, kind: .events, source: ref,
                    query: "SELECT timestamp, message, level, severity.text, severity.number, service.name, "
                        + "entity.name, trace.id FROM Log WHERE severity.number >= 17 OR level IN "
                        + "('error', 'ERROR', 'Error', 'fatal', 'FATAL', 'critical', 'CRITICAL') OR severity.text IN "
                        + "('ERROR', 'FATAL', 'error', 'fatal') SINCE {{window}} LIMIT 500",
                    group: true),
                MonitorPanel(
                    id: "\(ref)-span-errors", title: localized("Failing Operations") + suffix, kind: .events,
                    source: ref,
                    query: "SELECT timestamp, name, service.name, error.message, otel.status_description, trace.id "
                        + "FROM Span WHERE otel.status_code = 'ERROR' OR error IS true SINCE {{window}} LIMIT 500",
                    map: MonitorEventMap(defaultSeverity: .error), group: true),
            ]
            profile.metrics.append(MonitorPanel(
                id: "\(ref)-golden", title: localized("Golden Signals") + suffix, kind: .table, source: ref,
                query: "SELECT count(*) AS 'calls', rate(count(*), 1 minute) AS 'rpm', "
                    + "percentage(count(*), WHERE otel.status_code = 'ERROR' OR error IS true) AS 'errors', "
                    + "percentile(duration.ms, 95) AS 'p95' FROM Span WHERE span.kind = 'server' OR nr.entryPoint IS true "
                    + "FACET service.name SINCE {{window}} LIMIT 100",
                columns: [
                    MonitorColumn(field: "facet", title: localized("Service")),
                    MonitorColumn(field: "rpm", title: "/min", format: .count),
                    MonitorColumn(field: "errors", title: localized("Errors"), format: .percent, warn: 1, crit: 5),
                    MonitorColumn(field: "p95", title: "p95", format: .milliseconds),
                ],
                sort: "calls"))
            profile.incidents.append(MonitorPanel(
                id: "\(ref)-incidents", title: localized("Incidents") + suffix, kind: .incidents, source: ref))
        }
        return profile
    }
}
