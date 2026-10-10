import Foundation

// MARK: - Models

/// A running container as `docker ps` lists it — enough for one row of the
/// Docker pane, without a second round trip per container.
struct DockerContainer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let image: String
    /// Docker's own human line: "Up 3 hours (healthy)".
    let status: String
    let ports: String
    /// The Compose project the container belongs to, when Compose started it —
    /// how the pane groups a stack's services together.
    let composeProject: String?
    let composeService: String?

    enum Health: Sendable { case healthy, starting, unhealthy, none }

    /// Read off the status line, which is where `docker ps` reports it.
    var health: Health {
        if status.contains("(healthy)") { return .healthy }
        if status.contains("(health: starting)") { return .starting }
        if status.contains("(unhealthy)") { return .unhealthy }
        return .none
    }
}

/// What `docker inspect` adds for one container: the detail behind a row.
struct DockerContainerDetails: Sendable {
    struct Port: Hashable, Sendable {
        let container: String
        let host: String?
    }
    struct Network: Hashable, Sendable {
        let name: String
        let address: String?
    }
    struct Mount: Hashable, Sendable {
        let source: String
        let destination: String
        let isReadOnly: Bool
    }

    let id: String
    let name: String
    let image: String
    let state: String
    let health: String?
    let startedAt: Date?
    let restartPolicy: String?
    let command: String
    let workingDirectory: String?
    let ports: [Port]
    let networks: [Network]
    let mounts: [Mount]
    let environment: [String]
    let labels: [String: String]
}

// MARK: - Service

/// Talks to Docker through the `docker` CLI rather than the engine socket, so
/// the user's current context — Docker Desktop, OrbStack, Colima, a remote
/// `DOCKER_HOST` context — is honored exactly as their terminal honors it.
/// Read-only: the pane lists, inspects and reads logs; it never starts, stops or
/// removes anything.
enum DockerService {
    enum Failure: LocalizedError {
        case notInstalled
        /// The CLI is there but no engine answered — Docker Desktop not started.
        case notRunning(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return localized("Docker isn’t installed on this Mac.")
            case .notRunning(let detail), .failed(let detail): return detail
            }
        }
    }

    /// Where the CLI lives for each way Docker is installed on a Mac. A GUI app
    /// inherits launchd's bare `PATH`, so searching `PATH` would find none of them.
    private static var executableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "\(home)/.docker/bin/docker",
            "\(home)/.orbstack/bin/docker",
            "\(home)/.rd/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
    }

    static var executable: String? {
        executableCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { executable != nil }

    /// Every running container, in `docker ps` order (newest first).
    static func runningContainers() async throws -> [DockerContainer] {
        let output = try await run(["ps", "--no-trunc", "--format", "{{json .}}"])
        return parseContainerList(output)
    }

    static func details(of id: String) async throws -> DockerContainerDetails {
        let output = try await run(["inspect", id])
        guard let details = parseDetails(output) else {
            throw Failure.failed(localized("Docker returned an unexpected reply."))
        }
        return details
    }

    /// The last `tail` lines of a container's output, stdout and stderr
    /// interleaved the way they were written, with terminal color codes removed.
    static func logs(of id: String, tail: Int) async throws -> String {
        let output = try await run(["logs", "--tail", String(tail), id], mergingErrors: true)
        return stripTerminalEscapes(output)
    }

    // MARK: Parsing

    /// One JSON object per line, as `--format '{{json .}}'` writes them. A line
    /// that doesn't decode is skipped rather than failing the whole list.
    static func parseContainerList(_ output: String) -> [DockerContainer] {
        struct Row: Decodable {
            let ID: String
            let Names: String
            let Image: String
            let Status: String
            let Ports: String?
            let Labels: String?
        }
        return output.split(separator: "\n").compactMap { line in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { return nil }
            let labels = parseLabelList(row.Labels ?? "")
            return DockerContainer(
                id: row.ID,
                name: row.Names,
                image: row.Image,
                status: row.Status,
                ports: row.Ports ?? "",
                composeProject: labels["com.docker.compose.project"],
                composeService: labels["com.docker.compose.service"]
            )
        }
    }

    /// `docker ps` flattens labels to `key=value,key=value`.
    static func parseLabelList(_ text: String) -> [String: String] {
        var labels: [String: String] = [:]
        for pair in text.split(separator: ",") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            labels[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        return labels
    }

    static func parseDetails(_ output: String) -> DockerContainerDetails? {
        struct Inspect: Decodable {
            struct State: Decodable {
                struct Health: Decodable { let Status: String? }
                let Status: String?
                let StartedAt: String?
                let Health: Health?
            }
            struct Config: Decodable {
                let Image: String?
                let Env: [String]?
                let Cmd: [String]?
                let Entrypoint: [String]?
                let WorkingDir: String?
                let Labels: [String: String]?
            }
            struct HostConfig: Decodable {
                struct RestartPolicy: Decodable { let Name: String? }
                let RestartPolicy: RestartPolicy?
            }
            struct NetworkSettings: Decodable {
                struct Binding: Decodable { let HostIp: String?; let HostPort: String? }
                struct Endpoint: Decodable { let IPAddress: String? }
                let Ports: [String: [Binding]?]?
                let Networks: [String: Endpoint]?
            }
            struct Mount: Decodable {
                let Source: String?
                let Destination: String?
                let RW: Bool?
            }
            let Id: String
            let Name: String?
            let State: State?
            let Config: Config?
            let HostConfig: HostConfig?
            let NetworkSettings: NetworkSettings?
            let Mounts: [Mount]?
        }
        guard let inspect = try? JSONDecoder().decode([Inspect].self, from: Data(output.utf8)).first
        else { return nil }

        let ports: [DockerContainerDetails.Port] = (inspect.NetworkSettings?.Ports ?? [:])
            .sorted { $0.key < $1.key }
            .flatMap { key, bindings -> [DockerContainerDetails.Port] in
                guard let bindings, !bindings.isEmpty else {
                    return [DockerContainerDetails.Port(container: key, host: nil)]
                }
                return bindings.map { binding in
                    DockerContainerDetails.Port(
                        container: key,
                        host: hostAddress(ip: binding.HostIp, port: binding.HostPort))
                }
            }
        let networks = (inspect.NetworkSettings?.Networks ?? [:])
            .sorted { $0.key < $1.key }
            .map { name, endpoint in
                DockerContainerDetails.Network(
                    name: name,
                    address: endpoint.IPAddress.flatMap { $0.isEmpty ? nil : $0 })
            }
        let mounts = (inspect.Mounts ?? []).map { mount in
            DockerContainerDetails.Mount(
                source: mount.Source ?? "",
                destination: mount.Destination ?? "",
                isReadOnly: mount.RW == false)
        }
        let command = ((inspect.Config?.Entrypoint ?? []) + (inspect.Config?.Cmd ?? []))
            .joined(separator: " ")
        let restart = inspect.HostConfig?.RestartPolicy?.Name
        return DockerContainerDetails(
            id: inspect.Id,
            name: (inspect.Name ?? inspect.Id).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            image: inspect.Config?.Image ?? "",
            state: inspect.State?.Status ?? "",
            health: inspect.State?.Health?.Status,
            startedAt: inspect.State?.StartedAt.flatMap(parseTimestamp),
            restartPolicy: (restart?.isEmpty ?? true) || restart == "no" ? nil : restart,
            command: command,
            workingDirectory: inspect.Config?.WorkingDir.flatMap { $0.isEmpty ? nil : $0 },
            ports: ports,
            networks: networks,
            mounts: mounts,
            environment: inspect.Config?.Env ?? [],
            labels: inspect.Config?.Labels ?? [:]
        )
    }

    /// `0.0.0.0:8080`, or `[::]:8080` for an IPv6 address — bracketed, the way a
    /// URL writes it, so the port can't be mistaken for part of the address.
    static func hostAddress(ip: String?, port: String?) -> String? {
        let ip = ip ?? ""
        let port = port ?? ""
        guard !ip.isEmpty || !port.isEmpty else { return nil }
        let host = ip.contains(":") ? "[\(ip)]" : ip
        if port.isEmpty { return host }
        return host.isEmpty ? port : "\(host):\(port)"
    }

    /// Docker writes RFC 3339 with nanoseconds, which `ISO8601DateFormatter`
    /// only reads once the fraction is cut to milliseconds.
    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var trimmed = text
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<zone].prefix(3)
            trimmed = String(text[..<dot]) + "." + fraction + String(text[zone...])
        }
        return formatter.date(from: trimmed)
            ?? ISO8601DateFormatter().date(from: text)
    }

    /// Removes ANSI escape sequences — colors, cursor moves — that services
    /// write for a terminal and that read as noise in a plain text view.
    static func stripTerminalEscapes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    // MARK: Running

    /// A wedged engine can leave `docker` waiting forever; past this the call
    /// is abandoned and reported, so the pane never hangs with it.
    private static let timeout: TimeInterval = 10
    /// Logs can be large; anything past this much output is cut from the top.
    private static let outputLimit = 2_000_000

    private static func run(_ arguments: [String], mergingErrors: Bool = false) async throws -> String {
        guard let executable else { throw Failure.notInstalled }
        return try await Task.detached(priority: .userInitiated) {
            try runBlocking(executable: executable, arguments: arguments, mergingErrors: mergingErrors)
        }.value
    }

    /// Collects stderr on its own thread while stdout drains on the caller's.
    private final class ErrorBuffer: @unchecked Sendable {
        var data = Data()
    }

    private static func runBlocking(
        executable: String, arguments: [String], mergingErrors: Bool
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Credential helpers and CLI plugins sit next to the binary.
        var environment = ProcessInfo.processInfo.environment
        let directory = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = [directory, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
        let output = Pipe()
        let errors = mergingErrors ? output : Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Both pipes drain before the wait, so neither can fill and stall the child.
        let errorBuffer = ErrorBuffer()
        let errorReader = DispatchGroup()
        if !mergingErrors {
            errorReader.enter()
            DispatchQueue.global().async {
                errorBuffer.data = errors.fileHandleForReading.readDataToEndOfFile()
                errorReader.leave()
            }
        }
        var data = output.fileHandleForReading.readDataToEndOfFile()
        errorReader.wait()
        process.waitUntilExit()
        watchdog.cancel()
        if data.count > outputLimit { data = data.suffix(outputLimit) }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal {
                throw Failure.notRunning(localized("Docker didn’t answer in time."))
            }
            let message = String(decoding: mergingErrors ? data : errorBuffer.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("Cannot connect to the Docker daemon")
                || message.contains("Is the docker daemon running") {
                throw Failure.notRunning(localized("Docker isn’t running. Start Docker Desktop, OrbStack or Colima."))
            }
            throw Failure.failed(message.isEmpty ? localized("docker exited with an error.") : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
