import AppKit
import SwiftUI

/// The `~/.ssh/config` half of a machine — how it is reached — as controls the
/// Machines surface composes.
///
/// This file was `DevicesSettingsTab`, a top-level tab that was only ever the
/// route half. RFC §D2 folded it into a machine's pane so a box's route and its
/// capabilities read as one thing; what is left here is the shared pieces that
/// pane and the roster both draw with, plus the Add Host sheet the File menu also
/// opens.

/// How each probe outcome reads in a row: a short tinted label — the wording
/// itself distinguishes outcomes, so color is reinforcement, not the only
/// signal — with the raw ssh detail in the tooltip.

/// Which file the config editor shows — usually `~/.ssh/config`, but a host
/// defined in an `Include`d file opens that file, at its `Host` line.
struct SSHConfigEditorTarget: Identifiable {
    let url: URL
    let line: Int?
    var id: String { "\(url.path)#\(line ?? 0)" }
}

/// The raw-config editor, presented as a sheet from the Machines tab. The config
/// file stays the single source of truth: Fyolo reads the hosts `ssh` itself
/// resolves and never writes a separate list behind the user's back.
struct SSHConfigEditorSheet: View {
    let target: SSHConfigEditorTarget
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void

    var body: some View {
        FileEditorView(
            url: target.url,
            settings: settings,
            jumpLine: target.line,
            showsInspectorChrome: false,
            onClose: onClose
        )
        .frame(minWidth: 640, minHeight: 460)
        // The editor's own header controls belong to the inspector, which a sheet
        // doesn't have — so supply the one control that still applies. Escape closes
        // too; the visible button is the guaranteed way out.
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(localized("Close (Esc)"))
            .padding(8)
        }
    }
}

extension SSHProbeResult {
    var label: String {
        switch self {
        case .reachable: return localized("Reachable")
        case .wantsPassword: return localized("Wants a password")
        case .authFailed: return localized("Auth failed")
        case .unreachable(let reason): return reason
        }
    }

    var tint: Color {
        switch self {
        case .reachable: return .green
        case .wantsPassword, .authFailed: return .orange
        case .unreachable: return .red
        }
    }

    var detail: String {
        switch self {
        case .reachable: return localized("Connected and authenticated")
        case .wantsPassword(let message), .authFailed(let message),
             .unreachable(let message):
            return message
        }
    }
}

/// The Add Host sheet, appending a `Host` block to `~/.ssh/config` that is
/// indistinguishable from a hand-written one. Shared by Settings ▸ Devices' Add
/// Host button and the New SSH Connection ▸ Add Host… menu row (which connects
/// to the host right after adding it).
///
/// The address leads and everything else follows from it: `you@box.example.com:2222`
/// fills the user and port, and the name is the address's first label until the
/// user types their own. Under it sit the two fields that decide whether the host
/// lets you in — a user and a key — pre-filled from what the rest of the config
/// already uses, because a machine you add is almost always reached as the same
/// person with the same key as the last one.
///
/// They are filled in rather than hidden behind a picker, and they sit in a section
/// of their own headed Credentials — the grouping Termius uses, because signing in
/// is one question and a form that scatters it across a box of unrelated fields
/// never reads as one. An earlier draft offered the identity as a "Sign in as" row
/// whose exceptional case lived in Advanced, which is the shape Tabby and XPipe
/// both avoid: whatever names the credential owns the fields beneath it.
///
/// Nothing is behind a disclosure. `Port` was the only candidate, and hiding one
/// short field to save one row bought a mode where there could be none.
///
/// The Credentials footer says out loud that there is no password field and where
/// a password host does get handled. Termius has one and fyolo cannot; leaving
/// that unsaid makes the sheet look incomplete rather than decided.
struct AddSSHHostSheet: View {
    let existingAliases: Set<String>
    /// When set (the AppKit-presented menu path), called with the added alias —
    /// nil on Cancel — instead of the SwiftUI dismiss, since the environment's
    /// DismissAction has no SwiftUI presentation to pop there.
    var completion: ((String?) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    /// Empty until the user types a name of their own; until then the field shows
    /// (and Add uses) the one derived from the address.
    @State private var typedAlias = ""
    @State private var user = ""
    @State private var key: KeyChoice = .defaults
    @State private var password = ""
    @State private var passwordRevealed = false
    @State private var port = ""
    @State private var writeError: String?
    /// Read once, on appear: the sheet is modal, so neither the config nor `~/.ssh`
    /// can change under it, and re-reading per keystroke would walk every file
    /// `Include` pulls in.
    @State private var keys: [SSHPublicKey] = []

    /// What goes on the block's `IdentityFile` line — which is the only question
    /// ssh_config can answer here, so it is the only one the row asks. `defaults`
    /// writes no line at all and lets ssh do what it does alone: try the agent,
    /// then the default key names. It leads for the same reason Tabby's auth
    /// selector leads with Auto and XPipe's strategy list leads with no identity.
    private enum KeyChoice: Hashable {
        case defaults
        case file(String)
        /// Not a value — the row that opens the file panel, reverted the moment it
        /// is chosen so the picker never rests on a verb.
        case choose
    }

    private var parsedAddress: (user: String, host: String, port: String) {
        SSHConfigFile.parseDestination(address)
    }

    private var derivedAlias: String {
        SSHConfigFile.suggestedAlias(forHost: parsedAddress.host, avoiding: existingAliases)
    }

    private var effectiveAlias: String {
        typedAlias.isEmpty ? derivedAlias : typedAlias.trimmingCharacters(in: .whitespaces)
    }

    /// A user or port written into the address wins over the field: it was typed
    /// later and more specifically, and typing it there is a correction.
    private var effectiveUser: String {
        parsedAddress.user.isEmpty ? user.trimmingCharacters(in: .whitespaces) : parsedAddress.user
    }

    private var effectivePort: String {
        parsedAddress.port.isEmpty ? port.trimmingCharacters(in: .whitespaces) : parsedAddress.port
    }

    private var effectiveIdentityFile: String {
        if case .file(let path) = key { return path }
        return ""
    }

    /// The first thing standing between the sheet and a working Add, or nil when
    /// nothing is. Shown in place rather than left to a greyed-out button, which
    /// states the problem exists without saying what it is.
    private var validationMessage: String? {
        if parsedAddress.host.isEmpty { return nil }
        if effectiveAlias.contains(" ") {
            return localized("A name can’t contain spaces — it’s what you type after `ssh`.")
        }
        if existingAliases.contains(effectiveAlias) {
            return localized("“\(effectiveAlias)” is already in your config.")
        }
        if !effectivePort.isEmpty, Int(effectivePort).map({ (1...65535).contains($0) }) != true {
            return localized("A port is a number from 1 to 65535.")
        }
        let values = [effectiveAlias, parsedAddress.host, effectiveUser, effectiveIdentityFile]
        // ssh_config has no escape for a literal double quote — such values can't
        // be written faithfully, so refuse rather than corrupt the file.
        if values.contains(where: { $0.contains("\"") }) {
            return localized("A double quote can’t be written to ssh config.")
        }
        // A line break would end the directive, and a pasted address carrying one
        // could append directives of its own. `appendHost` refuses it as well; this
        // is so the sheet says why instead of failing at the write.
        if values.contains(where: SSHConfigFile.isUnwritable) {
            return localized("A line break can’t be written to ssh config.")
        }
        if password.contains(where: \.isNewline) {
            return localized("A password can’t contain a line break.")
        }
        return nil
    }

    private var canAdd: Bool {
        !parsedAddress.host.isEmpty && !effectiveAlias.isEmpty && validationMessage == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    field(localized("Address"), text: $address, prompt: "server.example.com")
                    field(localized("Port"), text: $port, prompt: "22")
                    field(
                        localized("Name"), text: $typedAlias,
                        prompt: derivedAlias.isEmpty ? "myserver" : derivedAlias
                    )
                } header: {
                    SectionHeaderLabel(title: localized("Add SSH Host"))
                } footer: {
                    footer
                }
                Section {
                    field(localized("User"), text: $user, prompt: NSUserName())
                    keyPicker
                    passwordField
                } header: {
                    SectionHeaderLabel(title: localized("Credentials"))
                } footer: {
                    Text(localized("A key is the credential that works everywhere, including sessions running on the box. A password is saved to your Keychain, never to ssh config, and only ever read when ssh asks for it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let writeError {
                    Text(writeError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button(localized("Cancel")) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                // On the menu path adding also opens the connection — the button
                // must promise both (HIG: the label describes the result).
                Button(completion == nil ? localized("Add") : localized("Add & Connect"), action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(12)
        }
        .frame(width: 460, height: 452)
        .onAppear(perform: prefill)
    }

    /// Fills the credential fields from what the config already does, so the common
    /// case — another box reached the same way as the last one — is a matter of
    /// typing an address. Both fields stay visible and editable: a default you can
    /// see is a suggestion, and one you can't is a trap.
    private func prefill() {
        keys = SSHConfigFile.publicKeys()
        guard let common = SSHConfigFile.suggestedIdentities(in: SSHConfigFile.hosts()).first
        else { return }
        user = common.user
        if let identityFile = common.identityFile { key = .file(identityFile) }
    }

    /// Optional, and last: the credential that works in fewer places belongs under
    /// the one that works everywhere. Reveal follows the platform — `SecureField`
    /// until asked, so a shoulder gets nothing by default — and the value goes to
    /// the Keychain on Add, never into the block being written.
    private var passwordField: some View {
        LabeledContent(localized("Password")) {
            HStack(spacing: 6) {
                Group {
                    if passwordRevealed {
                        TextField("", text: $password, prompt: Text(localized("optional")))
                    } else {
                        SecureField("", text: $password, prompt: Text(localized("optional")))
                    }
                }
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                Button {
                    passwordRevealed.toggle()
                } label: {
                    Image(systemName: passwordRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(passwordRevealed ? localized("Hide") : localized("Show"))
            }
        }
    }

    /// One labelled row, values trailing-aligned the way the rest of Settings writes
    /// them (`AgentSettingsTab`'s Command row). A plain `TextField(label:)` lets each
    /// row size its own gap, so four fields land at four different left edges — the
    /// ragged column that made this sheet look thrown together.
    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        LabeledContent(label) {
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
        }
    }

    /// The keys in `~/.ssh` by name, led by the no-`IdentityFile` default. A key the
    /// user picked from elsewhere joins the list so the choice they made is a row
    /// they can see, rather than a path in a field.
    private var keyPicker: some View {
        Picker(localized("Key"), selection: $key) {
            Text(localized("Default keys")).tag(KeyChoice.defaults)
            ForEach(keyOptions, id: \.self) { path in
                Text((path as NSString).lastPathComponent).tag(KeyChoice.file(path))
            }
            Divider()
            Text(localized("Choose…")).tag(KeyChoice.choose)
        }
        .onChange(of: key) { previous, choice in
            guard choice == .choose else { return }
            // Never rest on the verb: the panel's outcome decides, and cancelling
            // leaves the row exactly where the user found it. Presented after this
            // transaction rather than inside it — `runModal` spins a nested event
            // loop, and starting one while SwiftUI is still applying the selection
            // it caused is how a picker flickers or wedges.
            DispatchQueue.main.async {
                key = chooseIdentityFile() ?? previous
            }
        }
    }

    /// The private-key paths to offer: every `~/.ssh` key, plus one picked from
    /// elsewhere, `~`-relative the way ssh configs are conventionally written.
    private var keyOptions: [String] {
        var paths = keys.map { "~/.ssh/" + $0.name.replacingOccurrences(of: ".pub", with: "") }
        if case .file(let path) = key, !paths.contains(path) { paths.append(path) }
        return paths
    }

    /// Either what's wrong, or what the sheet is about to do — stated as the command
    /// the user will be able to type, since that is the result they get. Before an
    /// address exists there is no command to promise, so it says only what it does.
    @ViewBuilder
    private var footer: some View {
        if let validationMessage {
            Text(.init(validationMessage))
                .font(.caption)
                .foregroundStyle(.orange)
        } else if effectiveAlias.isEmpty {
            Text(localized("Adds a Host block to ~/.ssh/config."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(.init(localized("Adds a Host block to ~/.ssh/config. You’ll be able to run `ssh \(effectiveAlias)` anywhere.")))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        do {
            try SSHConfigFile.appendHost(
                alias: effectiveAlias,
                hostName: parsedAddress.host,
                user: effectiveUser,
                port: effectivePort,
                identityFile: effectiveIdentityFile
            )
        } catch {
            writeError = localized("Couldn’t write ~/.ssh/config: \(error.localizedDescription)")
            return
        }
        // After the block, and never fatal to it: the host is added and reachable
        // by hand either way, so a Keychain that refuses is worth reporting rather
        // than a reason to throw the block away.
        if !password.isEmpty {
            do {
                try SSHPasswordStore.save(password, for: effectiveAlias)
            } catch {
                writeError = error.localizedDescription
                return
            }
        }
        finish(effectiveAlias)
    }

    private func finish(_ addedAlias: String?) {
        if let completion { completion(addedAlias) } else { dismiss() }
    }

    /// A file picker starting in `~/.ssh` with hidden files visible (the whole
    /// directory is dot-hidden). The chosen path is stored `~`-relative, the way
    /// ssh configs are conventionally written. nil when the panel was cancelled.
    private func chooseIdentityFile() -> KeyChoice? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = SSHConfigFile.configURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        // `IdentityFile` names the private key; picking the public half is the
        // easy slip, since that is the file people hand around.
        let privatePath = path.hasSuffix(".pub") ? String(path.dropLast(4)) : path
        return .file(
            privatePath.hasPrefix(home + "/")
                ? "~" + privatePath.dropFirst(home.count)
                : privatePath
        )
    }
}
