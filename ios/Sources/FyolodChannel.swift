import Foundation
import FyoloShared

/// One WebSocket speaking the fyolod Session Protocol, and the only place the
/// phone turns a stream of bytes back into frames.
///
/// The daemon's listener is a splice, not a second protocol: it copies the same
/// framed stream a Unix socket carries into binary messages of whatever size its
/// copy loop happened to read, so a message boundary means nothing here — one
/// may hold three frames or a third of one, and `Fyolod.FrameReader` cuts them
/// apart. Everything link-shaped belongs to `WebSocketLink`; what lives here is
/// the `hello` that must be frame #1, the reassembly, and the decode.
///
/// Every callback below fires on the link's delegate queue except `onLinkState`
/// going down and `onFailure`, which arrive on the main queue where the link
/// schedules its reconnect.
final class FyolodChannel {
    /// One control frame, and the request it is an answer to.
    ///
    /// The two travel together because the `re` lives on the payload rather than
    /// on any decoded case: `decodeControl` throws it away, so reading it after
    /// the decode is impossible and reading it before is the only option. A pair
    /// rather than a second closure argument because both halves need naming —
    /// an unlabelled `UInt64?` at a call site says nothing about which direction
    /// it points.
    struct Reply {
        /// The `seq` the answered request was sent with. `nil` for a frame that
        /// answers nobody, and for a daemon too old to stamp its replies.
        let responseID: UInt64?
        let control: Fyolod.IncomingControl
    }

    /// The daemon answered the handshake. Fired on the link's delegate queue,
    /// which is where the frames behind it arrive too, so an owner replying from
    /// here keeps its reply ahead of everything else it sends.
    var onReady: ((Fyolod.HelloOkPayload) -> Void)?
    /// A decoded control frame and the request it answers, on the delegate
    /// queue.
    var onControl: ((Reply) -> Void)?
    /// A decoded `E` frame, on the delegate queue.
    var onEvent: ((Fyolod.IncomingEvent) -> Void)?
    var onData: ((Data) -> Void)?
    var onSnapshot: ((Data) -> Void)?
    var onFileChunk: ((Data) -> Void)?
    /// `true` means the handshake landed, and arrives immediately ahead of
    /// `onReady`.
    var onLinkState: ((Bool) -> Void)?
    /// The device refused this connection outright. The reason has to survive
    /// the reconnect loop or it reads as an unexplained outage.
    var onFailure: ((String) -> Void)?

    /// The only way to tell whether a `writer_changed` naming a client means us.
    private(set) var clientID: String?
    /// For the verbs that must name a path over there. Empty until the
    /// handshake lands.
    private(set) var homeDirectory = "/"

    private let name: String
    private let role: String
    private let capabilities: [String]
    private let link: WebSocketLink
    /// Delegate-queue only, and reset on every dial: a socket that died
    /// mid-frame leaves bytes that mean nothing to the next one.
    private var reader = Fyolod.FrameReader()

    init(
        endpoint: DeviceEndpoint,
        name: String,
        role: String,
        capabilities: [String],
        delegateQueue: OperationQueue?,
        pingRunLoopMode: RunLoop.Mode = .default
    ) {
        self.name = name
        self.role = role
        self.capabilities = capabilities
        var configuration = WebSocketLink.Configuration(
            name: name, url: endpoint.url, delegateQueue: delegateQueue,
            pingRunLoopMode: pingRunLoopMode
        )
        // The token rides the negotiated subprotocol. A query string on the
        // Upgrade line leaks it into proxy logs, so it never goes there.
        if let token = endpoint.token {
            configuration.subprotocols = ["fyolod.\(token)"]
        }
        // The listener's CSRF check refuses a missing Origin and `URLSession`
        // sends none from a native app, so the phone states the operator's own
        // allowed origin. The token stays the only thing authenticating the pipe.
        if let origin = endpoint.origin {
            configuration.headers["Origin"] = origin
        }
        link = WebSocketLink(configuration: configuration)
        link.onConnecting = { [weak self] in self?.onLinkState?(false) }
        link.onOpen = { [weak self] in self?.sendHello() }
        link.onDown = { [weak self] in self?.onLinkState?(false) }
        link.onData = { [weak self] data in self?.receive(data) }
        link.onText = { [weak self] _ in
            // The protocol is binary end to end. A text frame means the peer is
            // not the daemon this channel was built for.
            Log.device.error("\(self?.name ?? "?", privacy: .public) channel got a text frame")
        }
    }

    var isUp: Bool { link.isUp }

    func start() { link.start() }

    func stop(closeCode: URLSessionWebSocketTask.CloseCode = .goingAway) {
        link.stop(closeCode: closeCode)
    }

    func reconnectNow() { link.reconnectNow() }

    func send(kind: Fyolod.FrameKind, payload: Data) {
        link.send(Fyolod.frame(kind: kind, payload: payload))
    }

    /// Throws rather than swallowing an encode failure: the caller holds the
    /// request that will now never be answered, and knows what to say about it.
    func send(control operation: some Encodable) throws {
        send(kind: .control, payload: try Fyolod.encodeControl(operation))
    }

    /// `hello` is frame #1 on every connect. `onOpen` fires inside
    /// `didOpenWithProtocol` on the delegate queue and `URLSession` preserves
    /// send order, so nothing the owner queues afterwards can overtake it.
    private func sendHello() {
        reader.reset()
        do {
            send(kind: .control, payload: try Fyolod.helloPayload(
                role: role, caps: capabilities, client: Self.clientBanner))
        } catch {
            Log.device.error("""
            encoding hello for \(self.name, privacy: .public) failed: \
            \(error.localizedDescription, privacy: .public)
            """)
        }
    }

    private func receive(_ chunk: Data) {
        let frames: [(kind: Fyolod.FrameKind, payload: Data)]
        do {
            frames = try reader.append(chunk)
        } catch {
            // Alignment is gone: every frame after this one would be read at a
            // garbage offset, so the connection is over rather than degraded.
            Log.device.error("""
            \(self.name, privacy: .public) channel lost frame alignment: \
            \(error.localizedDescription, privacy: .public)
            """)
            fail(localized("The device sent something Fyolo could not read."))
            return
        }
        for frame in frames {
            switch frame.kind {
            case .data: onData?(frame.payload)
            case .snapshot: onSnapshot?(frame.payload)
            case .file: onFileChunk?(frame.payload)
            case .control: receiveControl(frame.payload)
            case .event: receiveEvent(frame.payload)
            case .upload, .history, .grid, .resize:
                // `R` is client-to-host only, and `H`/`G` need capabilities this
                // client never offers, so one arriving is a frame nobody asked
                // for rather than something to drop silently.
                Log.device.error("""
                unnegotiated \(String(UnicodeScalar(frame.kind.rawValue)), privacy: .public) \
                frame on \(self.name, privacy: .public)
                """)
            }
        }
    }

    private func receiveControl(_ payload: Data) {
        let control: Fyolod.IncomingControl
        do {
            control = try Fyolod.decodeControl(payload)
        } catch {
            Log.device.error("""
            undecodable control on \(self.name, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
            return
        }
        switch control {
        case .helloOk(let handshake):
            clientID = handshake.clientId
            homeDirectory = handshake.homeDirectory
            onLinkState?(true)
            onReady?(handshake)
        case .helloError(let reason):
            fail(reason)
        default:
            onControl?(Reply(
                responseID: Fyolod.responseID(of: payload), control: control))
        }
    }

    private func receiveEvent(_ payload: Data) {
        do {
            onEvent?(try Fyolod.decodeEvent(payload))
        } catch {
            Log.device.error("""
            undecodable event on \(self.name, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
        }
    }

    private func fail(_ reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !link.isStopped else { return }
            link.stop(closeCode: .policyViolation)
            onFailure?(reason)
        }
    }

    /// What this client calls itself in `hello`. The shared codec supplies no
    /// banner — claiming to be a particular client is not its to do.
    private static let clientBanner: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        return "fyolo-ios/\(version as? String ?? "dev")"
    }()
}
