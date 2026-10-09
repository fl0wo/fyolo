import XCTest

@testable import fyolo

/// The pure grammar behind Settings ▸ Devices: what an address means, what a new
/// host should be called, which credentials to offer, and which key an install
/// would actually send. All of it decides what lands in `~/.ssh/config` or on a
/// server's `authorized_keys`, and none of it needs a window.
final class SSHHostSetupTests: XCTestCase {
    // MARK: - Reading an address

    func testParsesUserHostAndPort() {
        let parsed = SSHConfigFile.parseDestination("root@10.0.0.4:2222")
        XCTAssertEqual(parsed.user, "root")
        XCTAssertEqual(parsed.host, "10.0.0.4")
        XCTAssertEqual(parsed.port, "2222")
    }

    func testPlainHostnameLeavesUserAndPortEmpty() {
        let parsed = SSHConfigFile.parseDestination("  server.example.com ")
        XCTAssertEqual(parsed.user, "")
        XCTAssertEqual(parsed.host, "server.example.com")
        XCTAssertEqual(parsed.port, "")
    }

    /// A trailing `:something` is only a port when it is a number. Otherwise it
    /// belongs to the hostname, and eating it would connect to the wrong box.
    func testNonNumericSuffixIsNotAPort() {
        let parsed = SSHConfigFile.parseDestination("server.example.com:staging")
        XCTAssertEqual(parsed.host, "server.example.com:staging")
        XCTAssertEqual(parsed.port, "")
    }

    /// An IPv6 literal is nothing but colons; splitting on the last one would
    /// truncate the address into a different (and reachable) host. The brackets
    /// come off because `HostName` wants the literal bare.
    func testBracketedIPv6KeepsItsColons() {
        let parsed = SSHConfigFile.parseDestination("[fe80::1]")
        XCTAssertEqual(parsed.host, "fe80::1")
        XCTAssertEqual(parsed.port, "")
    }

    func testBracketedIPv6WithAPortSplitsOnTheBracket() {
        let parsed = SSHConfigFile.parseDestination("[2001:db8::1]:2222")
        XCTAssertEqual(parsed.host, "2001:db8::1")
        XCTAssertEqual(parsed.port, "2222")
    }

    /// `2001:db8::1` is a whole address, not `2001:db8:` on port 1 — and the wrong
    /// reading yields a host that can resolve, so it fails as a mystery later.
    func testUnbracketedIPv6IsNotSplitIntoAPort() {
        let parsed = SSHConfigFile.parseDestination("2001:db8::1")
        XCTAssertEqual(parsed.host, "2001:db8::1")
        XCTAssertEqual(parsed.port, "")
    }

    func testUserWithBracketedIPv6AndPort() {
        let parsed = SSHConfigFile.parseDestination("root@[2001:db8::1]:2222")
        XCTAssertEqual(parsed.user, "root")
        XCTAssertEqual(parsed.host, "2001:db8::1")
        XCTAssertEqual(parsed.port, "2222")
    }

    func testEmptyAndPartialInputYieldNothingRatherThanGarbage() {
        XCTAssertEqual(SSHConfigFile.parseDestination("").host, "")
        let trailingAt = SSHConfigFile.parseDestination("you@")
        XCTAssertEqual(trailingAt.user, "you")
        XCTAssertEqual(trailingAt.host, "")
    }

    // MARK: - Naming the host

    func testAliasIsTheFirstLabel() {
        XCTAssertEqual(
            SSHConfigFile.suggestedAlias(forHost: "build.example.com", avoiding: []),
            "build"
        )
    }

    func testAliasForAnIPKeepsTheWholeAddress() {
        XCTAssertEqual(
            SSHConfigFile.suggestedAlias(forHost: "192.168.1.10", avoiding: []),
            "192.168.1.10"
        )
    }

    /// Two boxes under different domains share a first label. The second must not
    /// silently claim the first one's name — `ssh build` has to keep meaning one host.
    func testAliasAvoidsATakenName() {
        XCTAssertEqual(
            SSHConfigFile.suggestedAlias(forHost: "build.example.com", avoiding: ["build"]),
            "build-2"
        )
        XCTAssertEqual(
            SSHConfigFile.suggestedAlias(
                forHost: "build.example.com", avoiding: ["build", "build-2"]
            ),
            "build-3"
        )
    }

    /// A fixed ceiling handed back the taken base, so the sheet suggested a name it
    /// then rejected as a duplicate and Add could never be pressed.
    func testAliasKeepsCountingPastTheHundredthCollision() {
        var taken: Set<String> = ["build"]
        for suffix in 2...100 { taken.insert("build-\(suffix)") }
        let suggested = SSHConfigFile.suggestedAlias(forHost: "build.example.net", avoiding: taken)
        XCTAssertEqual(suggested, "build-101")
        XCTAssertFalse(taken.contains(suggested))
    }

    // MARK: - What can be written into the config

    func testALineBreakIsRefusedRatherThanWritten() {
        XCTAssertTrue(SSHConfigFile.isUnwritable("box\n  ProxyCommand /bin/sh"))
        XCTAssertTrue(SSHConfigFile.isUnwritable("box\rHost other"))
        XCTAssertFalse(SSHConfigFile.isUnwritable("server.example.com"))
        // A space is legal in a value; `appendHost` quotes it.
        XCTAssertFalse(SSHConfigFile.isUnwritable("~/My Keys/id_ed25519"))
    }

    func testAppendHostRefusesAValueCarryingItsOwnDirective() {
        XCTAssertThrowsError(
            try SSHConfigFile.appendHost(
                alias: "box\nHost evil", hostName: "example.com",
                user: "", port: "", identityFile: ""
            )
        )
    }

    // MARK: - Identities to offer

    private func host(
        _ alias: String, user: String = "", identityFile: String? = nil
    ) -> SSHConfigHost {
        SSHConfigHost(
            alias: alias, hostName: "\(alias).example.com", user: user, port: 22,
            identityFile: identityFile, file: URL(fileURLWithPath: "/dev/null"), line: 0
        )
    }

    func testIdentitiesAreRankedByUse() {
        let identities = SSHConfigFile.suggestedIdentities(in: [
            host("a", user: "deploy", identityFile: "~/.ssh/id_work"),
            host("b", user: "you", identityFile: "~/.ssh/id_ed25519"),
            host("c", user: "you", identityFile: "~/.ssh/id_ed25519"),
        ])
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(identities.first?.user, "you")
        XCTAssertEqual(identities.first?.keyName, "id_ed25519")
    }

    /// A host that sets neither field describes the defaults, and offering "sign in
    /// as (nothing)" is a row that changes nothing when picked.
    func testIdentityWithNeitherFieldIsNotOffered() {
        XCTAssertTrue(SSHConfigFile.suggestedIdentities(in: [host("bare")]).isEmpty)
    }

    // MARK: - Reading ssh's refusal

    func testMethodListNamesWhatTheServerWouldHaveTaken() {
        XCTAssertEqual(
            SSHConfigFile.offeredMethods("box: Permission denied (publickey,password)."),
            ["publickey", "password"]
        )
    }

    func testMissingMethodListReadsAsNoMethods() {
        XCTAssertTrue(SSHConfigFile.offeredMethods("Permission denied, please try again.").isEmpty)
    }

    // MARK: - Choosing the key to install

    private func key(_ name: String, algorithm: String) -> SSHPublicKey {
        SSHPublicKey(
            url: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/\(name)"),
            algorithm: algorithm, comment: ""
        )
    }

    func testStrongestKeyWinsWhenTheHostPinsNone() {
        let chosen = SSHConfigFile.publicKeyToInstall(
            for: host("box"),
            keys: [key("id_rsa.pub", algorithm: "RSA"), key("id_ed25519.pub", algorithm: "ED25519")]
        )
        XCTAssertEqual(chosen?.name, "id_ed25519.pub")
    }

    /// With no `IdentityFile` in the block, ssh offers only its default names and
    /// the agent. Installing `work_security_key` would report success and change
    /// nothing, because the next connection never offers that key.
    func testAKeySshWouldNeverOfferIsNotInstalled() {
        XCTAssertNil(SSHConfigFile.publicKeyToInstall(
            for: host("box"),
            keys: [key("work_security_key.pub", algorithm: "ED25519-SK")]
        ))
    }

    func testDefaultNamedKeyIsPreferredOverAStrongerCustomOne() {
        let chosen = SSHConfigFile.publicKeyToInstall(
            for: host("box"),
            keys: [
                key("work_security_key.pub", algorithm: "ED25519-SK"),
                key("id_rsa.pub", algorithm: "RSA"),
            ]
        )
        XCTAssertEqual(chosen?.name, "id_rsa.pub")
    }

    /// ssh will offer exactly the pinned key, so installing a different one leaves
    /// the host failing for the same reason with an extra key on it.
    func testPinnedIdentityFileDecidesTheKey() {
        let chosen = SSHConfigFile.publicKeyToInstall(
            for: host("box", identityFile: "~/.ssh/id_work"),
            keys: [key("id_ed25519.pub", algorithm: "ED25519"), key("id_work.pub", algorithm: "RSA")]
        )
        XCTAssertEqual(chosen?.name, "id_work.pub")
    }

    /// The pinned key has no `.pub` on disk: there is nothing safe to send, and
    /// guessing another key would install one ssh is never going to offer.
    func testPinnedIdentityWithNoPublicHalfInstallsNothing() {
        XCTAssertNil(SSHConfigFile.publicKeyToInstall(
            for: host("box", identityFile: "~/.ssh/id_missing"),
            keys: [key("id_ed25519.pub", algorithm: "ED25519")]
        ))
    }
}
