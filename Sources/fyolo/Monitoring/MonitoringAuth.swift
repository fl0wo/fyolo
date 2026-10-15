import Foundation
import Security

/// One connected backend account: the key, and the account it reads. Several
/// can exist side by side — two New Relic accounts, later a Datadog org — and a
/// profile's connectors bind to them by type and account.
struct MonitorConnection: Codable, Equatable, Sendable, Identifiable {
    var type: MonitorConnectorType
    var apiKey: String
    var accountID: Int
    var accountName: String
    var region: NewRelicRegion
    var userEmail: String?

    var id: String { "\(type.rawValue).\(region.rawValue).\(accountID)" }

    var title: String { "\(accountName) (\(accountID))" }

    /// Whether this connection is the account a profile's connector names. A
    /// connector without an account takes the first connection of its type.
    func satisfies(_ requirement: MonitorConnectorRequirement) -> Bool {
        guard requirement.type == type else { return false }
        if let account = requirement.accountID, account != accountID { return false }
        if let region = requirement.region, region.uppercased() != self.region.rawValue { return false }
        return true
    }
}

enum NewRelicRegion: String, Codable, CaseIterable, Sendable {
    case us = "US"
    case eu = "EU"

    var graphQLEndpoint: URL? {
        URL(string: self == .eu ? "https://api.eu.newrelic.com/graphql" : "https://api.newrelic.com/graphql")
    }

    var webBase: URL? {
        URL(string: self == .eu ? "https://one.eu.newrelic.com" : "https://one.newrelic.com")
    }
}

/// The Monitoring connections, kept as one Keychain item, the way Linear's
/// and GitHub's credentials are.
enum MonitoringAuth {
    /// Posted on the main thread whenever a connection is added or removed.
    static let connectionsDidChange = Notification.Name("sh.fyolo.monitoring.connectionsDidChange")

    /// Where a New Relic user key is made.
    static let newRelicKeyURL = URL(string: "https://one.newrelic.com/api-keys")

    private static let service = "sh.fyolo.app.monitoring" + AppChannel.suffix
    private static let account = "connections"

    static func connections() -> [MonitorConnection] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.monitoring.error("reading the monitoring connections failed: \(status)")
            }
            return []
        }
        do {
            return try JSONDecoder().decode([MonitorConnection].self, from: data)
        } catch {
            Log.monitoring.error("decoding the monitoring connections failed: \(error, privacy: .public)")
            return []
        }
    }

    /// Adds `connection`, replacing one for the same account.
    static func add(_ connection: MonitorConnection) {
        var all = connections().filter { $0.id != connection.id }
        all.append(connection)
        store(all)
    }

    static func remove(id: String) {
        store(connections().filter { $0.id != id })
    }

    private static func store(_ connections: [MonitorConnection]) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        if !connections.isEmpty {
            do {
                var add = base
                add[kSecValueData as String] = try JSONEncoder().encode(connections)
                let status = SecItemAdd(add as CFDictionary, nil)
                if status != errSecSuccess {
                    Log.monitoring.error("keychain store failed for monitoring: \(status)")
                }
            } catch {
                Log.monitoring.error("encoding the monitoring connections failed: \(error, privacy: .public)")
            }
        }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: connectionsDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: connectionsDidChange, object: nil)
            }
        }
    }
}
