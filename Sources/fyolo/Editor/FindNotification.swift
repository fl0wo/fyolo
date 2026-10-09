import Foundation

extension Notification.Name {
    /// ⌘F broadcast. Broadcast instead of the responder chain so the menu item stays enabled
    /// whenever an editor is on screen even if the terminal holds first responder.
    static let fyoloShowFindBar = Notification.Name("fyolo.showFindBar")
    /// ⌘G / ⇧⌘G. Broadcast for the same reason ⌘F is; a find bar that isn't open ignores them.
    static let fyoloFindNext = Notification.Name("fyolo.findNext")
    static let fyoloFindPrevious = Notification.Name("fyolo.findPrevious")
    /// ⌘E. Only the editor whose own text view holds the keyboard acts on it, so a second
    /// overlay mounted behind the first can't take its query from a buffer nobody is in.
    static let fyoloUseSelectionForFind = Notification.Name("fyolo.useSelectionForFind")
}
