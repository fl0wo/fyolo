import XCTest

@testable import fyolo

/// The Docker pane reads everything through the `docker` CLI's text output, so
/// the parsing is where it can silently go wrong: a field that stops decoding
/// empties the list, a stray color code garbles the logs. All of it is pure, so
/// it is pinned down here without an engine running.
@MainActor
final class DockerServiceTests: XCTestCase {
    private let psOutput = """
    {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2026-10-10 14:02:11 +0200 CEST","ID":"a1b2c3d4e5f6","Image":"postgres:16","Labels":"com.docker.compose.project=shop,com.docker.compose.service=db,com.docker.compose.version=2.29.1","LocalVolumes":"1","Mounts":"shop_pg","Names":"shop-db-1","Networks":"shop_default","Ports":"0.0.0.0:5432->5432/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours (healthy)"}
    not json at all
    {"Command":"\\"nginx -g 'daemon of…\\"","CreatedAt":"2026-10-10 15:00:00 +0200 CEST","ID":"ffeeddccbbaa","Image":"nginx:latest","Labels":"","LocalVolumes":"0","Mounts":"","Names":"web","Networks":"bridge","Ports":"","RunningFor":"5 minutes ago","Size":"0B","State":"running","Status":"Up 5 minutes"}
    """

    func testPsOutputBecomesContainersAndSkipsUnreadableLines() {
        let containers = DockerService.parseContainerList(psOutput)
        XCTAssertEqual(containers.map(\.name), ["shop-db-1", "web"])
        XCTAssertEqual(containers[0].composeProject, "shop")
        XCTAssertEqual(containers[0].composeService, "db")
        XCTAssertEqual(containers[0].ports, "0.0.0.0:5432->5432/tcp")
        XCTAssertEqual(containers[0].health, .healthy)
        XCTAssertNil(containers[1].composeProject)
        XCTAssertEqual(containers[1].health, .none)
    }

    func testComposeProjectsGroupAheadOfLooseContainers() {
        let groups = DockerView.groups(DockerService.parseContainerList(psOutput))
        XCTAssertEqual(groups.map(\.title), ["shop", "Containers"])
        XCTAssertEqual(groups[0].containers.map(\.name), ["shop-db-1"])
    }

    func testUptimeDropsTheVerbAndTheHealthNote() {
        XCTAssertEqual(DockerStatusDot.uptime("Up 2 hours (healthy)"), "2 hours")
        XCTAssertEqual(DockerStatusDot.uptime("Up About a minute"), "About a minute")
    }

    func testInspectOutputBecomesDetails() throws {
        let inspect = """
        [{"Id":"a1b2c3d4e5f6a1b2c3d4e5f6","Name":"/shop-db-1",
          "State":{"Status":"running","StartedAt":"2026-10-10T12:02:11.123456789Z","Health":{"Status":"healthy"}},
          "Config":{"Image":"postgres:16","Env":["POSTGRES_DB=shop","PATH=/usr/bin"],"Cmd":["postgres"],
                    "Entrypoint":["docker-entrypoint.sh"],"WorkingDir":"","Labels":{"com.docker.compose.project":"shop"}},
          "HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}},
          "NetworkSettings":{"Ports":{"5432/tcp":[{"HostIp":"0.0.0.0","HostPort":"5432"}],"8080/tcp":null},
                             "Networks":{"shop_default":{"IPAddress":"172.18.0.2"}}},
          "Mounts":[{"Source":"/var/lib/docker/volumes/shop_pg/_data","Destination":"/var/lib/postgresql/data","RW":true}]}]
        """
        let details = try XCTUnwrap(DockerService.parseDetails(inspect))
        XCTAssertEqual(details.name, "shop-db-1")
        XCTAssertEqual(details.health, "healthy")
        XCTAssertNotNil(details.startedAt)
        XCTAssertEqual(details.restartPolicy, "unless-stopped")
        XCTAssertEqual(details.command, "docker-entrypoint.sh postgres")
        XCTAssertNil(details.workingDirectory)
        XCTAssertEqual(details.ports, [
            .init(container: "5432/tcp", host: "0.0.0.0:5432"),
            .init(container: "8080/tcp", host: nil),
        ])
        XCTAssertEqual(details.networks, [.init(name: "shop_default", address: "172.18.0.2")])
        XCTAssertEqual(details.mounts.first?.isReadOnly, false)
        XCTAssertEqual(details.environment.count, 2)
    }

    func testIPv6BindingsAreBracketed() {
        XCTAssertEqual(DockerService.hostAddress(ip: "::", port: "8089"), "[::]:8089")
        XCTAssertEqual(DockerService.hostAddress(ip: "0.0.0.0", port: "8089"), "0.0.0.0:8089")
        XCTAssertNil(DockerService.hostAddress(ip: "", port: nil))
    }

    func testColorCodesAreStrippedFromLogs() {
        XCTAssertEqual(
            DockerService.stripTerminalEscapes("\u{1B}[32mINFO\u{1B}[0m ready\u{1B}[2K"),
            "INFO ready")
    }
}
