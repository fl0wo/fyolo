import XCTest
@testable import fyolo

/// The fyolo skill exists in four places and nothing at runtime ties them
/// together, so this is the only thing that stops an edit to one from silently
/// drifting the others: `Sources/fyolo/Resources/skills/fyolo/SKILL.md` (the
/// canonical copy, which `fyolod` embeds with `include_str!` and installs into
/// each agent's skills directory), the repo-root `skills/fyolo/SKILL.md` (the
/// layout `npx skills add` and `gh skill` discover for installs straight from
/// GitHub), and the published copy at https://fyolo.sh/skill.md.
///
/// Read off disk rather than out of the app bundle: since the installers moved
/// into the daemon, the app no longer looks these up at runtime, and a test that
/// went through a lookup nobody uses would be testing itself.
final class SessionSkillTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // fyoloTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testPublishedSkillMatchesInstalledSkill() throws {
        let canonical = try read("Sources/fyolo/Resources/skills/fyolo/SKILL.md")
        for mirror in ["skills/fyolo/SKILL.md", "web/landing/public/skill.md"] {
            XCTAssertEqual(
                try read(mirror), canonical,
                "\(mirror) must stay identical to the skill the daemon installs — "
                    + "update all copies together")
        }
    }

    /// A device gets a different document, not the Mac's: this one teaches the
    /// `fyolod` CLI, because a box has no `fyolo` binary and no app to report
    /// to. Installing the Mac's there would name a program that isn't there.
    func testDeviceSkillTeachesTheDaemonCLI() throws {
        let mac = try read("Sources/fyolo/Resources/skills/fyolo/SKILL.md")
        let device = try read("Sources/fyolo/Resources/skills/fyolo-device/SKILL.md")
        XCTAssertTrue(device.hasPrefix("---\nname: fyolo\n"))
        XCTAssertTrue(device.contains("FYOLOD_SESSION_ID"))
        XCTAssertTrue(device.contains("fyolod list"))
        XCTAssertFalse(device.contains("fyolo sessions"))
        XCTAssertNotEqual(device, mac)
    }

    /// A manifest's `skills.dir` is the declaration the daemon's installer
    /// trusts — a user dropping a custom agent into `~/.fyolo/config/agents/`
    /// gets its skill installed through the same field, no code change.
    func testManifestSkillsDeclaresDirectory() throws {
        let json = """
        { "id": "custom", "name": "Custom", "skills": { "dir": "~/.custom/skills" } }
        """
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        let definition = try manifest.definition(
            directory: repoRoot, resourceBundle: Bundle.fyoloResources)
        XCTAssertEqual(definition.skillDir, "~/.custom/skills")
    }

    /// Every bundled agent declares its skills directory, verified against each
    /// vendor's documented location so a typo in a manifest can't silently
    /// install into a directory the agent never reads.
    func testBundledSkillDeclarationsMatchCatalog() throws {
        let expected: [String: String] = [
            "claudeCode": "~/.claude/skills",
            "codex": "~/.codex/skills",
            "cursor": "~/.cursor/skills",
            "grok": "~/.grok/skills",
            "opencode": "~/.config/opencode/skills",
            "opencode2": "~/.config/opencode/skills",
            "pi": "~/.pi/agent/skills",
            "amp": "~/.config/agents/skills",
            "antigravity": "~/.gemini/antigravity/skills",
            "hermes": "~/.hermes/skills",
            "kimi": "~/.kimi-code/skills",
            "qwen": "~/.qwen/skills",
            "crush": "~/.config/crush/skills",
            "droid": "~/.factory/skills",
            "copilot": "~/.copilot/skills",
            "cline": "~/.cline/skills",
        ]
        for (id, directory) in expected {
            XCTAssertEqual(
                AgentCatalog.shared.find(id: id)?.skillDir, directory,
                "\(id) declares the wrong skills directory")
        }
    }
}
