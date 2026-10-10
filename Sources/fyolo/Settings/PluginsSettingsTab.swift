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
        }
        .formStyle(.grouped)
    }
}
