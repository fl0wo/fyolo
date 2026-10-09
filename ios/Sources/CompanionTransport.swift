import Foundation
import FyoloShared

/// v1 companion transport: a `WebSocketLink` to the Mac companion server
/// (directly on LAN, or via a tunnel URL). Binary frames are raw PTY bytes;
/// text frames are `CompanionControl` JSON. `TerminalViewController` bridges it
/// to an `InMemoryTerminalSession`.
///
/// The link self-heals and re-attaches, and the server replays its ring buffer
/// on attach so the screen repaints. Only a server-sent `exit` (the session
/// ended) or `error` (the session no longer exists — e.g. the Mac app
/// restarted) ends the loop.
///
/// E2E encryption (CryptoKit) wraps the payloads in the next pass; the PoC
/// proves the transport + PTY bridge first.
final class CompanionTransport {
    enum State {
        case connecting
        case connected
        /// The socket dropped; a reconnect is scheduled. Not fatal.
        case reconnecting
        /// The server rejected us (e.g. the session died with a Mac restart). Fatal.
        case failed(String)
        /// The session exited on the Mac. Fatal.
        case closed
    }

    private let url: URL
    /// Roster session id to bridge; sent as an `attach` control the moment the
    /// socket opens. nil connects to a server that streams without attach
    /// (the standalone companion PoC).
    private let attachSessionID: String?
    private let link: WebSocketLink
    /// Last viewport the terminal declared, re-sent on every (re)connect and on
    /// foreground: the first layout often fires before the socket exists and
    /// would be silently lost, and a reconnect never re-fires it (the view's
    /// size didn't change). The Mac forwards it as its bridge attachment's own
    /// viewport; the session's size is the viewport of the screen someone is in
    /// front of, and the write token has nothing to do with it.
    ///
    /// `surface` rides along because the bridge has no surface of its own to
    /// read it from: while this screen shows a session bigger than itself the
    /// two are different grids, and the Mac needs the second one to know when a
    /// keyframe can finally be painted here.
    private var gridCols = 0
    private var gridRows = 0
    private var gridRendering = true
    private var surfaceCols = 0
    private var surfaceRows = 0
    private let gridLock = NSLock()
    /// Guards send order: `auth` must be the first frame on the socket. The
    /// terminal view calls `resize` (→ `sendGrid`) as it lays out, which can land
    /// after the dial but before the socket opens — URLSession then flushes that
    /// queued `resize` *ahead* of the `auth` the open sends. The server refuses
    /// any non-`auth` control on an unauthenticated connection, so that stray
    /// `resize` trips "unauthorized" before `auth` is ever read (the roster socket
    /// never sends anything but `auth`, which is why the list works and the
    /// terminal didn't). So grid and keystroke frames stay suppressed until the
    /// open has queued the auth preamble and set this true. Guarded by `gridLock`.
    private var authSent = false
    /// Raw PTY input stays closed until the Mac acknowledges auth with its
    /// roster. Control messages remain optimistic because their version-0
    /// meanings are stable. Guarded by `gridLock`.
    private var authAccepted = false

    /// Remote PTY bytes for the terminal. Fired on the link's delegate queue.
    var onOutput: ((Data) -> Void)?
    /// State transitions, delivered on the main queue.
    var onState: ((State) -> Void)?
    /// The PTY's grid and whether this phone is sizing it, from the Mac's
    /// `grid` control; delivered on the main queue.
    var onSharedGrid: ((TerminalGrid, Bool) -> Void)?

    init(url: URL, attachSessionID: String? = nil) {
        self.url = url
        self.attachSessionID = attachSessionID
        link = WebSocketLink(configuration: .init(
            name: "session", url: url, delegateQueue: nil, pingRunLoopMode: .common
        ))
        link.onConnecting = { [weak self] in
            // A fresh socket has not sent its auth preamble yet — suppress grid
            // and keystroke frames until it does, so nothing precedes `auth`.
            guard let self else { return }
            gridLock.lock()
            authSent = false
            authAccepted = false
            gridLock.unlock()
        }
        link.onOpen = { [weak self] in self?.sendPreamble() }
        link.onUp = { [weak self] in self?.notify(.connected) }
        link.onDown = { [weak self] in self?.notify(.reconnecting) }
        link.onForeground = { [weak self] in
            // The link survived the background trip. If this phone still holds
            // the write token the PTY may have moved while it was away; if not,
            // the Mac ignores the report.
            self?.reassertGrid()
        }
        link.onData = { [weak self] data in self?.onOutput?(data) }
        link.onText = { [weak self] text in self?.receive(text) }
    }

    func start() {
        notify(.connecting)
        link.start()
    }

    func send(_ data: Data) {
        gridLock.lock()
        let ready = authAccepted
        gridLock.unlock()
        guard ready else { return }
        // Binary frames are raw PTY bytes permanently. Compression, encryption,
        // or multiplexing needs a separately negotiated mechanism and Wire gate
        // so a stale Mac can never interpret framing as keystrokes.
        link.send(data)
    }

    /// This screen's viewport. The Mac's bridge has no surface of its own, so it
    /// forwards this as its own attachment's viewport and the daemon sizes the
    /// session to the screen a person is in front of.
    func setViewport(cols: Int, rows: Int) {
        gridLock.lock()
        gridCols = cols
        gridRows = rows
        gridLock.unlock()
        sendGrid()
    }

    /// The grid the surface is actually laid out at — this screen's own while it
    /// fills the host, the session's while it is showing something bigger and
    /// scaling it down. Never a declaration of what this screen has room for.
    func noteSurfaceGrid(cols: Int, rows: Int) {
        gridLock.lock()
        let changed = surfaceCols != cols || surfaceRows != rows
        surfaceCols = cols
        surfaceRows = rows
        gridLock.unlock()
        guard changed else { return }
        sendGrid()
    }

    /// Whether this screen is showing the session. A parked screen keeps its
    /// viewport and stops counting toward the session's size.
    func setRendering(_ showing: Bool) {
        gridLock.lock()
        gridRendering = showing
        gridLock.unlock()
        sendGrid()
    }

    /// Re-sends this phone's viewport — on reconnect, foreground, and re-opening
    /// a parked session. A viewport the Mac already has costs nothing.
    func reassertGrid() {
        sendGrid()
    }

    private func sendGrid() {
        gridLock.lock()
        let cols = gridCols
        let rows = gridRows
        let rendering = gridRendering
        let laidOutCols = surfaceCols
        let laidOutRows = surfaceRows
        let ready = authSent
        gridLock.unlock()
        guard ready, cols > 0, rows > 0 else { return }
        // Omitted while the surface fills the host, which is the common case and
        // what a Mac built before the field assumes.
        let surface = (laidOutCols > 0 && laidOutRows > 0 && (laidOutCols, laidOutRows) != (cols, rows))
            ? TerminalGrid(rows: UInt16(clamping: laidOutRows), cols: UInt16(clamping: laidOutCols))
            : nil
        link.send(
            CompanionControl.resize(
                cols: cols, rows: rows, rendering: rendering, surface: surface).encoded())
    }

    func stop() {
        link.stop()
    }

    /// The preamble every (re)connect puts on the wire, in this order: auth,
    /// the attach it gates, and the grid claim the Mac's repaint is driven by.
    ///
    /// Nothing resets the screen first. The daemon's attach snapshot carries its
    /// own prologue (`SNAPSHOT_PROLOGUE` in `fyolod/vt/src/lib.rs`), built to
    /// land identically on a client in any prior state and deliberately stopping
    /// short of RIS — the palette, title and scrollback it would clear are the
    /// client's, not the host's. The `ESC c` that used to precede the old
    /// raw-scrollback replay bought nothing here and cost a flash on every
    /// reconnect the phone's foreground churn produces.
    private func sendPreamble() {
        // Auth precedes the attach on the same socket — the server refuses
        // the bridge (and everything else) until the token lands.
        if let token = CompanionLink.token(of: url) {
            link.send(CompanionControl.auth(token: token, wire: Wire.current).encoded())
        } else {
            // No `?t=` on the URL: the Mac drops this socket after its ~10s
            // auth grace window, so the session just churns "Reconnecting…"
            // with no visible cause. Say so.
            Log.companion.error("session URL has no pairing token (?t=…) — the Mac will refuse this socket after ~10s. Re-pair via Settings ▸ Mobile.")
        }
        // Auth is now queued ahead of everything else, so grid/keystroke frames
        // may flow. The link preserves send order, so the attach and grid below
        // land after auth; and any external `resize` that fired during the
        // connect stayed suppressed until this moment.
        gridLock.lock()
        authSent = true
        gridLock.unlock()
        if let attachSessionID {
            link.send(CompanionControl.attach(sessionID: attachSessionID).encoded())
        }
        sendGrid()
    }

    private func receive(_ text: String) {
        if let roster = CompanionRoster.decode(text) {
            if roster.wire < Wire.minimumServer {
                finish(
                    .failed(localized("Update Fyolo on your Mac to connect this phone.")),
                    closeCode: .policyViolation
                )
            } else {
                gridLock.lock()
                authAccepted = true
                gridLock.unlock()
            }
            return
        }
        switch CompanionControl.decode(text) {
        case .exit:
            finish(.closed)
        case .grid(let cols, let rows, let writer):
            let grid = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: cols))
            DispatchQueue.main.async { [onSharedGrid] in onSharedGrid?(grid, writer) }
        case .error(let message, let code):
            finish(.failed(CompanionRefusal.text(code: code, fallback: message)))
        default:
            break
        }
    }

    /// A fatal control arrived — the session itself is over, stop reconnecting.
    private func finish(
        _ state: State, closeCode: URLSessionWebSocketTask.CloseCode = .goingAway
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !link.isStopped else { return }
            link.stop(closeCode: closeCode)
            notify(state)
        }
    }

    private func notify(_ state: State) {
        DispatchQueue.main.async { [onState] in onState?(state) }
    }
}
