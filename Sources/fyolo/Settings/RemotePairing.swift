import AppKit
import SwiftUI
import FyoloShared

/// Minting the invite a phone scans — for a box reached over SSH, and for this
/// Mac itself.
///
/// The invite is minted **on the box**, by the `fyolod` already deployed there:
/// `fyolod pair --json` prints the URL it is reachable at, the token it will
/// demand, and its `host_id`. This Mac only carries the answer over the SSH it
/// already has and draws the QR — it never invents a token, and it never decides
/// where a remote box is reachable, because only the box knows either.
///
/// That is the ladder `fyolod`'s own `run_pair` describes: a Mac with SSH runs
/// `--json` and pushes the invite; an operator sitting on the box runs `--qr`
/// and scans the screen in front of them. This is the first rung, wired to a UI.
enum RemotePairing {
    /// What `fyolod pair --json` prints. `host_id` is the box's identity, not a
    /// name — the phone names the box itself (device architecture §4).
    struct Invite: Equatable {
        let url: String
        let token: String
        let hostID: String
        let proto: Int

        /// The `fyolo://device` link the iPhone parses, from a scanned QR or a
        /// paste. Built here rather than asked of the box so it stays in step
        /// with `Models.parseDeviceInvite` on the phone.
        var link: String {
            var components = URLComponents()
            components.scheme = "fyolo"
            components.host = "device"
            components.queryItems = [
                URLQueryItem(name: "url", value: url),
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "host_id", value: hostID),
                URLQueryItem(name: "proto", value: String(proto)),
            ]
            return components.string ?? ""
        }
    }

    /// The box refused, and said why. `fyolod`'s own message is carried through
    /// verbatim: it already names the two ways out ("pass `--url …`", "start the
    /// daemon with `--wss-origin …`"), and a sentence written here would be a
    /// worse copy of one written next to the code that failed.
    struct Failure: Error, Equatable {
        let message: String
    }

    /// Asks `<alias>` for an invite. `rotate` issues a new token first, which
    /// signs out every phone already paired with that box.
    ///
    /// The box's own answer, never an override. `fyolod pair` takes a `--url`,
    /// and passing it here would be a trap: it changes only the address the
    /// invite *prints*, not the origins the daemon will accept, so the QR scans
    /// and the connection is then refused with a 403 the phone cannot explain.
    /// The address a box is reachable at is set by arming the daemon
    /// (`RemoteTunnelService.arm`), which is also what makes `pair` able to
    /// answer at all — the listener binds loopback on purpose, so nothing on the
    /// box can derive a public name it was not given.
    ///
    /// `pair` is its own process, outside the unit, so the origin the unit
    /// hands the daemon (`FYOLOD_WSS_ORIGIN` in its drop-in) is handed to
    /// `pair` here too — the same value, read back through systemd, so the
    /// address the invite prints and the origin the daemon pins cannot
    /// disagree. A box with no drop-in falls through to the daemon's own
    /// `wss.origin`, which is where a hand-run `--wss-origin` persisted it.
    ///
    /// Runs on a detached task: this forks `ssh`, and a box that is asleep or
    /// behind a slow link would otherwise block whatever called it.
    static func invite(from alias: String, rotate: Bool = false) async throws -> Invite {
        let environment = await RemoteTunnelService.listenerOrigin(of: alias)
            .map { "FYOLOD_WSS_ORIGIN=\(RemoteShell.quoted($0)) " } ?? ""
        let command = "\(environment)\(Fyolod.remoteBinary()) pair --json\(rotate ? " --rotate" : "")"
        let result = try await run(alias: alias, command: command)
        guard result.status == 0 else {
            throw Failure(message: message(from: result))
        }
        guard let invite = decode(result.stdout) else {
            throw Failure(message: localized("\(alias) answered, but not with a pairing invite. Its fyolod is probably older than this app — deploy it again."))
        }
        return invite
    }

    /// This Mac's own invite, minted by the daemon in the app bundle rather than
    /// over SSH.
    ///
    /// `--url` is passed here, and it is not the trap it is on a remote box.
    /// There, the address the invite prints and the origin the daemon accepts
    /// are two different values and only arming reconciles them, so a typed
    /// address produces a QR that scans and then 403s. This Mac's listener is
    /// the app's own (`DeviceSpliceServer`), which checks no origin — the
    /// address is the one the app is listening on, and the app is the only
    /// thing that knows it.
    static func localInvite(url: String, rotate: Bool = false) async throws -> Invite {
        var arguments = ["pair", "--json", "--url", url]
        if rotate { arguments.append("--rotate") }
        let result = try await runLocally(arguments: arguments)
        guard result.status == 0 else {
            throw Failure(message: message(from: result))
        }
        guard let invite = decode(result.stdout) else {
            throw Failure(message: localized("The session host answered, but not with a pairing invite."))
        }
        return invite
    }

    // MARK: - Running it

    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(alias: String, command: String) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            // `.userInitiated`: someone is looking at a spinner.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                // The app's own ssh options — multiplexing, BatchMode, the
                // connect timeout — so this pays the same 26–33 ms a warm master
                // costs rather than a fresh handshake, and never stalls on a
                // password prompt nobody can answer.
                process.arguments = Fyolod.sshArguments(host: alias) + [alias, command]
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure(
                        message: localized("Could not run ssh: \(error.localizedDescription)")))
                    return
                }
                // Both pipes drain before the wait: a child that fills either one
                // blocks forever against a parent waiting on exit.
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: String(data: stdout, encoding: .utf8) ?? "",
                    stderr: String(data: stderr, encoding: .utf8) ?? ""))
            }
        }
    }

    /// The bundled `fyolod`, run against this app's own channel so it reads the
    /// state directory the running daemon uses. Without the variable a dev build
    /// would mint a pairing token for the release channel's daemon.
    private static func runLocally(arguments: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let binary = Fyolod.daemonBinaryPath()
                guard FileManager.default.isExecutableFile(atPath: binary) else {
                    continuation.resume(throwing: Failure(
                        message: localized("The fyolod binary wasn't found at \(binary).")))
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["FYOLO_CHANNEL"] = Fyolod.channelName
                process.environment = environment
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure(
                        message: localized("Could not run fyolod: \(error.localizedDescription)")))
                    return
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: String(data: stdout, encoding: .utf8) ?? "",
                    stderr: String(data: stderr, encoding: .utf8) ?? ""))
            }
        }
    }

    /// What to show when the command failed. `fyolod`'s message when it has one;
    /// otherwise ssh's, which is the case where the box was never reached at all.
    private static func message(from result: Result) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stderr.isEmpty else { return stderr }
        return localized("Exited with status \(Int(result.status)).")
    }

    private static func decode(_ json: String) -> Invite? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String,
              let token = object["token"] as? String,
              let hostID = object["host_id"] as? String
        else { return nil }
        // `proto` is informational here — the phone enforces it on the handshake,
        // which is the only place that can refuse a mismatch honestly.
        let proto = object["proto"] as? Int ?? 0
        return Invite(url: url, token: token, hostID: hostID, proto: proto)
    }
}

/// The Mobile pane's remote arm: one card for one box, holding whatever that box
/// last said when asked for an invite.
///
/// It asks on appear rather than behind a button. Everything the card can show —
/// the QR, the address, the reason there is neither — is the answer to the same
/// single question, so making the user press something first would only add a
/// state in which the card says nothing at all.
struct RemotePairingSection: View {
    let machine: KnownDevice

    private enum Phase: Equatable {
        case asking
        /// A remote step is running. Publishing is several of them with real
        /// latency — installing a binary, waiting for a relay to answer,
        /// restarting a daemon — so the phase carries which one it is on: a
        /// spinner that never explains itself is indistinguishable from a hang.
        case working(String)
        case ready(RemotePairing.Invite)
        case failed(String)
    }

    /// fyolod's own default WebSocket port (`DEPLOY.md`) — not the Mac
    /// companion's 8887/8888, so a Mac running both does not have them fight.
    private static let daemonPort = 8790

    @State private var phase = Phase.asking
    @State private var copied = false
    @State private var confirmRotate = false
    /// How this box is published, remembered per machine so re-publishing after
    /// a reboot is one click rather than a re-decision.
    @State private var provider = RemoteTunnelProvider.off
    @State private var custom = RemoteCustomTunnel()
    /// The sessions arming would end, named. Empty means nothing is at risk and
    /// Publish proceeds without asking.
    @State private var atRisk: [String] = []
    @State private var confirmArm = false
    /// Whether the box stays published across a reboot. False only when
    /// `loginctl enable-linger` was refused, which is worth one line on screen
    /// and is not worth failing a publish over. Read from what the last publish
    /// found rather than re-probed, so the warning outlives the pane it first
    /// appeared in.
    @State private var survivesReboot = true

    var body: some View {
        Section {
            switch phase {
            case .asking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized("Asking \(machine.name)…"))
                        .foregroundStyle(.secondary)
                }
            case .ready(let invite):
                // QR and its link are one unit — "scan this, or send yourself the
                // same thing" — so no divider comes between them.
                VStack(spacing: 12) {
                    if let qr = pairingQRImage(for: invite.link) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 180, height: 180)
                            .padding(10)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    addressRow(invite)
                    if !survivesReboot {
                        Label(
                            localized("\(machine.name) stays published only until you log out of it. Fyolo couldn’t set it to keep services running after that."),
                            systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                rotateRow
            case .working(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(.secondary)
                }
            case .failed(let message):
                unpublished(message)
            }
        } header: {
            SectionHeaderLabel(title: machine.name)
        } footer: {
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            provider = .remembered(device: machine.settingsKey)
            custom = .load(device: machine.settingsKey)
            await ask()
        }
    }

    // MARK: - Pieces

    private func addressRow(_ invite: RemotePairing.Invite) -> some View {
        HStack(spacing: 8) {
            Text(invite.url)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            // The *link*, not the address: a bare URL is not enough to pair
            // with, and copying one that looks like it should be is how someone
            // spends ten minutes wondering why the phone refuses it.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(invite.link, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(
                    copied ? localized("Copied") : localized("Copy Invite"),
                    systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
    }

    private var rotateRow: some View {
        LabeledContent {
            Button(localized("Rotate Token…")) { confirmRotate = true }
                .confirmationDialog(
                    localized("Rotate the pairing token?"),
                    isPresented: $confirmRotate,
                    titleVisibility: .visible
                ) {
                    Button(localized("Rotate Token"), role: .destructive) {
                        Task { await ask(rotate: true) }
                    }
                    Button(localized("Cancel"), role: .cancel) {}
                } message: {
                    Text(localized("Every iPhone paired with \(machine.name) is signed out and must re-scan the new QR to reconnect."))
                }
        } label: {
            SettingsLabel(
                title: localized("Pairing Token"),
                subtext: localized("Issues a new token and revokes every paired iPhone."),
                titleFont: .headline)
        }
    }

    /// The box has no way in from outside yet — so this is where you choose one.
    ///
    /// It offers the same list the Mac's own Mobile Access does, for the same
    /// reason it exists there: **we cannot be everyone's relay.** Fyolo's relay
    /// has finite capacity, so a tunnel the user already owns is a first-class
    /// answer, not a consolation. The one thing this pane will not do is ask
    /// someone to type an address: the Mac has SSH to this box, so it can run
    /// the tunnel and *read the address back* — a value read is a value that
    /// cannot be mistyped, and it is the value the daemon gets pinned to.
    private func unpublished(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                localized("\(machine.name) isn’t published yet"),
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)

            LabeledContent(localized("Tunnel")) {
                Picker("", selection: $provider) {
                    ForEach(RemoteTunnelProvider.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if provider == .custom {
                TextField(
                    localized("Command"), text: $custom.command,
                    prompt: Text(verbatim: "cloudflared tunnel run --url http://127.0.0.1:{port} my-tunnel"))
                    .textFieldStyle(.roundedBorder)
                TextField(
                    localized("URL Pattern"), text: $custom.urlPattern,
                    prompt: Text(verbatim: #"https://[a-z0-9-]+\.example\.com"#))
                    .textFieldStyle(.roundedBorder)
            }

            if let note = provider.prerequisite {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider != .off, !provider.keepsItsAddress {
                // Said before the click, not after: an address that rotates is
                // not a defect to discover later, it is the deal being offered.
                Label(
                    localized("This address changes when the tunnel restarts, and every paired iPhone must scan again."),
                    systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(localized("Publish")) { Task { await beginPublish() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(provider == .off || (provider == .custom && !custom.isUsable))
                Button(localized("Try Again")) { Task { await ask() } }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            .confirmationDialog(
                localized("Publishing restarts fyolod on \(machine.name)"),
                isPresented: $confirmArm, titleVisibility: .visible
            ) {
                Button(localized("Publish and End Them"), role: .destructive) {
                    Task { await publish() }
                }
                Button(localized("Cancel"), role: .cancel) {}
            } message: {
                Text(localized("Opening the listener needs the daemon restarted, which ends what it is hosting:\n\(atRisk.joined(separator: "\n"))"))
            }

            // The daemon's own words, kept but demoted: they are terminal output
            // aimed at whoever is fixing the box, not at whoever is choosing a
            // tunnel. Leading the card with them made a solvable choice look
            // like a crash.
            DisclosureGroup(localized("What the daemon said")) {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Asks first when the daemon is hosting something, because arming restarts
    /// it. A count would not be enough to decide on: whether to end a session
    /// depends on whether it is an agent mid-task or a shell left at a prompt,
    /// and only its command line answers that.
    private func beginPublish() async {
        guard let alias = machine.alias else { return }
        // Off the main actor: this forks `ssh`, and a box on a slow link would
        // otherwise freeze the window for as long as it takes to answer.
        let live = await Task.detached {
            (try? Fyolod.roster(route: .ssh(alias)))?.sessions.filter(\.alive) ?? []
        }.value
        atRisk = live.map { "• \($0.command)" }
        if atRisk.isEmpty {
            await publish()
        } else {
            confirmArm = true
        }
    }

    private func publish() async {
        guard let alias = machine.alias else { return }
        provider.remember(device: machine.settingsKey)
        custom.save(device: machine.settingsKey)
        do {
            phase = .working(localized("Starting \(provider.label) on \(machine.name)…"))
            let published = try await RemoteTunnelService.publish(
                alias: alias, provider: provider,
                port: Self.daemonPort, custom: custom)
            survivesReboot = published.survivesReboot
            RemoteTunnelService.rememberLinger(
                published.survivesReboot, device: machine.settingsKey)
            // The address is written to the daemon rather than shown to be
            // copied: the invite, the daemon's allowed origin and the phone's
            // stored origin must be one value, and the only way to guarantee
            // that is for one place to know it.
            phase = .working(localized("Pointing fyolod at \(published.address)…"))
            guard let origin = RemoteTunnelService.originValue(of: published.address) else {
                throw RemoteTunnelService.Failure(
                    message: localized("\(published.address) is not an address the iPhone could dial."))
            }
            try await RemoteTunnelService.arm(
                alias: alias, origin: origin, port: Self.daemonPort)

            phase = .working(localized("Checking that \(published.address) answers…"))
            let invite = try await RemotePairing.invite(from: alias)
            // Retried, unlike the check on appear: the tunnel is seconds old
            // here, and a relay's first route can lag its own log line.
            try await verify(invite, attempts: 3)
            phase = .ready(invite)
        } catch let failure as RemoteTunnelService.Failure {
            phase = .failed(failure.message)
        } catch let failure as RemotePairing.Failure {
            phase = .failed(failure.message)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Dials the box the way the phone will, before showing a QR that says it
    /// can be dialled.
    ///
    /// `fyolod pair` never contacts the daemon — it reads the token and the
    /// origin off disk — so an invite proves only that the box has *opinions*
    /// about where it is reachable. The path from there to the phone crosses a
    /// relay, a fresh listener and an origin pin, and every one of them fails as
    /// a 403 the phone reports as nothing at all.
    private func verify(_ invite: RemotePairing.Invite, attempts: Int) async throws {
        var last: Error?
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do {
                let answered = try await RemoteTunnelService.handshake(
                    url: invite.url, token: invite.token)
                guard answered == invite.hostID else {
                    // Same address, different machine: a relay handed the name
                    // to someone else, and pairing would attach the phone to a
                    // box that is not this one.
                    throw RemoteTunnelService.Failure(message: localized("\(invite.url) answered as a different machine than \(machine.name). Its address is being served by something else."))
                }
                return
            } catch let failure as RemoteTunnelService.Failure {
                last = failure
            }
        }
        throw last ?? RemoteTunnelService.Failure(
            message: localized("\(machine.name) never answered on its published address."))
    }

    private var footnote: String {
        switch phase {
        case .ready:
            return localized("On iPhone, tap the Mac pill ▸ Scan QR Code. The token is minted on \(machine.name) and demanded on every connection.")
        default:
            return localized("Pick how \(machine.name) is reached from outside. Fyolo runs it there over SSH and reads the address back — you never type one.")
        }
    }

    /// Always asks the box what *it* knows. Nothing is passed in: after
    /// publishing, the daemon's own `wss.origin` is the address, and a second
    /// source for it is a second chance to disagree.
    ///
    /// Then dials it. An invite the box hands over says only what it *believes*
    /// about where it is reachable — the tunnel in front of it may have died
    /// since, and a QR minted from a stale belief scans perfectly and then
    /// connects to nothing. A box that no longer answers is, to the person
    /// holding the phone, exactly a box that is not published, so it lands in
    /// the same state and offers the same way out.
    private func ask(rotate: Bool = false) async {
        guard let alias = machine.alias else { return }
        phase = .asking
        survivesReboot = RemoteTunnelService.lingers(device: machine.settingsKey)
        do {
            let invite = try await RemotePairing.invite(from: alias, rotate: rotate)
            phase = .working(localized("Checking that \(invite.url) answers…"))
            try await verify(invite, attempts: 1)
            phase = .ready(invite)
        } catch let failure as RemotePairing.Failure {
            phase = .failed(failure.message)
        } catch let failure as RemoteTunnelService.Failure {
            phase = .failed(failure.message)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
