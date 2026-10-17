import AppKit
import Combine
import Foundation

/// The current selection in the file tree, shared between the SwiftUI view (which
/// writes it) and the hosting controller (which reads it to feed Quick Look). Held
/// as its own object so the controller can answer `QLPreviewPanel`'s data-source
/// callbacks without reaching into SwiftUI's view state.
@MainActor
final class FileBrowserState: NSObject, ObservableObject {
    /// The selected row, as the path on whichever device the checkout lives on.
    /// A path rather than a URL because the tree is the device's: only a
    /// checkout on this Mac has a `URL` that addresses anything.
    @Published var selection: String?
    /// The selection as a file on *this* Mac, or nil for a checkout on another
    /// device. Quick Look previews a local file or nothing.
    @Published var selectedLocalURL: URL?
    /// The tree's outline controller, captured by `FileTreeList` so
    /// `FileBrowserView` can reveal a path through it. Not `@Published` — it's
    /// an AppKit escape hatch, not view state.
    weak var outline: FileOutlineController?
}
