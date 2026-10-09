import XCTest
@testable import fyolo

/// How the pieces a user authors become one command line.
///
/// `AppSettings.command(for:on:)` splices three separately-edited things — the
/// machine's path, the agent's arguments, the bypass switch — into a single
/// string that is later handed to `zsh -ilc`. The order they land in and the
/// rule that a flag is never added twice are the parts a caller cannot see.
@MainActor
final class AgentLaunchCommandTests: XCTestCase {

    private func settings() -> AppSettings {
        let suite = "agent-launch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suite).json")
        return AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(defaults: defaults, fileURL: file, domainName: nil))
    }

    func testArgumentsFollowThePathAndPrecedeTheBypassFlag() {
        let settings = settings()
        settings.setArguments("--model opus", for: .claudeCode)
        settings.setBypassPermissions(.claudeCode, enabled: true)

        XCTAssertEqual(
            settings.command(for: .claudeCode),
            "claude --model opus --dangerously-skip-permissions")
    }

    func testAFlagTypedIntoTheArgumentsIsNotAddedTwice() {
        // The same rule the command path already had: the switch tops the line up
        // to the flag rather than appending it unconditionally, so a user who
        // reached for the field before finding the switch doesn't get both.
        let settings = settings()
        settings.setArguments("--dangerously-skip-permissions", for: .claudeCode)
        settings.setBypassPermissions(.claudeCode, enabled: true)

        XCTAssertEqual(settings.command(for: .claudeCode),
                       "claude --dangerously-skip-permissions")
    }

    func testArgumentsApplyToEveryMachineWhilePathsDoNot() {
        // The scope split this setting exists for: how you want the agent to run
        // travels with the agent, where it lives is a fact about a box.
        let settings = settings()
        let vps = KnownDevice(alias: "vps", deviceID: "h_1")
        settings.setCommandPath("/opt/bin/codex", for: .codex, on: vps)
        settings.setArguments("--sandbox danger-full-access", for: .codex)

        XCTAssertEqual(settings.command(for: .codex, on: vps),
                       "/opt/bin/codex --sandbox danger-full-access")
        XCTAssertEqual(settings.command(for: .codex),
                       "codex --sandbox danger-full-access")
    }

    func testAnEmptiedFieldLeavesNothingBehind() {
        // An emptied field must hand the agent back to its default rather than
        // storing "" — the rule that keeps a cleared preference out of the file.
        let settings = settings()
        settings.setArguments("--model opus", for: .claudeCode)
        settings.setArguments("   ", for: .claudeCode)

        XCTAssertNil(settings.arguments(for: .claudeCode))
        XCTAssertTrue(settings.agentArguments.isEmpty)
        XCTAssertEqual(settings.command(for: .claudeCode), "claude")
    }

    func testOpenCodeCanSkipItsPromptsFromTheSwitchAlone() {
        // The reason issue #577 was filed: OpenCode's manifest carried no bypass
        // flag, so the switch it needed was not on its pane at all.
        XCTAssertEqual(AgentPreset.opencode.permissionBypassFlag, "--auto")

        let settings = settings()
        settings.setBypassPermissions(.opencode, enabled: true)
        XCTAssertEqual(settings.command(for: .opencode), "opencode --auto")
    }
}
