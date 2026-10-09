import SwiftUI
import FyoloShared
import UIKit

struct MockSession: Identifiable {
    let id = UUID()
    let title: String
    let project: String
    let agent: RosterAgent
    let status: SessionStatus
    let subtitle: String
    let time: String
    /// The Mac session's wire id when this row came from the live roster —
    /// what `attach` sends to bridge the real PTY. nil for bundled mock rows.
    var rosterID: String?
    /// The Mac project's wire id — what the file plane (`listFiles`/`readFile`)
    /// scopes requests to. nil for bundled mock rows.
    var projectRosterID: String?
    /// The project's absolute path on the Mac — the root the file tree's
    /// relative paths hang off, so "Copy Path" can hand back a full path.
    var projectPath: String?
    /// The project's current git branch (nil for non-repos / mock rows).
    var branch: String?
    /// The branch of the worktree checkout this session runs in — set only
    /// when the session lives off the project's main checkout, so rows label
    /// worktree sessions without repeating the project branch on every line.
    var worktreeBranch: String?

    static let samples: [MockSession] = [
        .init(title: "fix-sidebar", project: "fyolo", agent: .sampleClaude,
              status: .needsAttention, subtitle: "Allow running npm install?", time: "2m"),
        .init(title: "landing-hero", project: "fyolo", agent: .sampleClaude,
              status: .working, subtitle: "Editing hero.tsx…", time: "5m"),
        .init(title: "info-pane", project: "fyolo", agent: .sampleCodex,
              status: .done, subtitle: "Done · 3 files changed", time: "1h"),
        .init(title: "kanban-drag", project: "vibewizard", agent: .sampleClaude,
              status: .working, subtitle: "Running swift build…", time: "12m"),
        .init(title: "release-notes", project: "fyolo", agent: .sampleOpenCode,
              status: .idle, subtitle: "Waiting for input", time: "3h"),
    ]
}

/// A project (an opened folder), the first-level page — mirroring the desktop
/// sidebar's project → session hierarchy as list → sub-list.
struct MockProject: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    /// The Mac project's wire id when this came from the live roster — what
    /// `start` sends to create a session there. nil for bundled mock data.
    var rosterID: String?
    /// Current git branch of the checkout (nil for non-repos / mock data).
    var branch: String?
    /// The Mac's `ProjectKind` raw value ("folder" / "terminals" / "chats");
    /// nil for mock data — treat as a plain folder project.
    var kind: String?
    /// The workspace this project is filed under on the Mac, and that
    /// workspace's name — the list groups by the id and heads each group with
    /// the name. Empty for the bundled mock, which has no workspace to speak of.
    var workspaceID: String = ""
    var workspaceName: String = ""
    /// The `~/.ssh/config` alias of the machine the workspace is on, nil when
    /// that machine is the Mac we're paired with. A checkout on a VPS and one on
    /// the Mac are otherwise indistinguishable here.
    var deviceAlias: String?
    let sessions: [MockSession]

    /// A stand-in for the Mac's loose-terminals container before it has opened
    /// one, so a phone-seeded first terminal can open attached right away; the
    /// next roster push swaps in the real container.
    static let terminalsPlaceholder = MockProject(name: "Terminals", path: "", sessions: [])

    /// Projects keep their order; within a project, attention floats up.
    static let samples: [MockProject] = {
        var order: [String] = []
        var byProject: [String: [MockSession]] = [:]
        for session in MockSession.samples {
            if byProject[session.project] == nil { order.append(session.project) }
            byProject[session.project, default: []].append(session)
        }
        return order.map { name in
            MockProject(
                name: name,
                path: "~/Documents/GitHub/\(name)",
                sessions: byProject[name, default: []].sorted { $0.status.rank < $1.status.rank }
            )
        }
    }()
}

extension MockSession {
    /// Stable identity across roster refreshes (the `id` UUID is rebuilt on
    /// every push) — what the sidebar uses to highlight the open session.
    var key: String { rosterID ?? "\(project)/\(title)" }
}

// MARK: - Roster → model mapping

extension RosterAgent {
    /// Transitional defaults used only before an older Mac supplies an agent
    /// catalog. Live rows and menus otherwise render the metadata on the wire.
    static let legacyDefaults: [RosterAgent] = [.sampleClaude, .sampleCodex, .terminal]
    static let terminal = RosterAgent(id: "terminal", name: "Terminal", icon: IconRef())
    static let sampleClaude = RosterAgent(
        id: "claude", name: "Claude Code", tintHex: "#D97757",
        icon: IconRef(vector: "claude"))
    static let sampleCodex = RosterAgent(
        id: "codex", name: "Codex", icon: IconRef(vector: "codex"))
    static let sampleOpenCode = RosterAgent(
        id: "opencode", name: "OpenCode", icon: IconRef(asset: "opencode-favicon"))

    static func fallback(wire: String) -> RosterAgent {
        legacyDefaults.first { $0.id == wire }
            ?? RosterAgent(id: wire, name: wire, icon: IconRef())
    }

    var iconRef: IconRef { icon ?? IconRef() }

    var tintColor: Color {
        if let tintHex, let color = UIColor(ghosttyHex: tintHex) {
            return Color(uiColor: color)
        }
        if let vector = iconRef.vector, let logo = BrandLogo(reference: vector) {
            return logo.tint
        }
        return .monochromeInk
    }
}

extension IconRef {
    /// The agent's real brand mark as a `UIImage`, for UIKit spots (UIMenu
    /// rows) that can't host the SwiftUI `AgentIconView` the session rows use —
    /// so the menus show the same marks as the macOS sidebar, not SF Symbol
    /// stand-ins. Claude's orange and the favicon tiles keep their own colors
    /// via `.alwaysOriginal`; the monochrome vector marks render as templates
    /// so the menu tints them with the current label color.
    @MainActor
    func menuIcon(pointSize: CGFloat = 18) -> UIImage? {
        let isTemplate = asset == nil && png == nil && vector?.lowercased() != "claude"
        let mark = AgentIconView(ref: self, size: pointSize, tint: .black)
        let renderer = ImageRenderer(content: mark.frame(width: pointSize, height: pointSize))
        renderer.scale = 3
        guard let image = renderer.uiImage else { return nil }
        return image.withRenderingMode(isTemplate ? .alwaysTemplate : .alwaysOriginal)
    }
}

extension SessionStatus {
    /// Map a wire status string to a status. Both spellings are here because
    /// both are on a wire this app speaks: the companion roster says
    /// `needsAttention`, and fyolod's §4 workstream vocabulary says
    /// `needs_you` for the same state.
    init(wire: String) {
        switch wire {
        case "working": self = .working
        case "done": self = .done
        case "needsAttention", "needs_you": self = .needsAttention
        default: self = .idle
        }
    }
}

extension MockSession {
    init(roster: RosterSession, project: RosterProject, agentsByID: [String: RosterAgent]) {
        let projectBranch = project.branch.isEmpty ? nil : project.branch
        // "—" is the desktop's placeholder for "no branch"; drop it here.
        let worktreeBranch = roster.branch.flatMap { $0 == "—" || $0.isEmpty ? nil : $0 }
        self.init(
            title: roster.title,
            project: project.name,
            agent: agentsByID[roster.agent] ?? RosterAgent.fallback(wire: roster.agent),
            status: SessionStatus(wire: roster.status),
            subtitle: roster.subtitle ?? "",
            time: "",
            rosterID: roster.id,
            projectRosterID: project.id,
            projectPath: project.path,
            // The terminal top bar shows where the session actually runs, so
            // a worktree's branch wins over the project checkout's.
            branch: worktreeBranch ?? projectBranch,
            worktreeBranch: worktreeBranch
        )
    }
}

extension MockProject {
    init(roster: RosterProject, agentsByID: [String: RosterAgent]) {
        self.init(
            name: roster.name,
            path: roster.path,
            rosterID: roster.id,
            branch: roster.branch.isEmpty ? nil : roster.branch,
            kind: roster.kind,
            workspaceID: roster.workspaceID,
            workspaceName: roster.workspaceName,
            deviceAlias: roster.deviceAlias,
            sessions: roster.sessions.map {
                MockSession(roster: $0, project: roster, agentsByID: agentsByID)
            }
        )
    }
}

// MARK: - Mock file tree

/// The bundled sample tree, shown when there is no Mac behind the drawer (the demo
/// sessions and App Store screenshots). Browsed the same way a live project is —
/// one directory per screen — so the offline path exercises the real UI.
final class FileNode {
    let name: String
    let children: [FileNode]?
    let changed: Bool

    var isDirectory: Bool { children != nil }

    init(_ name: String, changed: Bool = false, children: [FileNode]? = nil) {
        self.name = name
        self.changed = changed
        self.children = children
    }

    static let sampleRoot: [FileNode] = [
        FileNode("Sources", children: [
            FileNode("fyolo", children: [
                FileNode("App.swift", changed: true),
                FileNode("Models.swift"),
                FileNode("SessionInfoView.swift", changed: true),
                FileNode("FyoloStore", children: [
                    FileNode("FyoloStore.swift"),
                    FileNode("FyoloStore+TerminalSurface.swift", changed: true),
                    FileNode("FyoloStore+AgentStatus.swift"),
                ]),
            ]),
        ]),
        FileNode("web", children: [
            FileNode("landing", children: [
                FileNode("src", children: [
                    FileNode("app", children: [FileNode("page.tsx")]),
                ]),
            ]),
        ]),
        FileNode("Package.swift"),
        FileNode("README.md"),
    ]

    /// One directory's entries in the same shape the wire delivers, so the browser has a
    /// single code path. "" is the root.
    static func sampleEntries(at path: String) -> [DeviceFileEntry] {
        var level = sampleRoot
        if !path.isEmpty {
            for component in path.split(separator: "/") {
                guard let node = level.first(where: { $0.name == component }),
                      let children = node.children else { return [] }
                level = children
            }
        }
        return level.map {
            DeviceFileEntry(name: $0.name, isDirectory: $0.isDirectory, changed: $0.changed || containsChange($0))
        }
    }

    /// Every file in the tree as a repo-relative path, for the offline filename search.
    static func flattened(_ nodes: [FileNode] = sampleRoot, prefix: String = "") -> [String] {
        nodes.flatMap { node -> [String] in
            let path = prefix.isEmpty ? node.name : "\(prefix)/\(node.name)"
            guard let children = node.children else { return [path] }
            return flattened(children, prefix: path)
        }
    }

    private static func containsChange(_ node: FileNode) -> Bool {
        guard let children = node.children else { return node.changed }
        return children.contains { $0.changed || containsChange($0) }
    }
}

// MARK: - Mock changes

/// The offline Changes pane and its diff — the same `DeviceChange` and unified-diff text a
/// live Mac sends, so the demo renders through the real reader rather than a stand-in.
enum MockChanges {
    static let samples: [DeviceChange] = [
        DeviceChange(path: "Sources/fyolo/App.swift", status: "M", additions: 40, deletions: 12),
        DeviceChange(path: "Sources/fyolo/SessionInfoView.swift", status: "M", additions: 18, deletions: 3),
        DeviceChange(
            path: "Sources/fyolo/FyoloStore/FyoloStore+TerminalSurface.swift",
            status: "M", additions: 62, deletions: 41
        ),
        DeviceChange(path: "Sources/fyolo/SessionHost.swift", status: "A", additions: 120, deletions: 0),
    ]

    /// Full-context sample: one long unchanged run, so the fold band and its reveal are
    /// visible offline exactly as they behave on a real full-context diff.
    static let sampleDiff = """
    @@ -1,44 +1,48 @@
     import AppKit
     import SwiftUI
    \u{20}
     /// The window's content: a sidebar of sessions beside the terminal surface.
     /// Layout is AppKit's, so the sidebar can run the full height of the window.
     struct ContentSplit {
         let store: FyoloStore
    \u{20}
         var sidebarWidth: CGFloat = 220
         var minimumSidebarWidth: CGFloat = 180
         var maximumSidebarWidth: CGFloat = 420
    \u{20}
         func makeSplitViewController() -> NSSplitViewController {
             let controller = NSSplitViewController()
             controller.splitView.dividerStyle = .thin
             return controller
         }
    \u{20}
         func makeSidebarItem(_ viewController: NSViewController) -> NSSplitViewItem {
             let item = NSSplitViewItem(sidebarWithViewController: viewController)
             item.minimumThickness = minimumSidebarWidth
             item.maximumThickness = maximumSidebarWidth
             return item
         }
     }
    \u{20}
     func makeContentSplitViewController(store: FyoloStore) -> NSSplitViewController {
         let split = ContentSplit(store: store)
         let splitViewController = split.makeSplitViewController()
         let sidebar = split.makeSidebarItem(SidebarViewController(store: store))
         sidebar.minimumThickness = 220
    -    window.styleMask.insert(.fullSizeContentView)
    +    sidebar.titlebarSeparatorStyle = .automatic
    +    window.titlebarAppearsTransparent = true
    +    window.styleMask.insert(.fullSizeContentView)
         splitViewController.addSplitViewItem(sidebar)
         splitViewController.addSplitViewItem(NSSplitViewItem(viewController: terminalVC))
         return splitViewController
     }
    \u{20}
     func applyTheme(_ theme: TerminalTheme, to window: NSWindow) {
         controller.setTheme(theme)
    +    // Resolve the dynamic color statically: fullscreen windows on macOS 26
    +    // do not re-evaluate an NSColor's appearance provider.
    +    let resolved = theme.background.resolvedColor(for: window)
    +    window.backgroundColor = resolved
         inspector.refresh()
     }
    """
}

// MARK: - Cross-screen notifications

extension Notification.Name {
    /// Posted by the sidebar on every roster push. `userInfo["statuses"]` is
    /// `[String: SessionStatus]` keyed by roster session id — how an open
    /// terminal tracks its session's live status without owning the socket.
    static let sessionStatusesDidChange = Notification.Name("SessionStatusesDidChange")
}

// MARK: - Companion link state

/// Which protocol reaches a paired peer. The app speaks two and the UI speaks
/// neither — see `docs/design/20260824-ios-as-device-client.md` D1.
enum DeviceKind: String, Codable {
    /// The Mac companion wire: JSON controls and raw PTY bytes on one socket,
    /// with the token on the query string.
    case companion
    /// The fyolod Session Protocol, straight to the box the session runs on.
    case fyolod
}

/// Everything a backend needs to dial one peer. Passed around in place of the
/// bare URL the app used when there was only one protocol to speak.
struct DeviceEndpoint: Equatable {
    let kind: DeviceKind
    /// The URL the socket dials, ready to use.
    let url: URL
    /// The pairing token, for a transport that does not carry it in `url`.
    let token: String?
    /// The `Origin` this peer's listener expects, when it checks one.
    let origin: String?

    init(kind: DeviceKind, url: URL, token: String? = nil, origin: String? = nil) {
        self.kind = kind
        self.url = url
        self.token = token
        self.origin = origin
    }
}

/// One machine this phone has paired with — several stay paired, one is active.
/// `id` is the peer's stable identity (a Mac's `macID`, a box's `host_id`), and
/// until the first roster names it, a locally minted placeholder that
/// `CompanionLink.adoptIdentity` replaces in place.
struct PairedMac: Codable, Equatable {
    var id: String
    var name: String
    /// ws(s)://host:port — for the companion wire the pairing token is held
    /// separately in `token`; for fyolod the path (`/ws`) is part of it.
    var address: String
    var token: String?
    /// Which protocol reaches this peer. Defaulted rather than required: the
    /// stored list decodes with `try?` and returns `[]` on failure, so a new
    /// mandatory field would silently unpair every device already saved.
    var kind: DeviceKind = .companion
    /// The `Origin` a fyolod listener expects, learned at pairing time from
    /// the invite's `url`. nil for the companion wire, which checks none.
    var origin: String?

    /// The companion wire carries its token as the `t` query param, the shape
    /// the Mac's QR encodes; fyolod carries it as a subprotocol, so a fyolod
    /// address dials as stored.
    var connectURL: URL? {
        guard var components = URLComponents(string: address) else { return nil }
        if kind == .companion, let token {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "t", value: token))
            components.queryItems = items
        }
        return components.url
    }

    /// Where and how to reach this peer — nil when the stored address no longer
    /// parses.
    var endpoint: DeviceEndpoint? {
        guard let url = connectURL else { return nil }
        return DeviceEndpoint(kind: kind, url: url, token: token, origin: origin)
    }

    /// "studio.local:8787" — the row caption; scheme is noise and the token
    /// is a secret.
    var displayAddress: String {
        guard let url = URL(string: address), let host = url.host else { return address }
        let port = url.port.map { ":\($0)" } ?? ""
        return host + port
    }
}

extension PairedMac {
    /// Written by hand so a blob saved before `kind` existed still decodes as
    /// the companion Mac it is. Declared in an extension so the memberwise
    /// initialiser survives.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        kind = try container.decodeIfPresent(DeviceKind.self, forKey: .kind) ?? .companion
        origin = try container.decodeIfPresent(String.self, forKey: .origin)
    }
}

/// The app-wide view of the Mac roster link: the paired-Mac list, which one
/// is active, and the active link's live state. The sidebar owns the socket
/// and keeps `state` current; other screens (the Devices settings page)
/// observe the notifications and read back.
enum CompanionLink {
    enum State: Equatable {
        /// No Mac address saved.
        case unpaired
        /// Paired, but the socket is down — connecting or in backoff retry.
        case connecting
        case connected
        /// The Mac answered but refused this pairing. The reason is rendered by
        /// the existing link-status surfaces so reconnecting cannot hide it.
        case failed(String)
    }

    static var state: State = .unpaired {
        didSet {
            guard state != oldValue else { return }
            NotificationCenter.default.post(name: stateDidChange, object: nil)
        }
    }

    static let stateDidChange = Notification.Name("CompanionLinkStateDidChange")
    /// Posted when the active pairing changes (a new pairing, a switch, a
    /// forget); the socket's owner reacts by reconnecting to `savedEndpoint`
    /// or tearing the link down.
    static let pairingDidChange = Notification.Name("CompanionPairingDidChange")
    /// Posted when the paired-Mac list or the active choice changes for any
    /// reason (including an identity adoption that only renames an entry) —
    /// the Devices page reloads on it.
    static let macsDidChange = Notification.Name("CompanionMacsDidChange")

    private static let macsKey = "companion.pairedMacs"
    private static let activeKey = "companion.activeMacID"
    /// The pre-multi-Mac single URL (token embedded as `?t=`); folded into
    /// `pairedMacs` on first read so an update keeps its pairing.
    private static let legacyURLKey = "companion.rosterURL"

    static var pairedMacs: [PairedMac] {
        migrateIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: macsKey),
              let macs = try? JSONDecoder().decode([PairedMac].self, from: data)
        else { return [] }
        return macs
    }

    static var activeMacID: String? {
        migrateIfNeeded()
        return UserDefaults.standard.string(forKey: activeKey)
    }

    /// The Mac the app talks to. A dangling or missing active id falls back
    /// to the first entry so a paired phone never strands itself.
    static var activeMac: PairedMac? {
        let macs = pairedMacs
        guard let id = activeMacID, let match = macs.first(where: { $0.id == id }) else {
            return macs.first
        }
        return match
    }

    /// Where and how to reach the active peer — nil when nothing is paired.
    static var savedEndpoint: DeviceEndpoint? { activeMac?.endpoint }

    /// The one place a pairing is understood: the scanner hands back a raw
    /// string and parses nothing. A companion address pairs the moment it
    /// parses; a `fyolo://device` invite dials first and waits for `hello_ok`,
    /// because saving an unverified address is what left the companion paired
    /// and silently unreachable. Returns false for an address that does not
    /// parse — `completion` carries the real outcome, later, on the main queue.
    @discardableResult
    static func pair(
        rawAddress: String, completion: ((Result<Void, PairingFailure>) -> Void)? = nil
    ) -> Bool {
        if let invite = parseDeviceInvite(rawAddress) {
            pair(invite: invite, completion: completion)
            return true
        }
        guard let url = normalize(rawAddress) else {
            completion?(.failure(.unreadableAddress))
            return false
        }
        let token = token(of: url)
        let address = strippedAddress(of: url)
        if let existing = pairedMacs.first(where: { $0.address == address && $0.token == token }) {
            setActive(existing.id)
            completion?(.success(()))
            return true
        }
        // Dial before filing it, the way an invite does. An address saved
        // unverified is one the app redials on every launch with nothing to
        // show for it, and the person who typed it learns nothing either way.
        verify(companion: url) { result in
            if case .failure(let failure) = result {
                completion?(.failure(failure))
                return
            }
            var macs = pairedMacs
            let mac = PairedMac(
                id: "local-\(UUID().uuidString)",
                name: url.host ?? "Mac",
                address: address,
                token: token
            )
            macs.append(mac)
            save(macs)
            setActive(mac.id)
            completion?(.success(()))
        }
        return true
    }

    /// Dial a companion address and wait for the Mac's roster, which is the Mac
    /// saying yes: the token was good and both ends read each other's `wire`.
    /// A refusal arrives already worded for this phone.
    private static func verify(
        companion url: URL, completion: @escaping (Result<Void, PairingFailure>) -> Void
    ) {
        let client = CompanionClient(url: url)
        // The link self-heals rather than giving up, which is wrong for a
        // pairing someone is waiting on: a Mac that never answers has to become
        // a refusal instead of a socket dialling forever behind a tapped
        // Connect.
        let deadline = DispatchWorkItem {
            retire(client)
            completion(.failure(.unreachable(localized("That Mac didn't answer."))))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: deadline)
        // These closures are the client's only owner, so clearing them frees it.
        client.onRoster = { _ in
            deadline.cancel()
            retire(client)
            completion(.success(()))
        }
        client.onConnectionFailure = { reason in
            deadline.cancel()
            retire(client)
            completion(.failure(.unreachable(reason)))
        }
        client.start()
    }

    /// Drops a one-shot client and the closure cycle keeping it alive.
    private static func retire(_ client: CompanionClient) {
        client.onRoster = nil
        client.onConnectionFailure = nil
        client.stop()
    }

    /// Why a pairing did not take. Each case is a sentence the Devices page can
    /// show as-is: a refused pairing that says nothing is the failure mode this
    /// whole verify-first flow exists to end.
    enum PairingFailure: Error, Equatable {
        case unreadableAddress
        /// The invite named a protocol version this build does not speak.
        case protocolTooNew
        /// The device never answered, or answered by refusing.
        case unreachable(String)

        var message: String {
            switch self {
            case .unreadableAddress:
                return localized("That isn't an address Fyolo can pair with.")
            case .protocolTooNew:
                return localized("This device speaks a newer protocol. Update Fyolo on this phone.")
            case .unreachable(let reason):
                return reason
            }
        }
    }

    /// What `fyolod pair` puts in a `fyolo://device` link. No display name:
    /// the host never supplies one, so `PairedMac.name` stands.
    struct DeviceInvite: Equatable {
        /// The dial URL, already resolved to `ws(s)://…/ws`.
        let url: URL
        let token: String
        let hostID: String
        let proto: UInt32
        /// The listener's allowed origin, derived from the invite's own `url` —
        /// it is the operator's `--wss-origin` rendered back as a base URL, so
        /// the two agree by construction.
        let origin: String

        var address: String { url.absoluteString }
    }

    /// Reads a `fyolo://device?url=…&token=…&host_id=…&proto=…` link, from the
    /// scanner or from a paste. nil for anything else, including a link missing
    /// a field — a half-read QR must not pair against a guess.
    static func parseDeviceInvite(_ raw: String) -> DeviceInvite? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "fyolo",
              components.host?.lowercased() == "device"
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let rawURL = value("url"), let token = value("token"),
              let hostID = value("host_id"),
              let base = URLComponents(string: rawURL),
              let dial = websocketURL(from: base), let origin = originValue(of: base)
        else { return nil }
        return DeviceInvite(
            url: dial,
            token: token,
            hostID: hostID,
            proto: value("proto").flatMap { UInt32($0) } ?? Fyolod.protocolVersion,
            origin: origin
        )
    }

    /// The invite's reachable base rendered as the socket URL: same host and
    /// port, the ws(s) twin of its scheme, and the listener's `/ws` mount under
    /// whatever path the operator published (Tailscale Serve's `/fyolo`).
    private static func websocketURL(from base: URLComponents) -> URL? {
        var dial = base
        switch base.scheme?.lowercased() {
        case "https", "wss": dial.scheme = "wss"
        case "http", "ws": dial.scheme = "ws"
        default: return nil
        }
        dial.query = nil
        dial.fragment = nil
        let prefix = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        dial.path = prefix + "/ws"
        return dial.url
    }

    /// `scheme://host[:port]` — an origin has no path, and the daemon compares
    /// it that way.
    private static func originValue(of base: URLComponents) -> String? {
        guard let scheme = base.scheme?.lowercased(), let host = base.host else { return nil }
        let webScheme = scheme == "wss" ? "https" : (scheme == "ws" ? "http" : scheme)
        let port = base.port.map { ":\($0)" } ?? ""
        return "\(webScheme)://\(host)\(port)"
    }

    /// Verify before saving: dial the box, wait for `hello_ok`, and key the
    /// entry by the identity the daemon answered with rather than the one the QR
    /// claimed, so a box already known by another route is not duplicated.
    private static func pair(
        invite: DeviceInvite, completion: ((Result<Void, PairingFailure>) -> Void)?
    ) {
        guard invite.proto <= Fyolod.protocolVersion else {
            completion?(.failure(.protocolTooNew))
            return
        }
        let endpoint = DeviceEndpoint(
            kind: .fyolod, url: invite.url, token: invite.token, origin: invite.origin)
        FyolodBackend.verify(endpoint: endpoint) { result in
            switch result {
            case .failure(let refusal):
                completion?(.failure(.unreachable(refusal.message)))
            case .success(let hostID):
                adopt(invite: invite, hostID: hostID)
                completion?(.success(()))
            }
        }
    }

    /// Files a verified invite. The daemon's own `host_id` wins over the QR's:
    /// re-scanning a box already paired updates that entry's address and token
    /// rather than leaving two rows for one machine.
    private static func adopt(invite: DeviceInvite, hostID: String) {
        var macs = pairedMacs
        let identity = hostID.isEmpty ? invite.hostID : hostID
        if let index = macs.firstIndex(where: { $0.id == identity }) {
            macs[index].address = invite.address
            macs[index].token = invite.token
            macs[index].kind = .fyolod
            macs[index].origin = invite.origin
            save(macs)
            setActive(identity)
            return
        }
        macs.append(PairedMac(
            id: identity,
            name: invite.url.host ?? localized("Device"),
            address: invite.address,
            token: invite.token,
            kind: .fyolod,
            origin: invite.origin
        ))
        save(macs)
        setActive(identity)
    }

    /// The active connection's roster named its Mac. Adopt the identity into
    /// the active entry — or, when that `macID` is already on the list under
    /// another entry (a re-scan of a known Mac through a placeholder), update
    /// the known entry's address/token in place and drop the placeholder.
    /// Never posts `pairingDidChange`: the socket is already on the right Mac.
    static func adoptIdentity(macID: String, name: String?) {
        var macs = pairedMacs
        guard let activeID = activeMac?.id,
              let activeIndex = macs.firstIndex(where: { $0.id == activeID })
        else { return }
        if let knownIndex = macs.firstIndex(where: { $0.id == macID }), knownIndex != activeIndex {
            macs[knownIndex].address = macs[activeIndex].address
            macs[knownIndex].token = macs[activeIndex].token
            if let name { macs[knownIndex].name = name }
            macs.remove(at: activeIndex)
            save(macs)
            UserDefaults.standard.set(macID, forKey: activeKey)
            NotificationCenter.default.post(name: macsDidChange, object: nil)
            return
        }
        var entry = macs[activeIndex]
        var changed = false
        if entry.id != macID {
            entry.id = macID
            changed = true
        }
        if let name, entry.name != name {
            entry.name = name
            changed = true
        }
        guard changed else { return }
        macs[activeIndex] = entry
        save(macs)
        UserDefaults.standard.set(macID, forKey: activeKey)
        NotificationCenter.default.post(name: macsDidChange, object: nil)
    }

    /// Switch the active Mac — the tap on a row in the Devices page. The socket's
    /// owner tears down and redials on `pairingDidChange`.
    static func switchTo(_ id: String) {
        guard id != activeMac?.id, pairedMacs.contains(where: { $0.id == id }) else { return }
        setActive(id)
    }

    /// Forget one Mac, leaving the others intact. Forgetting the active one
    /// promotes the next entry (or lands unpaired when it was the last).
    static func forget(_ id: String) {
        let wasActive = activeMac?.id == id
        var macs = pairedMacs
        macs.removeAll { $0.id == id }
        save(macs)
        if wasActive {
            if let next = macs.first?.id {
                UserDefaults.standard.set(next, forKey: activeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeKey)
            }
            NotificationCenter.default.post(name: pairingDidChange, object: nil)
        }
        NotificationCenter.default.post(name: macsDidChange, object: nil)
    }

    private static func setActive(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeKey)
        NotificationCenter.default.post(name: macsDidChange, object: nil)
        NotificationCenter.default.post(name: pairingDidChange, object: nil)
    }

    private static func save(_ macs: [PairedMac]) {
        guard let data = try? JSONEncoder().encode(macs) else { return }
        UserDefaults.standard.set(data, forKey: macsKey)
    }

    private static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: legacyURLKey) else { return }
        defaults.removeObject(forKey: legacyURLKey)
        guard defaults.data(forKey: macsKey) == nil, let url = URL(string: raw) else { return }
        let mac = PairedMac(
            id: "local-\(UUID().uuidString)",
            name: url.host ?? "Mac",
            address: strippedAddress(of: url),
            token: token(of: url)
        )
        save([mac])
        defaults.set(mac.id, forKey: activeKey)
    }

    /// The URL minus its `t` query param — what `PairedMac.address` stores,
    /// so the same Mac scanned twice compares equal regardless of token.
    private static func strippedAddress(of url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let remaining = (components.queryItems ?? []).filter { $0.name != "t" }
        components.queryItems = remaining.isEmpty ? nil : remaining
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// Bare-host shorthand: "studio.local" → ws://studio.local:8787. Tunnel
    /// addresses often get pasted with their http(s) scheme; the socket wants
    /// ws(s), same host, same everything else.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let full = trimmed.contains("://") ? trimmed : "ws://\(trimmed):8787"
        guard var components = URLComponents(string: full) else { return nil }
        // A scheme this does not recognize has to fail here, not at dial time:
        // `URLSession.webSocketTask(with:)` answers a non-ws(s) URL with an
        // ObjC exception, which Swift cannot catch. Since a parsed address is
        // saved before anything dials, letting one through crashes the app on
        // every launch afterwards, not just on the pairing that typed it.
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        case "http", "ws": components.scheme = "ws"
        default: return nil
        }
        guard let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    /// The pairing token riding the paired URL's `t` query param — sent as
    /// the first frame on every companion socket; the Mac serves nothing
    /// without it.
    static func token(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "t" }?.value
    }
}
