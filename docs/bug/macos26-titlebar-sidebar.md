# Debug journal — macOS 26 title bar & full-height sidebar

A record of the title-bar / sidebar chrome saga: the symptoms, what each fix
actually addressed, the dead ends, and the one OS bug we could not beat. Written
so the next person (or the next me) does not re-walk the same wall.

**Platform:** macOS 26 (Tahoe, 26.4 / 26.5) · **Stack:** AppKit `NSWindow` +
`NSSplitViewController` hosting SwiftUI panes + libghostty terminal.

**TL;DR of where we landed:** custom sidebar chrome was abandoned. We use the
**native macOS `.sidebar`** split item (vibrant full-height material, native
toggle, tracking separator) and accept one residual OS bug (the sidebar glass
seam after a full-screen round-trip — see Bug 6). The title bar is painted by
hand on the *detail* side only; the sidebar side is left clear so the native
glass shows through.

---

## The setup that makes all of this load-bearing

We do **not** use the SwiftUI `App`/`WindowGroup` lifecycle. We drive
`NSApplication` directly and build the window in `applicationDidFinishLaunching`
(see `App.swift`). The split is a real AppKit `NSSplitViewController` whose first
item is created with `NSSplitViewItem(sidebarWithViewController:)` and
`allowsFullHeightLayout = true`.

Why this matters: **the native full-height sidebar treatment** (vibrant material
running up behind the traffic lights, the system toggle, the title-bar tracking
separator) is *only* available to a real `.sidebar` `NSSplitViewItem`, or to a
SwiftUI `NavigationSplitView` that is the **root of a `WindowGroup` scene**. A
`NavigationSplitView` hosted inside a manual `NSWindow` renders as an embedded
representable with **no connection to the title bar** — it can never reach behind
the traffic lights. We proved this with lldb (the sidebar column had no
title-bar-linked superview). So once we chose the manual-`NSWindow` bootstrap (for
reliable terminal key/focus handling), the AppKit split controller was forced.

The window is configured:

- `styleMask` includes `.fullSizeContentView`; `titlebarAppearsTransparent = true`;
  `titleVisibility = .hidden` (a visible title forces a tall second toolbar row).
- `toolbarStyle = .automatic` — splits the title bar at the sidebar divider (like
  NetNewsWire), so the sidebar's vibrant material runs up behind the traffic
  lights. `.unified` would paint one flat full-width band instead.
- `titlebarSeparatorStyle = .none` — see Bug 2.

---

## Bug 1 — White band across the title bar over the terminal

**Symptom:** a bright/white horizontal band at the very top of the window, over
the terminal (the detail pane).

**Cause:** on macOS 26 the toolbar's **Liquid Glass** material renders white over
the detail pane. The obvious SwiftUI fix —
`.toolbarBackground(_:for: .windowToolbar)` — **never reaches the real
`NSToolbar`**, because our toolbar is bridged up from a child hosting controller
(`sceneBridgingOptions`), and that bridge does **not** carry the background
preference. `sceneBridgingOptions = [.toolbars]` carries the items, not
`.toolbarBackground`.

**Fix:** paint the title bar ourselves. `TitleBarBackgroundView` is an `NSView`
injected as a subview of the title-bar view (found via
`window.standardWindowButton(.closeButton)?.superview`, i.e. the private
`NSTitlebarView`), sitting *behind* the toolbar's glass. It carries the terminal
background color on the detail slice. See `applyTitleBarBackground()` and
`TitleBarBackgroundView` in `App.swift`.

---

## Bug 2 — White hairline at the sidebar/detail divider

**Symptom:** after Bug 1's fill, a thin white vertical line remained where the
sidebar met the detail pane, up in the title-bar strip.

**Cause:** the toolbar glass showed through the **divider strip** between the two
title-bar slices.

**Fix (two parts):**

1. `TitleBarBackgroundView` is split into **two `CALayer`s**: `sidebarLayer`
   (x `0…inset`) and `detailLayer` (x `inset…width`). The sidebar slice is left
   **clear** so the native sidebar glass shows through; only the detail slice is
   filled with the terminal color. The seam is gone because the detail fill starts
   exactly at the sidebar edge (`sidebarInsetProvider` → `sidebarTitleBarInset()`),
   not at `inset + dividerThickness`.
2. `window.titlebarSeparatorStyle = .none`, pinned. With the sidebar **expanded**,
   the full-height vibrant column + tracking separator already suppress the
   hairline; but on **collapse** that integration is gone and `.automatic`
   reasserts a grey separator line that reads as a shadow over the terminal — so
   the bar looked different collapsed vs expanded. Pinning `.none` keeps it
   seamless in both states.

> **Lesson (from Ghostty PR #10105):** title-bar geometry on macOS 26 changes
> across transitions (full screen, sidebar collapse, resize). Re-derive the inset
> on **every** `layout()` / relevant notification, never cache it once. The fill
> and chips both recompute their frames from `sidebarTitleBarInset()` each layout.

---

## Bug 3 — Sidebar toggle: placement & disappearance

**Question the user raised:** where does the collapse button conventionally live?
**Answer:** leading edge, over the sidebar — the standard macOS spot.

**Path:** the native sidebar toggle (`NSToolbarItem.Identifier.toggleSidebar`)
only exists for an `NSSplitViewController` with a real `.sidebar` item — which we
have. We register it in `MainToolbarDelegate` alongside `.sidebarTrackingSeparator`
(see `installToolbar()`).

**Dead end:** an early custom `SidebarToggleButton` (SwiftUI) and a `.navigation`
toolbar placement — the bridged sidebar toolbar wouldn't render a `.navigation`
item, and a custom toggle vanished after one use. Abandoned in favor of the
native item.

---

## Bug 4 — Path/branch chips had a button-like glass capsule

**Symptom:** the path & branch chips in the title bar looked like tappable buttons
(macOS 26 wraps **every** `NSToolbarItem` in a Liquid Glass capsule, and there is
**no AppKit opt-out** — `.sharedBackgroundVisibility(.hidden)` is SwiftUI-only).

**Fix:** don't host the chips as a toolbar item at all. `TitleBarChips`
(SwiftUI, in `TerminalPane.swift`) is injected **straight into the title-bar
view** like the fill, positioned by hand. An observer on `store.objectWillChange`
re-runs `applyTitleBarChips()` so the frame follows the selected session's
path/branch width. The chips use a soft `.quaternary` pill, not a button material.

---

## Bug 5 — Full-screen top padding

**Symptom:** in native full screen the terminal's first line sat flush against the
top edge (toolbar auto-hides), and the sidebar needed breathing room too.

**Fix:** `terminalTopInset` in `TerminalPane.swift`:

- full screen → `18` pt of breathing room (replaces the auto-hidden toolbar);
- windowed + sidebar collapsed → `28` pt (traffic lights + toggle move over the
  terminal's top-left and need a clear strip);
- windowed + sidebar expanded → `0` (that chrome is over the sidebar; terminal
  runs flush).

`store.isFullScreen` is set from `windowDidEnterFullScreen` / `…ExitFullScreen`.
We also insert `.autoHideToolbar` in `window(_:willUseFullScreenPresentationOptions:)`.

---

## Bug 6 — THE UNSOLVED ONE: native sidebar glass seam after a full-screen round-trip

**Symptom:** on a fresh launch the sidebar looks perfect — vibrant material runs
full-height up behind the traffic lights. **Enter native full screen, then exit**,
and the top of the sidebar is now **cut off / covered**: the glass no longer
re-extends into the title-bar region. A seam appears at the sidebar head.

**This is a macOS 26 OS bug, not ours.** Confirmed via web search:

- Ghostty issues **#10121** and **#8595** describe the same failure and are
  **open / unfixed**.
- macOS **26.4 and 26.5** did not fix it.
- There is **no public API workaround**.

**Things we tried that did NOT fix it:**

- Re-asserting `sidebarItem.allowsFullHeightLayout = true` after exit.
- Reinstalling the toolbar / tracking separator after exit.
- Programmatic collapse → re-expand of the sidebar.
- Toggling `styleMask` (`.fullSizeContentView`) off/on.
- Recreating the entire content split view controller on exit.
- Re-homing the title-bar fill + chips into the new container (this is correct and
  retained — it fixes the *fill*, but the **native glass** seam is OS-side and
  unreachable).
- Hiding/flattening the private backing views (`NSBlurryAlleywayView` =
  wallpaper backdrop, `NSContainerConcentricGlassEffectView` = the rounded glass
  card). **Hiding the concentric glass view blanked the whole sidebar** — the
  sidebar *content* lives inside it (this produced the "怎么什么也看不见了?" moment).

**What we kept as mitigation:** `syncFullScreenTitlebarColor()` (called from
`windowDidBecomeMain` and the full-screen notifications) repaints the full-screen
toolbar overlay; `windowDidExitFullScreen` does a deferred re-home of
`applyTitleBarBackground()` + `applyTitleBarChips()`. These keep *our* paint
correct; the native glass seam remains.

---

## The long detour: custom sidebar chrome (all reverted)

Because Bug 6 is unfixable from our side, we spent many iterations trying to
*replace* the native sidebar glass with custom chrome that wouldn't have the seam:

| Attempt | Why it was dropped |
|---|---|
| Flat uniform panel fill (`sidebarPanelColor`) | Lost the native vibrancy; still had divider/shadow artifacts |
| VS Code-style two vertical lines joined to the top | In dark mode the seam/border still read; shadow at the divider |
| Rounded card around the right (terminal + title) section | Dragging target unclear; border-only-on-one-side looked off |
| Plain split item + custom collapse button | Border reappeared; thin divider line; toggle didn't work |
| `tameSidebarVibrancy`, hiding/flattening private glass views | Blanked the sidebar (content is inside the glass view) |

**Final user directive:** *"the ui is quite messy, use macOS 自带的 sidebar 吧."* We
reverted **all** custom sidebar code and went back to the native `.sidebar`,
accepting Bug 6.

**Removed in the revert (now gone from the tree):** `tameSidebarVibrancy`,
`FyoloSplitViewController`, `addSidebarToggleAccessory`, `toggleSidebarColumn`,
`dividerLayer`, `reEstablishFullHeightSidebar`, `rebuildSidebarColumn`,
`SidebarToggleButton`, `FlatSidebarBackground`, `ChromeTheme.sidebarPanelColor`.

`SidebarView.swift` is back to native:

```swift
.listStyle(.sidebar)
.environment(\.defaultMinListRowHeight, 1)
.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
```

---

## What survives in the code (the parts worth keeping)

- **`TitleBarBackgroundView`** — two-layer title-bar fill: sidebar slice clear,
  detail slice = terminal color. Re-laid-out every `layout()`.
- **`applyTitleBarBackground()` / `applyTitleBarChips()` / `layoutTitleBarChips()`** —
  inject + position the fill and chips in the private title-bar view; re-home on
  full-screen transitions.
- **`sidebarTitleBarInset()`** — single source of truth for where the sidebar
  slice ends / the detail fill begins.
- **`syncFullScreenTitlebarColor()`** — paints the full-screen toolbar overlay
  (walks the view tree breadth-first for `NSTitlebarView` / `NSTitlebarBackgroundView`).
- **`store.isFullScreen` / `store.isSidebarCollapsed`** — drive `terminalTopInset`
  and chip positioning.

---

## Hard-won lessons

1. **The SwiftUI title-bar/sidebar APIs don't cross the AppKit bridge.**
   `.toolbarBackground`, `.sharedBackgroundVisibility(.hidden)`, `.navigation`
   placement — none reach a bridged `NSToolbar`. If you host SwiftUI inside a
   manual `NSWindow`, plan to do title-bar chrome in AppKit.
2. **Full-height native sidebar requires a real AppKit `.sidebar` split item** (or
   a root-of-`WindowGroup` `NavigationSplitView`). Hosted SwiftUI split views
   can't reach the title bar. Verified with lldb.
3. **macOS 26 title-bar geometry is transition-dependent.** Re-derive insets every
   layout (Ghostty PR #10105), never cache once.
4. **Don't fight an OS bug past the point of diminishing returns.** Bug 6 ate the
   most time for zero yield. Once the web search confirmed it was open upstream
   with no API workaround, the right move was to accept it and revert to native.
5. **The private glass views are load-bearing.**
   `NSContainerConcentricGlassEffectView` *contains* the sidebar content — hide it
   and the sidebar goes blank. Don't treat private chrome views as pure decoration.

---

## Open follow-ups

- **Bug 6** remains, gated on Apple. Watch Ghostty #10121 / #8595 for an API-level
  workaround.
- The screenshot-debug environment was unreliable during this work (kept capturing
  the wrong window / overlays). Verify UI changes against a real, focused capture.
