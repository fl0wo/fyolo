import XCTest
@testable import fyolo

/// What the update check concludes from a release's `latest.json`. The rules
/// decide whether a user is merely offered an update or blocked until they take
/// it, so each edge is pinned: a wrong answer either nags people on a supported
/// version or locks out everyone at once.
final class UpdateCheckTests: XCTestCase {
    private func version(_ text: String) throws -> ReleaseVersion {
        try XCTUnwrap(ReleaseVersion(text), "\(text) should parse")
    }

    private func manifest(_ latest: String, minimum: String = "0.0.0") throws -> ReleaseManifest {
        let json = """
        {"version": "\(latest)", "minimum_version": "\(minimum)",
         "notes_url": "https://github.com/fl0wo/fyolo/releases/tag/v\(latest)",
         "dmg_url": "https://github.com/fl0wo/fyolo/releases/download/v\(latest)/fyolo.dmg",
         "sha256": "abc", "cask": "fl0wo/tap/fyolo"}
        """
        return try JSONDecoder().decode(ReleaseManifest.self, from: Data(json.utf8))
    }

    private func verdict(running: String, latest: String, minimum: String = "0.0.0") throws -> UpdateVerdict? {
        UpdateVerdict.of(running: try version(running), manifest: try manifest(latest, minimum: minimum))
    }

    // MARK: - Versions

    func testVersionsCompareNumericallyNotAsText() throws {
        XCTAssertLessThan(try version("0.9.0"), try version("0.10.0"))
        XCTAssertLessThan(try version("0.3.9"), try version("0.4.0"))
        XCTAssertLessThan(try version("1.9.9"), try version("2.0.0"))
    }

    func testTagPrefixSuffixesAndShortFormsNormalize() throws {
        XCTAssertEqual(try version("v0.4.0"), try version("0.4.0"))
        XCTAssertEqual(try version("0.4.0-beta.1"), try version("0.4.0"))
        XCTAssertEqual(try version("0.4.0+2190"), try version("0.4.0"))
        XCTAssertEqual(try version("1"), try version("1.0.0"))
        XCTAssertEqual(try version("1.2").description, "1.2.0")
    }

    func testGarbageIsNotAVersion() {
        for text in ["", "abc", "1.2.3.4", "1..2", "-1.0.0", "1.x.0"] {
            XCTAssertNil(ReleaseVersion(text), "\(text) should not parse")
        }
    }

    // MARK: - Verdicts

    func testTheSameOrANewerRunningVersionIsCurrent() throws {
        XCTAssertEqual(try verdict(running: "0.4.0", latest: "0.4.0"), .current)
        XCTAssertEqual(try verdict(running: "0.5.0", latest: "0.4.0"), .current,
                       "a build ahead of the release (a local one) is never offered a downgrade")
    }

    func testANewerReleaseAboveTheFloorIsOnlyOffered() throws {
        let latest = try manifest("0.4.0")
        XCTAssertEqual(try verdict(running: "0.3.0", latest: "0.4.0"), .available(latest))
        XCTAssertEqual(try verdict(running: "0.3.9", latest: "0.4.0", minimum: "0.3.0"),
                       .available(try manifest("0.4.0", minimum: "0.3.0")))
    }

    func testRunningBelowTheFloorIsRequired() throws {
        // A new major: the release script sets the floor to <major>.0.0.
        XCTAssertEqual(try verdict(running: "0.9.3", latest: "1.0.0", minimum: "1.0.0"),
                       .required(try manifest("1.0.0", minimum: "1.0.0")))
        // A deliberate floor inside 0.x.
        XCTAssertEqual(try verdict(running: "0.3.0", latest: "0.5.0", minimum: "0.4.0"),
                       .required(try manifest("0.5.0", minimum: "0.4.0")))
    }

    /// A floor above the release itself would block every install with nothing
    /// to update to, so it is treated as no floor at all.
    func testAFloorAboveTheReleaseIsIgnored() throws {
        XCTAssertEqual(try verdict(running: "0.3.0", latest: "0.4.0", minimum: "9.0.0"),
                       .available(try manifest("0.4.0", minimum: "9.0.0")))
    }

    func testAnUnreadableFloorOnlyOffers() throws {
        XCTAssertEqual(try verdict(running: "0.3.0", latest: "0.4.0", minimum: "soon"),
                       .available(try manifest("0.4.0", minimum: "soon")))
    }

    func testAManifestThatCannotNameItsVersionDecidesNothing() throws {
        XCTAssertNil(try verdict(running: "0.3.0", latest: "latest"))
    }

    // MARK: - The manifest

    /// The exact shape `scripts/release-manifest.sh` writes — a rename on one
    /// side would leave every install unable to read the file.
    func testTheReleaseScriptsManifestDecodes() throws {
        let json = """
        {
          "version": "0.4.0",
          "minimum_version": "0.0.0",
          "notes_url": "https://github.com/fl0wo/fyolo/releases/tag/v0.4.0",
          "dmg_url": "https://github.com/fl0wo/fyolo/releases/download/v0.4.0/fyolo.dmg",
          "sha256": "da0150516d36115eb20049749f11871010145cbe186afc9494fe5457a343b84c",
          "cask": "fl0wo/tap/fyolo"
        }
        """
        let decoded = try JSONDecoder().decode(ReleaseManifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, "0.4.0")
        XCTAssertEqual(decoded.minimumVersion, "0.0.0")
        XCTAssertEqual(decoded.dmgURL.lastPathComponent, "fyolo.dmg")
        XCTAssertEqual(decoded.cask, "fl0wo/tap/fyolo")
    }

    // MARK: - Install method

    func testACaskroomEntryMeansHomebrew() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(InstallMethod.detect(prefixes: [root.path]), .direct)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Caskroom/fyolo/0.3.0"),
            withIntermediateDirectories: true)
        XCTAssertEqual(InstallMethod.detect(prefixes: [root.path]), .direct,
                       "a Caskroom with no brew beside it cannot run an upgrade")

        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let brew = bin.appendingPathComponent("brew")
        FileManager.default.createFile(atPath: brew.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(InstallMethod.detect(prefixes: [root.path]), .homebrew(brew: brew))
    }
}
