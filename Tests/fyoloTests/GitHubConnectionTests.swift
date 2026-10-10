import XCTest
@testable import fyolo

/// The GitHub connection is the one record every GitHub surface reads, and three
/// of its rules fail silently when wrong: a host typed loosely becomes a
/// connection to the wrong API root, an older install's Keychain item stops
/// decoding and signs the user out, and a remote on an Enterprise server never
/// binds to the Issues pane. All three are pure, so they are pinned down here.
final class GitHubConnectionTests: XCTestCase {
    func testHostInputIsReducedToABareHost() {
        let cases: [(String, String?)] = [
            ("github.com", "github.com"),
            ("  GitHub.com \n", "github.com"),
            ("https://github.example.com/", "github.example.com"),
            ("http://github.example.com/api/v3", "github.example.com"),
            ("github.example.com.", "github.example.com"),
            ("octocorp.ghe.com", "octocorp.ghe.com"),
            ("", nil),
            ("localhost", nil),
            ("ghe corp.com", nil),
            ("github.example.com:8443", nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(GitHubConnection.normalizedHost(input), expected, "input: \(input)")
        }
    }

    func testGitHubDotComAliasesAreNotMistakenForAnEnterpriseServer() {
        XCTAssertEqual(GitHubConnection.normalizedHost("www.github.com"), "github.com")
        XCTAssertEqual(GitHubConnection.normalizedHost("https://api.github.com"), "github.com")
    }

    func testEachKindOfServerGetsItsOwnAPIRoot() {
        func base(_ host: String) -> String {
            GitHubConnection(host: host, token: "t", source: .token).apiBase
        }
        XCTAssertEqual(base("github.com"), "https://api.github.com")
        XCTAssertEqual(base("octocorp.ghe.com"), "https://api.octocorp.ghe.com")
        XCTAssertEqual(base("github.example.com"), "https://github.example.com/api/v3")
    }

    func testABareTokenFromAnOlderInstallStillDecodesAsABrowserSignIn() {
        let legacy = GitHubConnection.decode(Data("gho_abc123".utf8))
        XCTAssertEqual(legacy, GitHubConnection(host: "github.com", token: "gho_abc123", source: .browser))
    }

    func testAStoredConnectionRoundTrips() throws {
        let connection = GitHubConnection(host: "github.example.com", token: "ghp_x", source: .token)
        let data = try JSONEncoder().encode(connection)
        XCTAssertEqual(GitHubConnection.decode(data), connection)
    }

    func testAnUnreadablePayloadIsNoConnectionRatherThanAGarbageToken() {
        XCTAssertNil(GitHubConnection.decode(Data("{\"host\":1}".utf8)))
        XCTAssertNil(GitHubConnection.decode(Data("  ".utf8)))
    }

    func testTheGitHubCLIHostsFileYieldsEachSignedInAccount() {
        let hosts = """
        github.com:
            users:
                fl0wo:
            git_protocol: https
            user: fl0wo
        github.example.com:
            oauth_token: secret
            user: alice
        half-done.example.com:
            git_protocol: ssh
        """
        XCTAssertEqual(
            GitHubCLI.accounts(inHostsFile: hosts),
            [
                GitHubCLIAccount(host: "github.com", user: "fl0wo"),
                GitHubCLIAccount(host: "github.example.com", user: "alice"),
            ])
    }

    func testRemotesBindToTheConnectedEnterpriseServerAndOnlyThere() {
        let enterprise = "github.example.com"
        XCTAssertEqual(
            GitService.gitHubSlug(fromRemote: "git@github.example.com:team/app.git", host: enterprise),
            "team/app")
        XCTAssertEqual(
            GitService.gitHubSlug(fromRemote: "https://github.example.com/team/app", host: enterprise),
            "team/app")
        XCTAssertNil(GitService.gitHubSlug(fromRemote: "https://github.com/team/app", host: enterprise))
        XCTAssertNil(GitService.gitHubSlug(fromRemote: "https://github.example.com/team/app"))
    }
}
