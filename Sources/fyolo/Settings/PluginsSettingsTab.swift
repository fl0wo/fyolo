import SwiftUI

/// Settings ▸ Plugins: one switch per plugin, with a line on what it adds. A
/// plugin that is off contributes nothing anywhere in the app.
struct PluginsSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(PluginRegistry.all, id: \.id) { plugin in
                    Toggle(isOn: Binding(
                        get: { settings.isPluginEnabled(plugin.id) },
                        set: { settings.setPlugin(plugin.id, enabled: $0) }
                    )) {
                        SettingsLabel(title: plugin.name, subtext: plugin.summary, titleFont: .headline)
                    }
                    .toggleStyle(.switch)
                }
            } header: {
                SectionHeaderLabel(title: localized("Built In"))
            }
            Section {
                ForEach(TestRunner.all) { runner in
                    Toggle(isOn: Binding(
                        get: { settings.isPluginEnabled(runner.pluginID) },
                        set: { settings.setPlugin(runner.pluginID, enabled: $0) }
                    )) {
                        SettingsLabel(title: runner.name, subtext: runner.summary, titleFont: .headline)
                    }
                    .toggleStyle(.switch)
                }
            } header: {
                SectionHeaderLabel(title: localized("Test Runners"))
            } footer: {
                Text(localized("A runner switched off stops being recorded at once, and new terminals no longer load it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
