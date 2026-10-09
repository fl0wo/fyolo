import Foundation
import Network
import FyoloShared

/// Which server a phone reaches this Mac through, readable from anywhere.
///
/// The switch itself is `MobileAccess.attachesDirectly`, which is what the
/// Settings pane binds and what the app observes; this is the same fact read
/// straight from defaults, for the places that need it outside the main actor —
/// the tunnel's provider specs, which are built while deciding what to spawn.
enum PhoneServing {
    static let defaultsKey = "companion.directAttach"

    /// Absent key → the companion wire, so an upgrade changes nothing about how
    /// a paired phone reaches this Mac.
    nonisolated static var isDirect: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// The port the phone dials, and therefore the one a tunnel has to front.
    nonisolated static var port: UInt16 {
        isDirect ? AppChannel.devicePort : AppChannel.companionPort
    }
}

/// The far end of a splice: the daemon socket to copy onto, and the secret that
/// pairs with it.
///
/// Passed in rather than derived inside the splice, so pointing one at another
/// socket does not mean redirecting every Fyolod client in the process through
/// `FYOLOD_SOCK`.
struct DaemonSocket: Sendable {
    let path: @Sendable () -> String
    /// The pairing secret a phone must present, read per handshake so a
    /// rotation lands on the next dial.
    let token: @Sendable () -> String?
    /// Bring the daemon up when nothing answers, the way the CLI and the attach
    /// path do. nil for a socket this app does not own and must not start.
    let autostart: (@Sendable () throws -> Void)?

    /// The daemon this app ships and runs.
    static let local = DaemonSocket(
        path: { Fyolod.socketPath() },
        token: { Fyolod.pairToken() },
        autostart: {
            // Connect-and-close: `connectWithAutostart` is the whole start
            // sequence, and the descriptor it hands back is not the one the
            // splice copies on.
            let descriptor = try Fyolod.connectWithAutostart()
            close(descriptor)
        }
    )
}

/// The Session Protocol, terminated on this Mac for a phone that dials it
/// directly — the same thing `fyolod`'s own listener does, for the one case
/// that listener cannot cover.
///
/// The daemon binds loopback and refuses anything else (`wss.rs:parse_bind`),
/// because the rule that keeps TLS out of `fyolod` is that a tunnel or a proxy
/// always sits in front of it. A phone on the same Wi-Fi has neither, and asking
/// someone to publish a relay to reach a Mac three feet away is not an answer.
/// So this terminates the WebSocket where the invariant allows it — in the app —
/// and splices it onto the daemon's Unix socket.
///
/// **It is a splice, not a second server.** After the Upgrade this copies bytes.
/// Nothing here reads a frame, so nothing here can disagree with the daemon
/// about what one means, and one WebSocket message is not one protocol frame —
/// the phone's `FrameReader` cuts the stream apart exactly as it does when the
/// daemon is doing the copying.
@MainActor
final class DeviceSpliceServer {
    /// Where a phone dials this Mac: 8895 for release, 8896 for dev, both clear
    /// of the companion port and of the daemon's own 8790.
    nonisolated static var defaultPort: UInt16 { AppChannel.devicePort }

    /// The port is held by someone else, or the listener died. Same contract as
    /// `CompanionServer.onListenerFailed`: whoever owns the wiring takes the
    /// public URL down, because a server that cannot bind must not leave one
    /// pointing at it.
    var onListenerFailed: (() -> Void)?

    private let port: UInt16
    private let daemon: DaemonSocket
    private var listener: NWListener?
    private var splices: [ObjectIdentifier: Splice] = [:]
    /// The handshake runs off the main queue: it reads the token from disk.
    private let handshakeQueue = DispatchQueue(label: "sh.fyolo.device.handshake")

    init(port: UInt16 = DeviceSpliceServer.defaultPort, daemon: DaemonSocket = .local) {
        self.port = port
        self.daemon = daemon
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        // A dev relaunch rebinds while the old instance's sockets sit in
        // TIME_WAIT; without reuse the new listener dies silently.
        parameters.allowLocalEndpointReuse = true
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = Fyolod.maximumFrameSize

        let token = daemon.token
        websocket.setClientRequestHandler(handshakeQueue) { subprotocols, _ in
            // Read per handshake rather than once at start, the way the daemon
            // reads it, so `fyolod pair --rotate` signs phones out on their
            // next dial instead of on the app's next launch.
            guard let expected = token(),
                  let offered = subprotocols.first(where: {
                      Self.carries(token: expected, in: $0)
                  })
            else {
                // A status line and nothing else goes back; which check failed
                // is the operator's business, and this is where they read it.
                Log.companion.notice("device splice refused a dial with no valid pairing token")
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: offered)
        }
        // `Origin` is not checked here, and that is not an omission. The
        // daemon's check is a CSRF defence for a listener a browser page can
        // reach behind a published name; this one is reachable only from the
        // local network, and the secret it demands rides the subprotocol, which
        // a page that does not already hold the token cannot produce.
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        guard let endpoint = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: endpoint)
        else {
            Log.companion.error("device splice failed to bind port \(self.port, privacy: .public)")
            onListenerFailed?()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.companion.notice("device splice on ws://0.0.0.0:\(self.port, privacy: .public)/ws")
            case .failed(let error):
                Log.companion.error("device splice listener failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in self.onListenerFailed?() }
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for splice in splices.values { splice.finish() }
        splices.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        let splice = Splice(phone: connection, daemon: daemon) { [weak self] in
            Task { @MainActor in self?.splices[identifier] = nil }
        }
        splices[identifier] = splice
        splice.start()
    }

    /// Constant-time in the length that matters. Not crypto — a loop and an OR —
    /// but a network-facing secret comparison should not hand out a prefix
    /// oracle, and this mirrors `secret_eq` in `wss.rs` rather than inventing a
    /// second rule for the same check.
    nonisolated static func carries(token expected: String, in subprotocol: String) -> Bool {
        let prefix = "fyolod."
        guard subprotocol.hasPrefix(prefix) else { return false }
        let candidate = Array(subprotocol.dropFirst(prefix.count).utf8)
        let wanted = Array(expected.utf8)
        guard candidate.count == wanted.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(candidate, wanted) { difference |= left ^ right }
        return difference == 0
    }
}

/// One phone's WebSocket and the daemon socket it is copying onto.
///
/// Both halves are `NWConnection`s on one serial queue, so every descriptor and
/// its teardown belong to the framework and all the state below is queue-
/// confined rather than locked. Each pump chains its next read to the completion
/// of the write it caused: that, and nothing else, is the backpressure story —
/// a phone on a slow hop stops the daemon being read rather than growing a
/// buffer nobody bounded.
private final class Splice: @unchecked Sendable {
    /// The daemon's listener pings on this cadence for the same reason: quiet
    /// shells emit nothing for minutes and every NAT in between forgets the
    /// mapping.
    private static let pingInterval: DispatchTimeInterval = .seconds(30)
    /// Two and a half missed pings, matching `LinkLiveness.silenceLimit`. A
    /// phone that leaves coverage never sends a FIN, and the attachment it left
    /// behind still holds the session's write token.
    private static let silenceLimit: TimeInterval = 50
    private static let chunk = 64 * 1024

    private let phone: NWConnection
    private let endpoint: DaemonSocket
    private let daemon: NWConnection
    private let queue = DispatchQueue(label: "sh.fyolo.device.splice")
    private let onFinish: @Sendable () -> Void
    private var finished = false
    /// Whether the daemon side has been opened, so a second trigger cannot dial
    /// it twice.
    private var dialled = false
    /// Whether the daemon socket is up and bytes may flow.
    private var ready = false
    /// The phone's first message, held while the daemon socket opens.
    private var pending = Data()
    private var lastHeard = ProcessInfo.processInfo.systemUptime
    private var heartbeat: DispatchSourceTimer?

    init(phone: NWConnection, daemon endpoint: DaemonSocket,
         onFinish: @escaping @Sendable () -> Void) {
        self.phone = phone
        self.endpoint = endpoint
        self.onFinish = onFinish
        daemon = NWConnection(to: .unix(path: endpoint.path()), using: .tcp)
    }

    /// Nothing touches the daemon until the phone has actually said something.
    ///
    /// A rejected handshake still reaches `.ready` here — Network delivers the
    /// connection, answers 400, and only then fails it — so readiness is not
    /// proof that the token was accepted. The first inbound message is: a peer
    /// refused at the Upgrade never sends one. Waiting for it is what stops an
    /// unpaired dial opening a daemon connection, and starting the daemon, by
    /// connecting to the port with any token at all. No byte crossed either
    /// way, which is why only a test asking the far side what it saw could
    /// catch it (`DeviceSpliceIntegrationTests`).
    func start() {
        phone.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Before the daemon exists, so a connection that says nothing
                // at all is still reaped rather than held forever.
                startHeartbeat()
                pumpPhone()
            case .failed, .cancelled:
                finish()
            default:
                break
            }
        }
        phone.start(queue: queue)
    }

    private func openDaemon() {
        guard !finished, !dialled else { return }
        dialled = true
        // The daemon may not be running yet — a phone can dial a Mac whose app
        // has opened no session since boot — and starting it blocks, so it
        // happens off this queue.
        guard let autostart = endpoint.autostart else {
            connectDaemon()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try autostart()
            } catch {
                Log.companion.error("device splice found no daemon to splice onto: \(error.localizedDescription, privacy: .public)")
                finish()
                return
            }
            queue.async { self.connectDaemon() }
        }
    }

    private func connectDaemon() {
        guard !finished else { return }
        daemon.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready = true
                let queued = pending
                pending = Data()
                pumpDaemon()
                // The message that triggered the dial, held while the socket
                // was opening — the `hello` the daemon is waiting on.
                if queued.isEmpty {
                    pumpPhone()
                } else {
                    write(queued)
                }
            case .failed(let error):
                Log.companion.error("device splice lost the daemon: \(error.localizedDescription, privacy: .public)")
                finish()
            case .cancelled:
                finish()
            default:
                break
            }
        }
        daemon.start(queue: queue)
    }

    /// Phone → daemon, one message at a time: the next receive is chained to
    /// this write completing, so a daemon that stops draining stops the phone
    /// being read rather than growing a buffer nobody bounded.
    private func write(_ data: Data) {
        daemon.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { finish() } else { pumpPhone() }
        })
    }

    /// Daemon → phone.
    private func pumpDaemon() {
        daemon.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) {
            [weak self] data, _, isComplete, error in
            guard let self, !finished else { return }
            if let data, !data.isEmpty {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(
                    identifier: "splice", metadata: [metadata])
                phone.send(content: data, contentContext: context, completion: .contentProcessed {
                    [weak self] error in
                    guard let self else { return }
                    if error != nil { finish() } else { pumpDaemon() }
                })
                return
            }
            if error != nil || isComplete { finish() } else { pumpDaemon() }
        }
    }

    private func pumpPhone() {
        phone.receiveMessage { [weak self] data, context, _, error in
            guard let self, !finished else { return }
            lastHeard = ProcessInfo.processInfo.systemUptime
            let metadata = context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close || error != nil {
                finish()
                return
            }
            guard let data, !data.isEmpty else {
                pumpPhone()
                return
            }
            guard ready else {
                // Hold it and open the socket. Receiving does not resume until
                // the daemon is ready, so anything sent meanwhile waits in the
                // phone's socket buffer rather than in an unbounded one here.
                pending = data
                openDaemon()
                return
            }
            write(data)
        }
    }

    /// Ping the phone, and reap the splice when nothing answers. TCP keepalive
    /// proves only that the next hop answers, which over a tunnel is a process
    /// on this very machine.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !finished else { return }
            if ProcessInfo.processInfo.systemUptime - lastHeard > Self.silenceLimit {
                Log.companion.notice("reaping a silent phone splice")
                finish()
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            metadata.setPongHandler(queue) { [weak self] _ in
                self?.lastHeard = ProcessInfo.processInfo.systemUptime
            }
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
            phone.send(content: Data("hb".utf8), contentContext: context, completion: .idempotent)
        }
        timer.resume()
        heartbeat = timer
    }

    /// Idempotent, and reached from either side: whichever end dies takes the
    /// other with it, because half a splice is a session nobody is reading.
    ///
    /// Always through the queue, including from the pumps already on it. The
    /// server tears splices down from the main actor when Mobile Access goes
    /// off, and every field below is queue-confined — the hop is what makes
    /// that true rather than nearly true.
    func finish() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            heartbeat?.cancel()
            heartbeat = nil
            phone.cancel()
            // Safe before `start`: cancelling an unstarted connection is how a
            // splice refused at the handshake tears down, and the daemon side
            // of that one was never dialled.
            daemon.cancel()
            onFinish()
        }
    }
}
