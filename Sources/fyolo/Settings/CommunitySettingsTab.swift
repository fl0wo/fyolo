import SwiftUI

/// Where the fyolo community lives: Discord, GitHub, and the WeChat group.
/// Pure links — nothing in this tab writes settings.
struct CommunitySettingsTab: View {
    var body: some View {
        Form {
            Section {
                CommunityLinkRow(
                    title: localized("Discord"),
                    subtext: localized("Chat with the developer and other users."),
                    buttonTitle: localized("Join"),
                    url: "https://discord.gg/H9DKVwsE5f"
                )
                CommunityLinkRow(
                    title: localized("GitHub"),
                    subtext: localized("Fyolo is open source — star the repo, report bugs, and request features."),
                    buttonTitle: localized("Open"),
                    url: "https://github.com/fl0wo/fyolo"
                )
            } header: {
                SectionHeaderLabel(title: localized("Channels"))
            }
            if let qrImage = Self.wechatQR {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsLabel(
                            title: localized("WeChat group"),
                            subtext: localized("Scan the QR code with WeChat to join the Chinese community group."),
                            titleFont: .headline
                        )
                        Image(nsImage: qrImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                } header: {
                    SectionHeaderLabel(title: localized("WeChat"))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The WeChat group QR code, bundled as `wechat-community.png` in the app's
    /// resource assets. The whole section stays hidden when the asset isn't in
    /// the build, so a missing image never shows as an empty card.
    private static let wechatQR: NSImage? = Bundle.fyoloResources
        .url(forResource: "wechat-community", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
}

/// One community destination: the standard two-line label with a trailing
/// button that opens the link in the browser.
private struct CommunityLinkRow: View {
    let title: String
    let subtext: String
    let buttonTitle: String
    let url: String

    var body: some View {
        HStack(spacing: 10) {
            SettingsLabel(title: title, subtext: subtext, titleFont: .headline)
            Spacer()
            Button(buttonTitle) {
                guard let destination = URL(string: url) else { return }
                NSWorkspace.shared.open(destination)
            }
        }
    }
}
