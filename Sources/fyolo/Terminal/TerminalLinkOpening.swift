import AppKit
import Foundation
import GhosttyTerminal

extension Notification.Name {
    /// Posted when the user cmd-clicks a hyperlink (an OSC 8 link, or a URL/`file://` path
    /// libghostty auto-detected) inside a terminal surface. `object` is the `TerminalViewState`
    /// that fired it; `userInfo[TerminalLinkKey.url]` carries the raw link string. `FyoloStore`
    /// observes this to route local files into the read-only preview overlay and web links to the
    /// system browser.
    static let fyoloTerminalOpenURL = Notification.Name("fyolo.terminalOpenURL")
}

enum TerminalLinkKey {
    static let url = "url"
}

// libghostty's `TerminalViewRepresentable` hardcodes the surface delegate to the `TerminalViewState`,
// and that state does not itself implement the open-URL delegate — so a cmd-click is dispatched by
// the callback bridge but lands nowhere. Conforming the state to the protocol here (retroactively,
// from fyolo's own module) makes the bridge's `delegate as? any TerminalSurfaceOpenURLDelegate`
// cast succeed at runtime, with no fork of the prebuilt library. The state has no back-reference to
// the store, so it republishes the event as a notification the store picks up (keyed by the state
// instance, whose published `workingDirectory` resolves any relative path).
extension TerminalViewState: @retroactive TerminalSurfaceOpenURLDelegate {
    public func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        // Fallback path: ghostty fires this on cmd-click of a link it handles itself. In practice
        // it rarely (never, in testing) reaches us — a plain shell's click is consumed by the
        // app-wide interceptor first, and a mouse-capturing TUI never lets ghostty handle the click
        // at all. Kept so any context where ghostty *does* open a URL still routes through us.
        NotificationCenter.default.post(
            name: .fyoloTerminalOpenURL,
            object: self,
            userInfo: [TerminalLinkKey.url: url]
        )
    }
}

// Same retroactive-conformance trick for hover feedback: the prebuilt library never touches
// `NSCursor` (its tracking area doesn't even request `.cursorUpdate`, so the terminal shows the
// plain arrow everywhere and ghostty's MOUSE_SHAPE action is dropped). ghostty does fire
// MouseOverLink as the hovered link changes — even inside a mouse-capturing TUI, where it declines
// to draw its own underline but still tells us the URL. We use that both to swap in the pointing-hand
// cursor (the VS Code feel) and to remember the hovered URL so the cmd-click interceptor can open it.
extension TerminalViewState: @retroactive TerminalSurfaceHoverLinkDelegate {
    public func terminalDidUpdateHoverLink(_ url: String?) {
        TerminalLinkState.update(hoveredURL: url)
    }
}

/// Tracks the hyperlink currently under the mouse (from ghostty's hover detection) and drives the
/// pointing-hand cursor. `hoveredURL` is read by `FyoloStore`'s cmd-click interceptor so a click
/// opens whatever link is hovered — which is what makes link-clicking work even inside a TUI, where
/// ghostty won't fire its own `open_url`. There is only one mouse, so this is a single main-actor
/// state. MouseOverLink fires only when the hovered link *changes*, so the cursor is pushed on the
/// first non-nil and popped on the next nil — a guarded transition, never an unbalanced push/pop.
@MainActor
enum TerminalLinkState {
    private(set) static var hoveredURL: String?
    private static var showingPointer = false

    static func update(hoveredURL url: String?) {
        hoveredURL = url
        let hovering = url != nil
        if hovering, !showingPointer {
            NSCursor.pointingHand.push()
            showingPointer = true
        } else if !hovering, showingPointer {
            NSCursor.pop()
            showingPointer = false
        }
    }
}
