import Foundation
import FyoloShared

extension Fyolod {
    /// The account's home directory on the device, from the handshake the pooled
    /// channel already performed. Free once a channel to that machine is open,
    /// and one connection's worth otherwise — which is what a picker needs
    /// before it can show the user anywhere at all.
    ///
    /// Blocking; call it off the main thread.
    static func deviceHome(route: FyolodRoute, caps: [String] = filesCapabilities) throws -> String {
        let channel = try ControlPool.channel(route: route, caps: caps)
        guard channel.capabilities.contains("files") else {
            throw DeviceFileError.unsupported
        }
        return channel.home
    }
}

/// Lists directories on another machine for a path field — the project picker's
/// half of the files plane (§C.12, capability `files`).
///
/// Deliberately *not* a file browser: a path field asks for the directory the
/// user is currently typing inside, and the answer is one `fs.list`. Nothing
/// walks a tree, so a machine with a huge checkout costs the same as an empty
/// one.
///
/// This used to hold a private control channel open, because opening one per
/// keystroke means `ssh <host> fyolod stdio` and a whole SSH round trip on
/// every `/` the user types. That reasoning was right and is now general:
/// `ControlPool` holds one channel per device for the tree, the file reader, the
/// search and this, so a picker opened over a checkout that is already on screen
/// pays nothing at all. What is left here is the part that was ever specific to
/// a picker — which entries it keeps and the order it reads them in.
final class FyolodDirectoryLister: @unchecked Sendable {
    /// A directory that can be descended into, which is all a project picker
    /// offers — a file is never a project root.
    struct Entry: Sendable, Equatable {
        let name: String
    }

    enum Failure: Error {
        /// The daemon answered, but refused this path — gone, unreadable, or
        /// outside the root. Carries the daemon's own words.
        case refused(String)
    }

    private let route: FyolodRoute
    /// Serialises the requests. The channel underneath multiplexes happily, but
    /// a path field has exactly one question outstanding — the directory the
    /// caret is in — so overlapping them would only race answers onto the same
    /// field.
    private let queue = DispatchQueue(label: "sh.fyolo.fyolod.directory-lister")

    init(route: FyolodRoute) {
        self.route = route
    }

    /// Reports the home directory to start from, opening the device's channel if
    /// this is the first thing to reach it. Called once, off the main thread.
    func connect(completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        queue.async { [route] in
            completion(Result {
                do {
                    return try Fyolod.deviceHome(route: route)
                } catch DeviceFileError.unsupported {
                    // An older daemon that never learned the file plane. The
                    // picker still opens; it just cannot complete a path.
                    throw Failure.refused(
                        localized("This machine’s fyolod is too old to list folders."))
                }
            })
        }
    }

    /// The directories directly inside `path`, sorted the way a picker reads:
    /// case-insensitively, with dot-directories last so `~/.cache` never sits
    /// above `~/code`.
    ///
    /// `root` is `path` itself. Confinement is anchored at the directory being
    /// listed rather than at some remembered ancestor, because the field lets
    /// the user retype the whole path at any moment — anchoring anywhere else
    /// would refuse a sibling directory the user can plainly `cd` to.
    func list(_ path: String, completion: @escaping @Sendable (Result<[Entry], Error>) -> Void) {
        queue.async { [route] in
            completion(Result {
                let listings = try Fyolod.listDirectories(
                    route: route, root: path, paths: [path])
                guard let listing = listings.listings.first else {
                    throw Failure.refused(
                        localized("The machine answered with no listing for that folder."))
                }
                if let message = listing.error { throw Failure.refused(message) }
                return listing.entries
                    .filter(\.isDirectory)
                    .map { Entry(name: $0.name) }
                    .sorted { left, right in
                        let leftHidden = left.name.hasPrefix(".")
                        let rightHidden = right.name.hasPrefix(".")
                        if leftHidden != rightHidden { return rightHidden }
                        return left.name.localizedStandardCompare(right.name) == .orderedAscending
                    }
            })
        }
    }
}
