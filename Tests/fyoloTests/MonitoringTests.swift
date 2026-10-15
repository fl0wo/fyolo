import XCTest
@testable import fyolo

/// The Monitoring noise engine: message templates, Dice similarity, the
/// similarity slider, and how rules decide placement and notification.
final class MonitoringNoiseTests: XCTestCase {
    func testTemplateMasksTheVariableParts() {
        XCTAssertEqual(
            MonitorNoise.template("Order 812 timed out after 30.5s"),
            MonitorNoise.template("order 977 timed out after 31s"))
        XCTAssertEqual(
            MonitorNoise.template("trace=4bf92f3577b34da6a3ce929d0e0e4736 failed"),
            "trace=<id> failed")
        XCTAssertEqual(
            MonitorNoise.template("GET https://api.example.com/v1/x?id=3 from 10.0.0.12"),
            "get <url> from <n>")
        XCTAssertEqual(
            MonitorNoise.template("user 6f1c2a9e-3b0d-4a55-9c2e-1d2f3a4b5c6d not found"),
            "user <id> not found")
        XCTAssertEqual(MonitorNoise.template("mail ops@example.com"), "mail <email>")
    }

    func testTemplateKeepsWordsThatOnlyLookHexy() {
        // "deadbeef"-shaped words are ids; plain English that happens to be
        // all hex letters is not.
        XCTAssertEqual(MonitorNoise.template("decade faded"), "decade faded")
    }

    func testDiceIsOneForTheSameTextAndLowForUnrelatedText() {
        XCTAssertEqual(MonitorNoise.similarity("connection refused", "connection refused"), 1)
        let unrelated = MonitorNoise.similarity(
            "connection refused by upstream", "invoice rendered for customer")
        XCTAssertLessThan(unrelated, MonitorNoise.threshold(strength: 0))
        let related = MonitorNoise.similarity(
            "connection refused by upstream acme", "connection refused by upstream globex")
        XCTAssertGreaterThan(related, MonitorNoise.threshold(strength: 50))
    }

    func testSliderEnds() {
        XCTAssertEqual(MonitorNoise.threshold(strength: 0), 0.30, accuracy: 1e-9)
        XCTAssertEqual(MonitorNoise.threshold(strength: 100), 0.99, accuracy: 1e-9)
        XCTAssertEqual(MonitorNoise.threshold(strength: -20), MonitorNoise.threshold(strength: 0))
        XCTAssertEqual(MonitorNoise.threshold(strength: 400), MonitorNoise.threshold(strength: 100))
    }

    func testStrengthOneHundredMatchesTheSameTextWithDifferentNumbers() {
        let rule = MonitorRule(
            id: "r", match: MonitorRuleMatch(similarTo: MonitorSimilarity(text: "Order 1 timed out", strength: 100)),
            action: .hide)
        let engine = MonitorRuleEngine(rules: [rule])
        XCTAssertTrue(engine.matches(rule, MonitorSubject(tab: .observability, text: "order 55 timed out")))
        XCTAssertFalse(engine.matches(rule, MonitorSubject(tab: .observability, text: "order 55 was refunded")))
    }

    func testNothingIsHiddenAndNothingNotifiesByDefault() {
        let verdict = MonitorRuleEngine(rules: []).verdict(
            for: MonitorSubject(tab: .incidents, severity: .critical, text: "CPU on fire"))
        XCTAssertEqual(verdict, MonitorVerdict())
    }

    func testFirstRuleWinsOnEachAxisIndependently() {
        let engine = MonitorRuleEngine(rules: [
            MonitorRule(id: "show-payments", match: MonitorRuleMatch(service: "payments*"), action: .show),
            MonitorRule(id: "hide-all", match: MonitorRuleMatch(), action: .hide),
            MonitorRule(id: "mute-warnings", match: MonitorRuleMatch(tab: .incidents), action: .mute),
            MonitorRule(id: "notify-critical", match: MonitorRuleMatch(minimumSeverity: .critical), action: .notify),
        ])
        let payments = engine.verdict(
            for: MonitorSubject(tab: .incidents, service: "payments-api", severity: .critical, text: "x"))
        XCTAssertEqual(payments.placement, .shown)
        // The mute came first on the notification axis, so the later notify never applies.
        XCTAssertFalse(payments.notifies)

        let other = engine.verdict(for: MonitorSubject(tab: .observability, service: "ledger", severity: .critical, text: "y"))
        XCTAssertEqual(other.placement, .hidden)
        XCTAssertEqual(other.hiddenBy, "hide-all")
        XCTAssertTrue(other.notifies)
    }

    func testAPinnedItemSurvivesAHideRule() {
        let subject = MonitorSubject(tab: .observability, text: "disk full")
        let verdict = MonitorRuleEngine(rules: [MonitorRule(id: "h", match: MonitorRuleMatch(), action: .hide)])
            .verdict(for: subject, pinnedItems: [subject.fingerprint])
        XCTAssertEqual(verdict.placement, .pinned)
        XCTAssertNil(verdict.hiddenBy)
    }

    func testMatchConditionsAllHaveToHold() {
        let rule = MonitorRule(
            id: "r",
            match: MonitorRuleMatch(
                tab: .observability, minimumSeverity: .error, contains: "Timeout",
                attributes: ["app.partner": "acme*"]),
            action: .group, group: "Acme")
        let engine = MonitorRuleEngine(rules: [rule])
        let matching = MonitorSubject(
            tab: .observability, severity: .error, text: "upstream timeout",
            attributes: ["app.partner": "acme-us"])
        XCTAssertEqual(engine.verdict(for: matching).group, "Acme")
        var lowSeverity = matching
        lowSeverity.severity = .warning
        XCTAssertNil(engine.verdict(for: lowSeverity).group)
        var otherIntegration = matching
        otherIntegration.attributes = ["app.partner": "globex"]
        XCTAssertNil(engine.verdict(for: otherIntegration).group)
    }

    func testGroupingMergesTheSameMessageAcrossSources() {
        let events = [
            MonitorEvent(id: "1", time: Date(timeIntervalSince1970: 10), severity: .error, service: "api",
                         message: "timeout after 30s", source: "nr"),
            MonitorEvent(id: "2", time: Date(timeIntervalSince1970: 20), severity: .critical, service: "api",
                         message: "timeout after 31s", source: "dd"),
            MonitorEvent(id: "3", time: Date(timeIntervalSince1970: 15), severity: .warning, service: "api",
                         message: "slow query", source: "nr"),
        ]
        let groups = MonitorEventGroup.grouping(events)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[0].severity, .critical)
        XCTAssertEqual(groups[0].latest.id, "2")
        XCTAssertEqual(groups[0].sources, ["nr", "dd"])
    }
}

/// Profiles: decoding what people write by hand, variables, the personal
/// overlay, and a sample profile that uses every panel kind.
final class MonitoringProfileTests: XCTestCase {
    private func fixture() throws -> MonitoringProfile {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample-profile", withExtension: "json",
                              subdirectory: "Fixtures/monitoring"))
        return try MonitoringLibrary.decode(Data(contentsOf: url))
    }

    func testTheSampleProfileDecodes() throws {
        let profile = try fixture()
        XCTAssertEqual(profile.connectors.first?.accountID, 1234567)
        XCTAssertEqual(profile.variables.map(\.name), ["env", "service", "window"])
        XCTAssertEqual(profile.metrics.map(\.kind), [.stat, .stat, .table, .table, .stat, .table])
        XCTAssertEqual(profile.incidents.last?.checks?.count, 2)
    }

    func testRendersTheRoutesQueryExactly() throws {
        let profile = try fixture()
        let routes = try XCTUnwrap(profile.metrics.first { $0.id == "routes" }?.query)
        let rendered = try MonitorQueryTemplate.render(routes, variables: profile.variables, values: [:])
        XCTAssertEqual(rendered, "SELECT count(*) AS 'calls', percentage(count(*), WHERE http.response.status_code >= 500) AS 'err5xx', percentile(http.server.request.duration, 95) AS 'p95' FROM Metric WHERE metricName = 'http.server.request.duration' AND service.name = 'checkout' AND environment = 'production' AND http.route != '/health' FACET http.route SINCE 60 minutes ago LIMIT 100")
    }

    func testRawPlaceholdersBuildLiterals() throws {
        let profile = try fixture()
        let filter = try XCTUnwrap(profile.incidents.first?.filter)
        XCTAssertEqual(
            try MonitorQueryTemplate.render(filter, variables: profile.variables, values: ["env": "staging"]),
            "policyName = 'checkout [staging]'")
    }

    func testStringValuesAreEscaped() throws {
        let variables = [MonitorVariable(name: "service", kind: .string, defaultValue: "a")]
        XCTAssertEqual(
            try MonitorQueryTemplate.render(
                "WHERE s = {{service}}", variables: variables, values: ["service": #"o'brien\x"#]),
            #"WHERE s = 'o\'brien\\x'"#)
    }

    func testUnknownVariablesAndBadWindowsAreErrors() {
        let variables = [MonitorVariable(name: "window", kind: .duration, defaultValue: "1h")]
        XCTAssertThrowsError(try MonitorQueryTemplate.render("{{nope}}", variables: variables, values: [:])) {
            XCTAssertEqual($0 as? MonitorQueryError, .unknownVariable("nope"))
        }
        XCTAssertThrowsError(
            try MonitorQueryTemplate.render("SINCE {{window}}", variables: variables, values: ["window": "soon"]))
        XCTAssertEqual(
            try MonitorQueryTemplate.render("SINCE {{ window }}", variables: variables, values: ["window": "7d"]),
            "SINCE 10080 minutes ago")
    }

    func testUnknownKindsAndFieldsDecodeAndSurviveARoundTrip() throws {
        let json = #"{"id":"p","observability":[{"id":"x","kind":"heatmap","shiny":true}]}"#
        let profile = try MonitoringLibrary.decode(Data(json.utf8))
        XCTAssertNil(profile.observability.first?.kind)
        let again = try MonitoringLibrary.decode(MonitoringLibrary.encode(profile))
        XCTAssertEqual(again.observability.first?.kindName, "heatmap")
    }

    func testRefusesANewerFormat() {
        XCTAssertThrowsError(try MonitoringLibrary.decode(Data(#"{"fyoloMonitoring":99,"id":"p"}"#.utf8)))
    }

    func testOverlayOrderKeepsNewTeamPanelsAndDropsVanishedOnes() {
        var profile = MonitoringProfile(id: "p", name: "p")
        profile.metrics = ["a", "b", "c"].map { MonitorPanel(id: $0, title: $0, kind: .table) }
        var overlay = MonitoringOverlay(profileID: "p")
        overlay.order["metrics"] = ["c", "gone", "a"]
        overlay.update("b") { $0.pinned = true }
        overlay.update("a") { $0.hidden = true }

        let placed = profile.placedPanels(in: .metrics, overlay: overlay)
        XCTAssertEqual(placed.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(placed.first { $0.id == "a" }?.isHidden, true)

        // The team adds a panel and removes one; the person's arrangement holds.
        profile.metrics = ["a", "c", "d"].map { MonitorPanel(id: $0, title: $0, kind: .table) }
        XCTAssertEqual(profile.placedPanels(in: .metrics, overlay: overlay).map(\.id), ["c", "a", "d"])
    }

    func testPersonalRulesRunBeforeTheTeams() {
        var profile = MonitoringProfile(id: "p", name: "p")
        profile.rules = [MonitorRule(id: "team", match: MonitorRuleMatch(), action: .hide)]
        var overlay = MonitoringOverlay(profileID: "p")
        overlay.rules = [MonitorRule(id: "mine", match: MonitorRuleMatch(service: "ledger"), action: .show)]
        let engine = MonitorRuleEngine(rules: profile.effectiveRules(with: overlay))
        XCTAssertEqual(engine.verdict(for: MonitorSubject(tab: .metrics, service: "ledger", text: "x")).placement, .shown)
        XCTAssertEqual(engine.verdict(for: MonitorSubject(tab: .metrics, service: "api", text: "x")).placement, .hidden)
    }

    func testFoldingCarriesTheArrangementIntoAnExport() {
        var profile = MonitoringProfile(id: "p", name: "p")
        profile.variables = [MonitorVariable(name: "env", kind: .string, options: ["prd", "sbx"], defaultValue: "prd")]
        profile.metrics = ["a", "b"].map { MonitorPanel(id: $0, title: $0, kind: .table) }
        var overlay = MonitoringOverlay(profileID: "p")
        overlay.update("a") { $0.hidden = true }
        overlay.values["env"] = "sbx"
        let folded = profile.folding(overlay)
        XCTAssertEqual(folded.metrics.map(\.id), ["b"])
        XCTAssertEqual(folded.variables.first?.defaultValue, "sbx")
    }

    func testFileNamesAreSanitized() {
        XCTAssertEqual(MonitoringLibrary.fileName("../../etc/passwd"), "-..-etc-passwd.json")
        XCTAssertEqual(MonitoringLibrary.fileName(""), "profile.json")
    }
}

/// NerdGraph replies to normalized records.
final class NewRelicMappingTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testFlattensPercentilesAndReadsFacets() throws {
        let envelope = try json(#"""
        {"data":{"actor":{"account":{"q0":{"results":[
          {"facet":"/v1/quote","http.route":"/v1/quote","calls":120,"lat":{"50":0.1,"95":0.4,"99":0.9},"p95":{"95":0.4}},
          {"facet":["acme","USD"],"completed":3}
        ],"metadata":{"facets":["http.route"]}}}}}}
        """#)
        let result = try XCTUnwrap(NewRelicMapping.results(envelope, count: 1).first)
        XCTAssertNil(result.error)
        let first = result.table.rows[0]
        XCTAssertEqual(first.facets, ["/v1/quote"])
        XCTAssertNil(first.values["http.route"], "facet attributes are not repeated as values")
        XCTAssertEqual(first.number("lat.95"), 0.4)
        XCTAssertNil(first.number("lat"), "a several-value percentile has no bare value")
        XCTAssertEqual(first.number("p95"), 0.4, "a single-value percentile reads under its alias")
        XCTAssertEqual(result.table.rows[1].text("facet"), "acme · USD")
    }

    func testAnErrorFailsOnlyItsOwnAlias() throws {
        let envelope = try json(#"""
        {"data":{"actor":{"account":{"q0":{"results":[{"count":1}],"metadata":{"facets":null}},"q1":null}}},
         "errors":[{"message":"NRQL Syntax Error","path":["actor","account","q1"]}]}
        """#)
        let results = NewRelicMapping.results(envelope, count: 2)
        XCTAssertNil(results[0].error)
        XCTAssertEqual(results[1].error, "NRQL Syntax Error")
    }

    func testEventsReadLevelsTimesAndAttributes() throws {
        let table = NewRelicMapping.table([
            try json(#"{"timestamp":1700000000000,"severity.number":17,"message":"boom","service.name":"api","trace.id":"t1","app.partner":"globex"}"#),
            try json(#"{"timestamp":1700000001000,"level":"WARN","message":"slow"}"#),
            try json(#"{"timestamp":1700000002000,"name":"/Quote","otel.status_description":"deadline"}"#),
        ], facetNames: [])
        let events = NewRelicMapping.events(
            table, map: MonitorEventMap(defaultSeverity: .error), source: "nr", panel: "p")
        XCTAssertEqual(events[0].severity, .error)
        XCTAssertEqual(events[0].service, "api")
        XCTAssertEqual(events[0].traceID, "t1")
        XCTAssertEqual(events[0].attributes["app.partner"], "globex")
        XCTAssertEqual(events[0].time, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(events[1].severity, .warning)
        XCTAssertEqual(events[2].message, "deadline")
        XCTAssertEqual(events[2].severity, .error)
    }

    func testIncidentsKeepOpenAndRecentlyClosedOnly() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ms = { (secondsAgo: Double) in (now.timeIntervalSince1970 - secondsAgo) * 1000 }
        let rows: [JSONValue] = [
            .object(["facet": .string("a"), "event": .string("Open"), "priority": .string("critical"),
                     "title": .string("CPU high"), "openTime": .number(ms(600))]),
            .object(["facet": .string("b"), "event": .string("Close"), "priority": .string("warning"),
                     "openTime": .number(ms(9000)), "closeTime": .number(ms(7200)), "condition": .string("old")]),
            .object(["facet": .string("c"), "event": .string("Close"), "priority": .string("warning"),
                     "openTime": .number(ms(900)), "closeTime": .number(ms(300)), "condition": .string("recent")]),
            .object(["facet": .string("d"), "event": .string("Open"), "muted": .bool(true)]),
            .object(["facet": .string("e"), "event": .string("Open"), "priority": .string("warning"),
                     "openTime": .number(ms(60))]),
        ]
        let incidents = NewRelicMapping.incidents(
            NewRelicMapping.table(rows, facetNames: ["incidentId"]), source: "nr",
            closedWithinMinutes: 60, now: now, webBase: nil)
        XCTAssertEqual(incidents.map(\.id), ["nr:a", "nr:e", "nr:c"])
        XCTAssertEqual(incidents[0].priority, .critical)
        XCTAssertEqual(incidents[2].title, "recent")
        XCTAssertEqual(incidents[2].state, .closed)
    }

    func testServicesSortWorstFirst() throws {
        let envelope = try json(#"""
        {"data":{"actor":{"entitySearch":{"results":{"entities":[
          {"guid":"1","name":"zeta","alertSeverity":"NOT_ALERTING","reporting":true},
          {"guid":"2","name":"alpha","alertSeverity":"CRITICAL","reporting":true,"apmSummary":{"throughput":12.5,"responseTimeAverage":0.2}},
          {"guid":"3","name":"beta","alertSeverity":"NOT_CONFIGURED","reporting":false}
        ]}}}}}
        """#)
        let services = NewRelicMapping.services(envelope, source: "nr")
        XCTAssertEqual(services.map(\.name), ["alpha", "beta", "zeta"])
        XCTAssertEqual(services[0].values["throughput"], 12.5)
        XCTAssertFalse(services[1].isReporting)
    }

    func testDefaultProfileCoversEveryTabAndRenders() throws {
        let connection = MonitorConnection(
            type: .newRelic, apiKey: "k", accountID: 1, accountName: "Acme", region: .us, userEmail: nil)
        let profile = NewRelicDefaults.profile(for: [connection])
        XCTAssertFalse(profile.observability.isEmpty)
        XCTAssertFalse(profile.metrics.isEmpty)
        XCTAssertFalse(profile.incidents.isEmpty)
        for panel in profile.allPanels {
            if let query = panel.query {
                XCTAssertNoThrow(try MonitorQueryTemplate.render(query, variables: profile.variables, values: [:]))
            }
        }
    }
}
