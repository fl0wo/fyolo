import Foundation

/// The one thing fyolo measures about itself: how many installs open it on a
/// given day.
///
/// Deliberately **not** PostHog's Swift SDK. `posthog-ios` ships
/// `PrivacyInfo.xcprivacy` as a bundled resource in two of its targets and pulls
/// in PLCrashReporter and libwebp behind it — an SPM dependency that ships
/// resources is the exact shape that has crashed a released fyolo twice (see
/// AGENTS.md, "Dependencies and vendored code"). PostHog's capture endpoint is
/// one JSON POST, and a daily-active count needs nothing else, so the whole
/// integration is this file: no session replay, no autocapture, no crash
/// reporter, no background queue.
///
/// What leaves the machine, at most once per calendar day: a random install
/// UUID, the app version, the macOS version, and the preferred language. No
/// project paths, no session contents, no account, nothing tied to a person.
/// Events are sent anonymously (`$process_person_profile: false`), so PostHog
/// stores no person record — daily-unique counts resolve on the install id
/// alone.
///
/// Off in the dev channel, off under `swift run` and `swift test`, and off
/// entirely when the user turns it off in Settings ▸ General ▸ Privacy.
@MainActor
enum Analytics {
    /// PostHog project API key. Write-only by design: it can capture events and
    /// read nothing back, which is why PostHog ships it inside client bundles and
    /// why it is safe in a public repo. Empty disables every path below, so a
    /// fork that never sets one sends nothing.
    private static let projectAPIKey = ""

    /// Ingestion host for the project's region. `us.i.posthog.com` for a US
    /// project, `eu.i.posthog.com` for an EU one — a key posted to the wrong
    /// region is rejected.
    private static let ingestionHost = "https://us.i.posthog.com"

    private enum Key {
        /// A random per-install identifier. Not derived from hardware, the user,
        /// or anything else that could be correlated back off-device; deleting it
        /// makes this install a new one and nothing more.
        static let installID = "analytics.installID"
        /// The last day already counted, `yyyy-MM-dd` in UTC. Presence of today's
        /// date is the whole dedupe.
        static let lastActiveDay = "analytics.lastActiveDay"
    }

    private static weak var settings: AppSettings?
    private static var rolloverTimer: Timer?

    /// Counts today, then keeps counting for as long as the app stays open.
    ///
    /// The hourly tick is not a send: it re-asks the date question, which is a
    /// string comparison that answers "already counted" on all but one wake a
    /// day. Without it an app left running across midnight — the normal state of
    /// a machine supervising agents — would report the day it launched and never
    /// another one.
    static func start(settings: AppSettings) {
        self.settings = settings
        recordActiveDay()
        rolloverTimer?.invalidate()
        rolloverTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { recordActiveDay() }
        }
    }

    static func recordActiveDay() {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        let today = day(for: Date())
        guard defaults.string(forKey: Key.lastActiveDay) != today else { return }
        // Claim the day before the request goes out, so a second launch while the
        // first is still in flight can't double-count it.
        defaults.set(today, forKey: Key.lastActiveDay)
        let identifier = installID
        Task { @MainActor in
            let delivered = await send(event: "app_active", distinctID: identifier)
            guard !delivered else { return }
            // Hand the day back only if nothing has moved on since — the hourly
            // tick then retries, which is what makes a closed lid at launch cost
            // nothing.
            if defaults.string(forKey: Key.lastActiveDay) == today {
                defaults.removeObject(forKey: Key.lastActiveDay)
            }
        }
    }

    // MARK: - Consent

    private static var isEnabled: Bool {
        guard !projectAPIKey.isEmpty else { return false }
        // An explicit environment answer wins over everything, including the
        // channel gate — it is how the dev build is exercised at all.
        switch ProcessInfo.processInfo.environment["FYOLO_ANALYTICS"]?.lowercased() {
        case "off", "0", "false": return false
        case "on", "1", "true": return true
        default: break
        }
        // A rebuild loop is not a user, and neither is a test run. Both would
        // otherwise land in the same daily-active count as a real install.
        guard AppChannel.isFyoloAppBundle, !AppChannel.isDev else { return false }
        return settings?.analyticsEnabled ?? false
    }

    // MARK: - Sending

    /// Returns whether PostHog accepted the event. Failure is expected and cheap
    /// — no network at launch is the common case.
    private static func send(event: String, distinctID: String) async -> Bool {
        guard let url = URL(string: ingestionHost + "/i/v0/e/") else { return false }
        let payload: [String: Any] = [
            "api_key": projectAPIKey,
            "event": event,
            "distinct_id": distinctID,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "properties": [
                // Anonymous event: no person record, no person properties. Daily
                // uniques still count on `distinct_id`.
                "$process_person_profile": false,
                "$lib": "fyolo-mac",
                "app_version": appVersion,
                "os_version": osVersion,
                "language": Locale.preferredLanguages.first ?? "und",
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            Log.app.error("analytics: could not encode \(event, privacy: .public)")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200 ..< 300).contains(http.statusCode) else {
                Log.app.error("""
                    analytics: \(event, privacy: .public) rejected \
                    (HTTP \(http.statusCode, privacy: .public))
                    """)
                return false
            }
            return true
        } catch {
            Log.app.info("""
                analytics: \(event, privacy: .public) not sent — \
                \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
    }

    // MARK: - Values

    private static var installID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Key.installID), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Key.installID)
        return fresh
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// UTC, so a machine that travels does not report two active days for one,
    /// and so the boundary matches the one PostHog's own daily rollup uses.
    private static func day(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") { calendar.timeZone = utc }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
