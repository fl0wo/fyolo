import Foundation
import FyoloShared

/// Receives the live project/session roster from the Mac companion server over
/// a `WebSocketLink`, so the home tree shows the same list the desktop sidebar
/// does. The link owns connect, reconnect and liveness; this type owns only
/// what is protocol: the auth preamble, the frames that must wait behind it,
/// and the decode.
final class CompanionClient {
    private let url: URL
    private let link: WebSocketLink
    /// `refuse()` sends one final `.error` and immediately cancels the socket,
    /// while request errors leave it open. Keep the last reason briefly so the
    /// close path can distinguish those two cases without expanding the wire.
    private var lastServerError: (message: String, uptime: TimeInterval)?
    private static let refusalCloseWindow: TimeInterval = 1

    /// Latest roster, delivered on the main queue.
    var onRoster: ((CompanionRoster) -> Void)?
    /// `true` once connected, `false` on drop — delivered on the main queue.
    var onConnected: ((Bool) -> Void)?
    /// A `start` we sent succeeded; the new session id is ready to attach.
    /// The second value is the agent the Mac actually launched (nil from an
    /// older Mac) — the only source of truth for an agent-less New Chat.
    var onStarted: ((String, String?) -> Void)?
    /// A directory listing arrived (reply to `.listFiles`).
    var onFileList: ((String, [WireFileEntry]) -> Void)?
    /// File contents arrived (reply to `.readFile`).
    var onFile: ((WireFile) -> Void)?
    /// A write we sent landed (reply to `.writeFile`): path + new mtime (ms).
    var onWritten: ((String, Int) -> Void)?
    /// An upload we sent landed (reply to `.upload`): absolute Mac path.
    var onUploaded: ((String) -> Void)?
    /// Filename-search matches (reply to `.searchFiles`): the echoed query,
    /// repo-relative paths, and whether the batch was capped.
    var onSearchResults: ((String, [String], Bool) -> Void)?
    /// The project's working-tree changes (reply to `.listChanges`).
    var onChanges: (([WireChange]) -> Void)?
    /// One file's unified diff (reply to `.readDiff`).
    var onDiff: ((WireDiff) -> Void)?
    /// The server rejected a request (e.g. a failed `start`).
    var onError: ((String) -> Void)?
    /// The server sent an error and immediately dropped the connection.
    var onConnectionFailure: ((String) -> Void)?
    /// The Mac's parsed `~/.ssh/config` host blocks, answering a
    /// `.sshConfigHosts` request — the read-only menu the Terminals ＋ → New SSH
    /// picks from (the phone never authors a host, only chooses a known alias).
    var onSSHConfig: (([WireSSHHost]) -> Void)?

    /// Controls sent before the socket is open wait here — auth must ride
    /// the wire first on every connect, so a `.upload` fired right after
    /// `start()` would otherwise reach the server ahead of the auth frame
    /// and be refused as unauthorized.
    private var pendingControls: [CompanionControl] = []

    /// Send a control message (e.g. `.start`) over the roster link. Queued
    /// until the connect + auth handshake if the link isn't up yet.
    func send(_ control: CompanionControl) {
        guard link.isUp else {
            pendingControls.append(control)
            return
        }
        link.send(control.encoded())
    }

    init(url: URL) {
        self.url = url
        link = WebSocketLink(configuration: .init(name: "roster", url: url, delegateQueue: .main))
        link.onConnecting = { [weak self] in self?.lastServerError = nil }
        link.onOpen = { [weak self] in self?.sendPreamble() }
        link.onUp = { [weak self] in self?.onConnected?(true) }
        link.onDown = { [weak self] in
            guard let self else { return }
            let connectionFailure = takeErrorForImmediateDrop()
            onConnected?(false)
            if let connectionFailure { onConnectionFailure?(connectionFailure) }
        }
        link.onText = { [weak self] text in self?.receive(text) }
    }

    func start() {
        link.start()
    }

    func stop() {
        link.stop()
        lastServerError = nil
    }

    /// Force an immediate reconnect, dropping any pending backoff — the "Try
    /// Again" affordance on the stalled zero state.
    func reconnectNow() {
        link.reconnectNow()
    }

    /// Auth rides first on every connect; the roster is the server's reply.
    /// Anything queued while the link was down follows in order behind it.
    private func sendPreamble() {
        if let token = CompanionLink.token(of: url) {
            link.send(CompanionControl.auth(token: token, wire: Wire.current).encoded())
        } else {
            // No `?t=` on the paired URL: the socket opens, but the Mac refuses
            // it after its ~10s auth grace window, so the link loops
            // connect→unauthorized→reconnect with no visible cause. Say so.
            Log.companion.error("roster URL has no pairing token (?t=…) — the Mac will refuse this socket after ~10s. Re-pair via Settings ▸ Mobile.")
        }
        let queued = pendingControls
        pendingControls = []
        for control in queued {
            link.send(control.encoded())
        }
    }

    private func takeErrorForImmediateDrop() -> String? {
        defer { lastServerError = nil }
        guard let lastServerError,
              ProcessInfo.processInfo.systemUptime - lastServerError.uptime
                <= Self.refusalCloseWindow else { return nil }
        return lastServerError.message
    }

    private func receive(_ text: String) {
        if let roster = CompanionRoster.decode(text) {
            lastServerError = nil
            if roster.wire < Wire.minimumServer {
                onConnectionFailure?(localized("Update Fyolo on your Mac to connect this phone."))
                stop()
            } else {
                onRoster?(roster)
            }
            return
        }
        lastServerError = nil
        switch CompanionControl.decode(text) {
        case .started(let sessionID, let agent): onStarted?(sessionID, agent)
        case .fileList(let path, let entries): onFileList?(path, entries)
        case .file(let file): onFile?(file)
        case .written(let path, let mtime): onWritten?(path, mtime)
        case .uploaded(let path): onUploaded?(path)
        case .searchResults(let query, let paths, let truncated):
            onSearchResults?(query, paths, truncated)
        case .changes(let files): onChanges?(files)
        case .diff(let diff): onDiff?(diff)
        case .error(let reason, let code):
            let refusal = CompanionRefusal.text(code: code, fallback: reason)
            lastServerError = (
                message: refusal,
                uptime: ProcessInfo.processInfo.systemUptime
            )
            onError?(refusal)
        case .sshConfigList(let hosts): onSSHConfig?(hosts)
        default: break
        }
    }
}

/// The Mac's refusals, worded here. A refusal is the one server message a
/// person has to read and act on, and the Mac has no idea what language this
/// phone is in — so it names the reason and the phone says it. An older Mac
/// names nothing, and its English sentence is all there is to show.
enum CompanionRefusal {
    static func text(code: String?, fallback: String) -> String {
        switch code {
        case WireRefusal.unauthorized:
            return localized(
                "This Mac didn't recognize this phone. Scan its QR code again in Settings ▸ Mobile.")
        case WireRefusal.clientTooOld:
            return localized("Update Fyolo on this phone to connect to this Mac.")
        default:
            return fallback
        }
    }
}
