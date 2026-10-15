import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

// MARK: - Scope

/// What one note belongs to: a project, one of its worktrees, or nothing in
/// particular (a session that answers to no project). Worktrees are the
/// sidebar's branch level, so a note per worktree is a note per branch that
/// never vanishes on `git checkout`.
enum NoteScope: Hashable, Sendable {
    case scratch
    /// `machine` is the workspace's device alias, `nil` on this Mac, so two
    /// machines' checkouts at the same path keep separate notes.
    case project(name: String, path: String, machine: String?)
    case worktree(projectName: String, projectPath: String, machine: String?, path: String)

    var title: String {
        switch self {
        case .scratch: return localized("Scratch")
        case .project(let name, _, _): return name
        case .worktree(let projectName, _, _, let path):
            return "\(projectName) › \(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }

    /// The folder the note is about, shown under the title.
    var subtitle: String? {
        switch self {
        case .scratch: return nil
        case .project(_, let path, let machine), .worktree(_, _, let machine, let path):
            return machine.map { "\($0):\(path)" } ?? path
        }
    }
}

// MARK: - Files

/// Notes on disk, under `~/.fyolo/notes`: one Markdown file per project, a
/// folder per project for its worktrees' notes, `scratch.md`, and the images
/// pasted into any of them under `attachments/`. Plain files, so they outlive
/// the app, show up in `grep`, and an agent can read or append to them.
enum NotesLibrary {
    static var directory: URL {
        AppChannel.homeConfigDirectory.appendingPathComponent("notes", isDirectory: true)
    }

    static let attachmentsFolder = "attachments"

    /// The note's file. A file is found by the hash of its folder's path, not by
    /// its whole name, so renaming the project in the sidebar keeps its note;
    /// the readable slug in front is only for someone browsing the folder.
    static func fileURL(for scope: NoteScope, in directory: URL = directory) -> URL {
        switch scope {
        case .scratch:
            return directory.appendingPathComponent("scratch.md")
        case .project(let name, let path, let machine):
            return existing(in: directory, hash: hash(machine, path), suffix: ".md")
                ?? directory.appendingPathComponent("\(slug(name))-\(hash(machine, path)).md")
        case .worktree(let projectName, let projectPath, let machine, let path):
            let projectHash = hash(machine, projectPath)
            let folder = existing(in: directory, hash: projectHash, suffix: "")
                ?? directory.appendingPathComponent("\(slug(projectName))-\(projectHash)", isDirectory: true)
            let worktreeHash = hash(machine, path)
            return existing(in: folder, hash: worktreeHash, suffix: ".md")
                ?? folder.appendingPathComponent(
                    "\(slug(URL(fileURLWithPath: path).lastPathComponent))-\(worktreeHash).md")
        }
    }

    private static func existing(in directory: URL, hash: String, suffix: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.first { $0.hasSuffix("-\(hash)\(suffix)") }.map {
            directory.appendingPathComponent($0, isDirectory: suffix.isEmpty)
        }
    }

    /// FNV-1a over the machine and path. Swift's own `hashValue` changes on
    /// every launch, so it can't name a file.
    static func hash(_ machine: String?, _ path: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(machine ?? "")|\(path)".utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(String(value, radix: 16).suffix(8)).leftPadded(to: 8)
    }

    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var slug = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "note" : String(trimmed.prefix(40))
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Keeps a copy of a pasted or dropped image beside the notes, so the note
    /// still shows it after the original — a screenshot on the Desktop, a file
    /// in Downloads — is gone. Returns the path the note links to.
    static func storeAttachment(_ data: Data, fileExtension: String, in directory: URL = directory) throws -> String {
        let name = "\(UUID().uuidString.prefix(8).lowercased()).\(fileExtension)"
        let url = directory.appendingPathComponent(attachmentsFolder, isDirectory: true).appendingPathComponent(name)
        try write(data, to: url)
        return "\(attachmentsFolder)/\(name)"
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// What a link in a note points at: a web or file URL as written, or a
    /// path relative to the notes folder (where attachments live).
    static func resolve(_ link: String, in directory: URL = directory) -> URL? {
        if let url = URL(string: link), url.scheme != nil { return url }
        if link.hasPrefix("/") || link.hasPrefix("~") {
            return URL(fileURLWithPath: (link as NSString).expandingTildeInPath)
        }
        let decoded = link.removingPercentEncoding ?? link
        return directory.appendingPathComponent(decoded)
    }

    /// The Markdown a dropped or pasted file becomes: an image is copied in and
    /// shown as an image link; anything else is linked where it lives.
    static func markdown(forFile url: URL, in directory: URL = directory) -> String {
        let name = url.lastPathComponent
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        if isImage, let data = try? Data(contentsOf: url),
           let path = try? storeAttachment(data, fileExtension: url.pathExtension.lowercased(), in: directory) {
            return "![\(name)](\(path))"
        }
        return "[\(name)](\(url.absoluteString))"
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}

// MARK: - Document

/// One note, open. Edits save themselves half a second after typing stops, and
/// again whenever the note is left, so nothing waits on a Save command. A
/// change made on disk meanwhile — an agent appending to the file — is picked
/// up; if it collides with unsaved typing, neither is lost: the disk version is
/// kept beside the note and named in the page.
@MainActor
final class NoteDocument: ObservableObject {
    let scope: NoteScope
    let url: URL
    @Published private(set) var text: String
    @Published private(set) var lastSaved: Date?
    @Published private(set) var conflictCopy: URL?
    @Published private(set) var saveError: String?
    @Published private(set) var isDirty = false

    /// The file as last read or written, to tell someone else's change from our own.
    private var diskText: String
    private var diskModified: Date?
    private var saveTask: Task<Void, Never>?

    static let saveDelay: Duration = .milliseconds(500)

    init(scope: NoteScope, directory: URL = NotesLibrary.directory) {
        self.scope = scope
        url = NotesLibrary.fileURL(for: scope, in: directory)
        let loaded = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = loaded
        diskText = loaded
        diskModified = NotesLibrary.modificationDate(of: url)
    }

    func edit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty else { return }
        preserveDiskChangeIfAny()
        do {
            if text.isEmpty, FileManager.default.fileExists(atPath: url.path) {
                // An emptied note leaves no empty file behind.
                try FileManager.default.removeItem(at: url)
            } else if !text.isEmpty {
                try NotesLibrary.write(text, to: url)
            }
            diskText = text
            diskModified = NotesLibrary.modificationDate(of: url)
            isDirty = false
            lastSaved = Date()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            Log.app.error("saving the note at \(self.url.path, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// Picks up a change made outside the page. Returns whether `text` was
    /// replaced, so the editor knows to redraw.
    @discardableResult
    func reloadIfChangedOnDisk() -> Bool {
        let modified = NotesLibrary.modificationDate(of: url)
        guard modified != diskModified else { return false }
        let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        diskModified = modified
        guard onDisk != diskText else { return false }
        if isDirty {
            preserve(onDisk)
            diskText = onDisk
            return false
        }
        diskText = onDisk
        text = onDisk
        return true
    }

    func dismissConflict() { conflictCopy = nil }

    /// Before overwriting the file, keeps a version someone else wrote since we
    /// last read it.
    private func preserveDiskChangeIfAny() {
        let modified = NotesLibrary.modificationDate(of: url)
        guard modified != diskModified,
              let onDisk = try? String(contentsOf: url, encoding: .utf8), onDisk != diskText
        else { return }
        preserve(onDisk)
    }

    private func preserve(_ otherVersion: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let copy = url.deletingPathExtension().appendingPathExtension("conflict-\(stamp).md")
        do {
            try NotesLibrary.write(otherVersion, to: copy)
            conflictCopy = copy
        } catch {
            Log.app.error("keeping the conflicting note failed: \(error, privacy: .public)")
        }
    }
}

// MARK: - Page state

/// The note on screen and the notes opened before it, kept so switching back
/// and forth between projects is instant.
@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var document: NoteDocument
    private var opened: [NoteScope: NoteDocument] = [:]
    private let directory: URL

    init(scope: NoteScope, directory: URL = NotesLibrary.directory) {
        self.directory = directory
        let document = NoteDocument(scope: scope, directory: directory)
        self.document = document
        opened[scope] = document
    }

    func show(_ scope: NoteScope) {
        guard scope != document.scope else { return }
        document.saveNow()
        if let cached = opened[scope] {
            cached.reloadIfChangedOnDisk()
            document = cached
        } else {
            let fresh = NoteDocument(scope: scope, directory: directory)
            opened[scope] = fresh
            document = fresh
        }
    }

    func saveAll() {
        for document in opened.values { document.saveNow() }
    }
}

extension FyoloStore {
    /// The note for what the sidebar has selected: the session's worktree when
    /// it runs in one, else its project, else the scratch note.
    var selectedNoteScope: NoteScope {
        guard let id = selectedSessionID, let project = project(for: id) else { return .scratch }
        let machine = workspaces.first { $0.id == project.workspaceID }?.deviceAlias
        if let worktreePath = session(id)?.worktreePath, worktreePath != project.path {
            return .worktree(projectName: project.name, projectPath: project.path, machine: machine, path: worktreePath)
        }
        return .project(name: project.name, path: project.path, machine: machine)
    }
}
