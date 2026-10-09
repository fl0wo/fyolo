import Foundation
import Network
import FyoloShared
import UIKit

/// One self-healing WebSocket, and the only place the app's link behaviour
/// lives: connect, jittered backoff, network-path wakeups, the foreground
/// retry, the 15 s liveness ping, and the guarantee that whatever the owner
/// puts on the wire from `onOpen` gets there first.
///
/// It knows nothing about which protocol rides it. The roster link and the
/// terminal's byte link each carried their own copy of all six, so every link
/// fix had to be found and made twice.
///
/// It never gives up: a link self-heals rather than dead-ending in a
/// "disconnected" state that needs a manual tap. Only the owner can stop it.
final class WebSocketLink: NSObject {
    struct Configuration {
        /// Names this link in the log, so two live sockets are tellable apart.
        let name: String
        let url: URL
        /// A `file` reply for a 1 MB source is ~1.4 MB of base64 JSON, and the
        /// ring-buffer replay on attach arrives as one frame of up to 1 MB —
        /// the 1 MB default cap would kill the socket mid-read.
        var maximumMessageSize = 8 << 20
        /// Where delegate callbacks and received frames land. The roster link
        /// asks for the main queue so all its state stays on one queue; the
        /// terminal's byte link leaves this nil for a private serial queue, so
        /// PTY output never waits behind UI work.
        var delegateQueue: OperationQueue?
        /// `.common` keeps the liveness probe firing while a finger is down —
        /// what the terminal needs, since scrolling the scrollback would
        /// otherwise hold the probe off for the length of the drag.
        var pingRunLoopMode: RunLoop.Mode = .default
        /// Subprotocols to offer on the Upgrade. fyolod's listener carries the
        /// pairing token here rather than in the query string, so it never
        /// reaches a proxy's request log.
        var subprotocols: [String] = []
        /// Extra request headers. fyolod's listener runs a browser CSRF check
        /// on `Origin` and a native client sends none, so the phone states the
        /// operator's allowed origin — a value it chose, which is why the token
        /// stays the only thing authenticating the pipe.
        var headers: [String: String] = [:]
    }

    /// About to dial. Main queue — reset whatever per-connection state the
    /// protocol keeps before a frame can arrive.
    var onConnecting: (() -> Void)?
    /// The socket is open. Fired on the delegate queue ahead of everything
    /// else, so an auth preamble sent from here is the first frame on the
    /// wire; anything sent after it keeps its order behind it.
    var onOpen: (() -> Void)?
    /// The link is up. Main queue, after `onOpen`.
    var onUp: (() -> Void)?
    /// The link went down and a reconnect is already scheduled. Main queue,
    /// once per drop however many ways the socket reports it.
    var onDown: (() -> Void)?
    /// The app came back to the foreground on a link that was still up — the
    /// only foreground case the link cannot handle itself.
    var onForeground: (() -> Void)?
    /// A text frame, on the delegate queue.
    var onText: ((String) -> Void)?
    /// A binary frame, on the delegate queue.
    var onData: ((Data) -> Void)?

    private let configuration: Configuration
    private lazy var session = URLSession(
        configuration: .default, delegate: self, delegateQueue: configuration.delegateQueue
    )
    private var task: URLSessionWebSocketTask?
    /// Main queue only.
    private var stopped = true
    private var policy = ReconnectPolicy()
    private var foregroundObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var pingTimer: Timer?
    /// A socket announces the same death through both the failed read and the
    /// close delegate; the first one wins so a drop dials exactly one
    /// reconnect. Main queue only, cleared on every dial.
    private var currentTaskDidDie = false
    /// Set the moment the socket opens and cleared the moment it dies, on
    /// whichever queue notices — hence the lock.
    private var open = false
    private let openLock = NSLock()

    /// `true` between the socket opening and its death.
    var isUp: Bool {
        openLock.lock()
        defer { openLock.unlock() }
        return open
    }

    /// `true` before `start()` and after `stop()` — no reconnect is pending
    /// and none will be scheduled.
    var isStopped: Bool { stopped }

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    // MARK: - Lifecycle (main queue)

    func start() {
        stopped = false
        policy.reset()
        connect()
        startPathMonitor()
        startPingTimer()
        startForegroundObserver()
    }

    /// Tear the link down for good. `closeCode` is how the peer is told; a
    /// protocol that is refusing this peer says so with `.policyViolation`
    /// rather than a polite goodbye.
    func stop(closeCode: URLSessionWebSocketTask.CloseCode = .goingAway) {
        stopped = true
        setOpen(false)
        task?.cancel(with: closeCode, reason: nil)
        task = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathStatus = nil
        pingTimer?.invalidate()
        pingTimer = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    /// Dial now, dropping any pending backoff — the "Try Again" affordance on
    /// a stalled zero state.
    func reconnectNow() {
        guard !stopped, !isUp else { return }
        policy.reset()
        connect()
    }

    /// Put a frame on the current socket. Order is preserved, so the owner's
    /// `onOpen` preamble stays ahead of everything queued behind it.
    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    func send(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    // MARK: - Connect

    private func connect() {
        guard !stopped else { return }
        // `webSocketTask(with:)` raises an uncatchable ObjC exception for a URL
        // it cannot dial, so a link that would abort the process stays down
        // instead. Callers validate before they get here; this is the backstop
        // that keeps a bad address a dead link rather than a dead app.
        guard let scheme = configuration.url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss", configuration.url.host != nil
        else {
            Log.companion.error(
                "\(self.configuration.name, privacy: .public) cannot dial \(self.configuration.url.scheme ?? "<no scheme>", privacy: .public):// — the socket needs a ws(s) URL with a host"
            )
            return
        }
        currentTaskDidDie = false
        task?.cancel(with: .goingAway, reason: nil)
        let task = makeTask()
        task.maximumMessageSize = configuration.maximumMessageSize
        setOpen(false)
        self.task = task
        onConnecting?()
        task.resume()
        receive(on: task)
    }

    /// A link that asks for no headers dials exactly the way it always has —
    /// the request-building path exists for fyolod's `Origin` and must not
    /// become the companion wire's path too.
    private func makeTask() -> URLSessionWebSocketTask {
        guard !configuration.headers.isEmpty else {
            return session.webSocketTask(
                with: configuration.url, protocols: configuration.subprotocols)
        }
        var request = URLRequest(url: configuration.url)
        for (name, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !configuration.subprotocols.isEmpty {
            request.setValue(
                configuration.subprotocols.joined(separator: ", "),
                forHTTPHeaderField: "Sec-WebSocket-Protocol"
            )
        }
        return session.webSocketTask(with: request)
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        // Fast burst then a slow heartbeat (see ReconnectPolicy): quick to
        // notice a rebuilt peer, easy on the radio when the laptop's just
        // closed.
        let delay = policy.nextDelay()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !stopped, !isUp else { return }
            connect()
        }
    }

    /// Reconnect the instant the network path comes back (Wi-Fi rejoin,
    /// cellular handoff, VPN toggle) instead of sitting out a scheduled
    /// backoff the phone itself already knows is pointless.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, !stopped else { return }
            let cameUp = path.status == .satisfied
                && lastPathStatus != nil && lastPathStatus != .satisfied
            lastPathStatus = path.status
            guard cameUp, !isUp else { return }
            policy.reset()
            connect()
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// A half-open socket (the peer slept, the network switched under us, the
    /// tunnel dropped the hop) never fails `receive` — the read just waits
    /// forever on a connection nothing will ever answer, and the screen looks
    /// frozen rather than disconnected. A periodic ping is what notices, and
    /// its failure forces the reconnect loop.
    private func startPingTimer() {
        pingTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, !stopped, isUp, let task else { return }
            task.sendPing { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !stopped, task === self.task, isUp else { return }
                    setOpen(false)
                    onDown?()
                    // The phone knows the link is dead right now, so there is
                    // nothing to back off from — dial immediately.
                    policy.reset()
                    connect()
                }
            }
        }
        if configuration.pingRunLoopMode != .default {
            RunLoop.main.add(timer, forMode: configuration.pingRunLoopMode)
        }
        pingTimer = timer
    }

    private func startForegroundObserver() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !stopped else { return }
            guard !isUp else {
                onForeground?()
                return
            }
            // Skip any pending backoff — the socket rarely survives a trip to
            // the background, and the user is looking at the screen now.
            policy.reset()
            connect()
        }
    }

    // MARK: - Read

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): onText?(text)
                case .data(let data): onData?(data)
                @unknown default: break
                }
                receive(on: task)
            case .failure(let error):
                Log.companion.notice(
                    "\(self.configuration.name, privacy: .public) link dropped: \(error.localizedDescription, privacy: .public)"
                )
                died(task)
            }
        }
    }

    /// The socket died — from a failed read or from the close delegate.
    private func died(_ deadTask: URLSessionWebSocketTask) {
        setOpen(false)
        DispatchQueue.main.async { [weak self] in
            guard let self, !stopped, !currentTaskDidDie, deadTask === task else { return }
            currentTaskDidDie = true
            onDown?()
            scheduleReconnect()
        }
    }

    private func setOpen(_ value: Bool) {
        openLock.lock()
        open = value
        openLock.unlock()
    }
}

extension WebSocketLink: URLSessionWebSocketDelegate {
    func urlSession(
        _: URLSession, webSocketTask task: URLSessionWebSocketTask, didOpenWithProtocol _: String?
    ) {
        guard task === self.task else { return }
        Log.companion.notice(
            "\(self.configuration.name, privacy: .public) link connected to \(self.configuration.url.host ?? "?", privacy: .public)"
        )
        setOpen(true)
        onOpen?()
        DispatchQueue.main.async { [weak self] in
            guard let self, !stopped, task === self.task else { return }
            policy.reset()
            onUp?()
        }
    }

    func urlSession(
        _: URLSession, webSocketTask task: URLSessionWebSocketTask,
        didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?
    ) {
        died(task)
    }
}
