---
title: The tab strip is the collapsed sidebar
status: draft
type: rfc
created: 2026-08-29
updated: 2026-08-31
related:
  - 20260702-split-panes.md
  - 20260628-worktree-information-architecture.md
  - 20260713-loose-terminal-entity.md
  - 20260812-keyboard-command-design.md
  - 20260818-one-workspace-source.md
---

# The tab strip is the collapsed sidebar

> Give the window a horizontal tab strip that appears only when the sidebar is
> collapsed, drawn from the same row model the sidebar draws. A tab is a split
> group (or a lone session); a tab group is a sidebar section or a project, the
> way a Chrome tab group is a collapsible section in Chrome's vertical tabs.
> Only the group holding the selection is open; the rest fold to their chips.
> Settings › Appearance › Tabs (*Vertical* / *Horizontal*) is the navigator
> toggle by another name. No new mode, no new shortcut, nothing new persisted.

## The one idea

Fyolo has one session switcher, the sidebar, and one way to hide it, the
navigator toggle. Hiding it today leaves nothing behind: the band above the
terminal holds the toggle, the branch picker and the inspector switch, and the
user is flying blind — no status rings, no way to see which agent went
`needs-you`, no way to switch except ⌘⇧[ / ⌘⇧], the Session menu, or Open
Quickly. So nobody collapses the sidebar, and 240pt of a 13" screen stays spent
on a list they are not reading while an agent works.

Superlogical's two screenshots settle what the fix is. In the vertical one the
sidebar is open and the title bar carries only the session's name. In the
horizontal one the sidebar is closed and the title bar carries the tabs. Those
are not two "tab layouts" the user picks between. They are the sidebar toggle,
and the strip is what a collapsed sidebar *becomes*.

```
 sidebar open                                    sidebar collapsed
 ┌────────────────┬─────────────────────────┐   ┌─────────────────────────────────────────────────────┐
 │ ☰ Work   ⇅ +   │ fyolo · main      ⊞ ▤  │   │ ☰ Work ▾│fyolo·main│● Claude│○ zsh│Terminals│+ ⊞ ▤ │
 ├────────────────┼─────────────────────────┤   ├─────────────────────────────────────────────────────┤
 │ ▾ fyolo       │                         │   │                                                     │
 │   ● Claude  ◀──┼── selected              │   │  $ claude                                           │
 │   ○ zsh        │                         │   │  ▌                                                  │
 │ ▾ Terminals    │                         │   │                                                     │
 │   ○ zsh        │                         │   │                                                     │
 └────────────────┴─────────────────────────┘   └─────────────────────────────────────────────────────┘
                                           ☰ ───────▶
                    one toggle, one row model, two geometries
```

The choice gets two handles and one state. The navigator toggle is one; a
**Tabs: Vertical / Horizontal** picker in Settings › Appearance is the other,
and the strip's context menu carries *Show Tabs Vertically* as Chrome's does.
All three flip the sidebar's collapse — the state `NSSplitView` already
autosaves — so someone who wants a horizontal browser can say so once in
Settings, and someone who just wants the sidebar gone clicks the toggle as
today. There is no third state in which the setting says one thing and the
window shows another.

That is the whole proposal. The rest of this document is what falls out of it.

## Why this is not the tab strip that was dropped

On 2026-07-06 a Safari-style session tab strip was built for the detail column
and dropped the same day: "感觉这种UI方式没什么用". It sat *beside* an open
sidebar and listed the selected project's sessions — a second switcher showing a
subset of the first. The worktree IA doc records the same verdict against
pushing sessions into a content-area strip. Both stand.

| | Dropped strip (2026-07-06) | This RFC |
| --- | --- | --- |
| Visible when | Always, beside the sidebar | Only while the sidebar is collapsed |
| Shows | The selected project's sessions | Everything the sidebar shows, same order |
| Model | Its own | The sidebar's row model, second geometry |
| Net switchers on screen | Two | One |
| What it buys | Nothing the sidebar lacked | A collapsed sidebar that still works |

The redundancy argument was correct and it is exactly what the visibility rule
removes: the strip and the sidebar are never on screen together, so there is
never a second copy of anything.

## What the neighbours do, and why

### Superlogical

The strip lives in the title bar. Its leading control is a sidebar glyph that
also opens the workspace menu — *Filter or create…*, a checked **Demo**, *New
Session ⇧⌘N*, *Add Remote Host…* — so one click either reopens the vertical
view or changes which workspace the strip is showing. Inactive tabs are
separated by hairlines that vanish beside the active tab (Chrome's rule); the
active tab is a lifted pill; `+` trails.

Why the strip shows one workspace and the sidebar shows all of them (**Demo**
and **Work** are both sections in the vertical view): Superlogical's tree is
flat — workspace → sessions — so a single row of tabs can carry one workspace
and nothing else without losing structure. The dropdown is how the other
workspaces stay one click away. Their tab is one surface; splits are separate
native windows, so "a tab of several panes" never arises for them.

### Chrome tab groups

On desktop Chrome a group is a contiguous run of tabs headed by a coloured chip
carrying the group's name, with the colour underlining the run. Clicking the
chip collapses the run to the chip alone; the tabs stay open, they are just not
drawn. Dragging a tab into the run joins the group, dragging it out leaves it,
dragging the chip moves the whole run. The chip's context menu is the group's
verb set: *New tab in group*, *Ungroup*, *Close group*, *Move group to new
window*, *Save group*. Pinned tabs sit leftmost, icon-only, outside every
group. In Chrome's vertical tabs the same groups render as collapsible sections
of a list — the strip and the list are one model in two geometries, which is
the property this RFC wants.

Why Chrome needs names and colours: its groups are invented by the user out of
arbitrary pages, so identity has to be painted on. Why Fyolo does not: its
groups are folders. A project's name is its identity and a section's name is
its kind. Painting colours on top would be a knob with nothing to decide.

Why Chrome's ⌘1–9 reaches tabs and Fyolo's reaches workspaces: Chrome's
top-level object is the tab; Fyolo's is the workspace, decided in the keyboard
design and already drawn beside each workspace in the switcher. A Chrome
window is a Fyolo workspace — one strip, one workspace, switch to see another.

How the two geometries are switched: Chrome's vertical tabs (2025) and Edge's
before them are one toggle reachable from two places — the strip's context
menu (*Show tabs vertically*) and Settings › Appearance — and the toggle is
the whole of the setting; there is no mode underneath that could disagree with
what the window shows. Chrome's vertical strip collapses to icons and back with
its own button, which is the navigator toggle's job here.

What Chrome does not do: fold the groups you are not in. Collapse is a click
per group, and the active tab can never sit inside a collapsed group — collapse
the active group and Chrome moves activation to the next tab outside it. The
most-installed patch on the feature, *Auto Collapse for Tab Groups*, adds the
missing rule in one sentence: collapse every group with no focused tab.

### Vivaldi accordion tab stacks

Vivaldi ships that rule natively (4.1, 2021) as one of its three stack styles:
"the stack will expand automatically when viewing a tab in the stack and
collapse when viewing other tabs." A collapsed stack is about the width of one
tab; an open stack's tabs share the bar with everything else. Two knobs ride
along — double-click pins a stack open, and a setting turns auto-expand off —
and this RFC takes the rule without them.

Firefox (142+) has the opposite invariant: a collapsed group *may* hold the
active tab, drawn as the chip plus that one tab, and hovering a collapsed chip
lists its tabs so one can be picked without opening the group. The list is
worth taking; the invariant is not, because the accordion makes it moot.

## The mapping

| Chrome | Fyolo | Note |
| --- | --- | --- |
| Window | Workspace | The strip shows `currentWorkspace`; ⌘1–9 switch |
| Tab group | Terminals section, Chats section, project, worktree | Chip + run; the run draws only for the selection's group |
| Tab | A split group, or a lone session | The user's rule: every group is one tab, every loose session is one tab |
| Active tab | The tab containing `selectedSessionID` | `splitRoot` is already "the group containing the selection" |
| Collapsed group | Every group but the selection's | Derived from `selectedSessionID`, never toggled — see *One group open* |
| `+` at the strip's end | The sidebar's `+` pull-down | Global by rule (see *plus-menu-is-global*) |
| *New tab in group* | The project header's quick-add / section header's *New Terminal* / *New Chat* | The chip's context menu is the header's menu, verbatim |
| Pinned tabs | *(none)* | See *Pinned* below |
| Tab search | Open Quickly ⌘⇧O | Exists |
| Vertical tabs | The sidebar | Exists |

A **tab** is precisely what the terminal area can show at once: `visiblePaneIDs`
is the tab's leaves. A lone session is a tab of one leaf. A split group is a tab
whose leaves are `splitRoot.leafIDs`. Clicking a pane inside a tab changes the
focused leaf, not the tab. This keeps the SplitTree invariant its own header
states — there is no "tabs inside a pane" layer; a leaf is a session — because
a tab is a whole layout, never a slot within one.

```
 sidebar (vertical)                     strip (horizontal), same order
 ──────────────────                     ────────────────────────────────────────────
 ▾ fyolo                           ─▶  │ fyolo·main │                 open: holds the selection
   ┌ ● Claude Code   split group    ─▶                │ ● Claude Code ⧉2 │
   └ ○ zsh           (bracketed run)                     one tab, two leaves
   ○ zsh             lone session   ─▶                                     │ ○ zsh │
 ▾ fix-auth                         ─▶  │ fix-auth ● │                  folded: chip + status dot
   ● Codex                                (listed in the chip's menu)
 ▾ Terminals                        ─▶  │ Terminals │                   folded
   ○ zsh                                  (listed in the chip's menu)
```

A bracketed run in the sidebar folds into one tab; a group header becomes a
chip; the order is untouched. Only the selection's group draws its tabs — the
others are chips, which is the accordion in *One group open*.

A tab's **title** is the focused leaf's `displayTitle` (the sidebar row's label:
given title, then live title, then prompt title, then the placeholder), so a tab
reads exactly as the row it replaces. A multi-leaf tab appends a small pane
count. A tab's **status** is the most urgent of its leaves' statuses —
`needsAttention` > `working` > `done` > `idle` — the same fold the menu-bar
pulse already does across all sessions, applied to one layout.

A tab lives in the **group of its first leaf** in sidebar order. Split groups are
inserted beside their origin (`splitSelectedPane` places the new row next to the
focused one so the sidebar can draw its ┌/└ bracket), so a tab's leaves are
adjacent rows and the strip's order is the sidebar's order with bracketed runs
folded into one tab.

## One model, three consumers

The sidebar's `body` opens with forty lines that derive the rows: the ordered
projects partitioned into pinned and unpinned, the pinned worktrees and sessions
minus what a pinned ancestor already shows, the other-workspace `needs-you`
rows, whether rows wear a device mark, which sections exist. The Session menu
derives a second, slightly different flattening in `sidebarSessionGroups`. A
strip would be a third.

The engineering step underneath this RFC is to lift that derivation into one
value the store computes:

```swift
struct SwitcherRows {
    struct Group: Identifiable {
        enum Kind { case terminals, chats, project(Project.ID), worktree(Project.ID, Worktree.ID), alsoRunning }
        let id: String            // stable across rebuilds: kind + owning id
        let kind: Kind
        let label: String         // "Terminals", the project's name, the branch
        let tabs: [Tab]
    }
    struct Tab: Identifiable {
        let id: Session.ID        // the first leaf, in sidebar order
        let leaves: [Session.ID]  // one for a lone session; splitRoot.leafIDs for a group
    }
    let groups: [Group]
}
```

`SidebarView` renders it as the tree it renders today (a project group followed
by its worktree groups is the three-level nest; a multi-leaf tab is the
bracketed run). `TabStripView` renders it as chips and runs. The Session menu
renders it as headers and rows. Three geometries, one order — the thing Chrome's
vertical and horizontal tabs get right and the thing two independent
derivations would drift on within a month.

```
                  FyoloStore
      ┌──────────────────────────────────┐
      │ projects · worktrees · sessions  │
      │ splitGroups · deviceSessions     │
      │ selectedSessionID                │
      └────────────────┬─────────────────┘
                       │ derive once
                       ▼
                 SwitcherRows
              groups: [Group{tabs}]
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
    SidebarView   TabStripView   Session menu
    tree + ┌/└    chips + runs   headers + rows
    (open)        (collapsed)    (always)
```

The strip carries no fold state of its own: which group is open is derived
from the selection (see *One group open*). The sidebar keeps the disclosure
`@State` it has today — a list can show everything, so its folds stay manual
and stay unpersisted — and the `StateFile` stays what it is: tree, selection,
inspector layout.

## Presentation

### Where it sits

In the toolbar band, between the navigator toggle and the branch picker, as one
`NSToolbarItem` hosting a SwiftUI view — the shape the branch picker already
takes (`.branchPicker`, an `NSHostingView` with a width constraint that follows
the terminal pane). The band is otherwise empty once the sidebar is gone, and a
second row below the toolbar would spend a line of terminal text to draw tabs
under blank chrome. Superlogical and Safari both put the strip in the title
bar for the same reason.

Two things make the band *one row of tab titles* rather than tabs squeezed
beside the chrome that is there today:

- **The branch picker retires while the strip is up.** It is display only —
  the project's name over its branch, no menu — and both facts move to the
  group chip: the project's name is the chip, and the primary checkout's chip
  carries the branch after it (`fyolo · main`), the way a worktree chip already
  *is* its branch. With the sidebar open the picker stays, since nothing else in
  the band says which project the terminal is in.
- **The band goes compact.** Its height comes from `toolbarStyle`, not from its
  contents: macOS 26 gets `.automatic` (the tall bar) and earlier systems
  `.unifiedCompact`. A one-line strip in a two-line band reads as empty, so the
  strip lands with a switch to `.unifiedCompact` on 26 as well — a paired
  decision, made once, that also applies while the sidebar is open. This is
  the vertical saving; the horizontal one is the 240–260pt the sidebar gives
  back, and that is the larger of the two.

```
 sidebar open
 ┌───────────────────────────────────────────────────────────────────────────────────────┐
 │ ☰ Work         ⇅   +    ┃ fyolo                                               ⊞ ▤    │
 └───────────────────────────────────────────────────────────────────────────────────────┘
   toggleNavigator  flex  sort  new │ sidebarTrackingSeparator │ branchPicker  flex  toggleInspector

 sidebar collapsed
 ┌───────────────────────────────────────────────────────────────────────────────────────┐
 │ ☰ Work ▾ │ fyolo·main │ ● Claude Code ⧉2 │ ○ zsh │ fix-auth ● │ Terminals │ +   ⊞ ▤  │
 └───────────────────────────────────────────────────────────────────────────────────────┘
   toggleNavigator │ ───────────── tabStrip: grows to fill, shrinks first ───────────── │ toggleInspector
   + workspace switcher
```

The strip takes the branch picker's slot and the sort/`+` pair's freed room;
the workspace switcher stays on the toggle because it is the strip's workspace
dropdown.

The existing `sidebarCollapseObserver` is the switch. It already inserts and
removes the sidebar's toolbar actions on every collapse path (toggle, View
menu, divider drag) through `setNavigatorItemsVisible`; the strip item is
inserted where those are removed and removed where they are restored. The
workspace switcher must stay in the band while collapsed — it is the strip's
workspace dropdown, and today it rides with the sidebar's region.

### Workspaces in the strip

The strip shows one workspace, the way a Chrome window shows one window's tabs,
and the workspace switcher is the strip's leading control — Superlogical's
sidebar glyph that also opens the workspace menu. It rides the navigator
toggle item today (`NavigatorToggleToolbarView`) and hides itself when the
sidebar collapses; the strip needs it shown, with the workspace's name beside
the glyph so the strip's first word says whose tabs these are. Everything
that switches workspaces keeps working unchanged: the dropdown, ⌘1–9, the
Workspace menu. Agents blocked on the user in another workspace put a dot on
the switcher (see *Pinned*).

```
 ┌──────────────────────────────────────────────────────────────┐
 │ ☰ Work ▾ │ fyolo·main │ ● Claude Code ⧉2 │ ○ zsh │ +   ⊞ ▤  │
 └──┬───────────────────────────────────────────────────────────┘
    │  ✓ Work                ⌘1
    │    Personal ●          ⌘2       ← needs-you elsewhere
    │  ──────────────────────
    │    New Workspace…
    │    Show Tabs Vertically
    └──────────────────────────
```

### The setting

Settings › Appearance gains one row:

> **Tabs** — Vertical | Horizontal
> *Show sessions in a sidebar beside the terminal, or in a strip above it.*

It is not an `AppSettings` field. The picker reads `store.sidebarVisible` and
writes by collapsing or expanding the sidebar through the same path the
toggle uses, so the KVO observer that swaps the toolbar items runs for it
too, and the split view's autosave remains the only copy of the state. The
strip's context menu offers *Show Tabs Vertically*, and the sidebar's header
menu the reverse, as Chrome's strip does — the same verb from where the user
is looking.

### Beside the inspector

The inspector keeps its band region exactly as it is: the Files / Search /
Changes / Info switch and the ▤ toggle stay pinned over the inspector column by
`inspectorTrackingSeparator`. The strip is the terminal column's width, between
the two tracking separators, and never runs under the inspector's controls —
the rule the branch picker already follows (`branchPickerWidthLimit` tracks
the terminal pane), inherited with the slot.

```
 sidebar collapsed, inspector open
 ┌─────────────────────────────────────────────────────────────────────┬──────────────────────────────┐
 │ ☰ Work ▾ │ fyolo·main │ ● Claude Code ⧉2 │ ○ zsh │ fix-auth ● │ +  ┃ Files Search Changes Info  ▤ │
 ├─────────────────────────────────────────────────────────────────────┼──────────────────────────────┤
 │ terminal                                                            │ inspector                    │
 └─────────────────────────────────────────────────────────────────────┴──────────────────────────────┘
   strip = the terminal column                     inspector region untouched
```

Chrome's side panel is the comparison people reach for, and it is shaped
differently on purpose: the panel carries its own header (title, pop-out, ×)
so that Chrome's tab strip and toolbar can each span the full window as their
own rows. Fyolo has one band, and the accordion keeps the strip short, so a
self-headed inspector would buy band space nobody needs and cost the inspector
a row and the window its symmetry — the sidebar's controls would still be in
the band. What Chrome's panel does get right, Fyolo already does: the panel
follows the tab. Gemini's panel is per-tab; the inspector shows the selected
session's project, and the accordion draws from the same `selectedSessionID`,
so switching tabs moves the open group and the inspector together.

### One group open

The strip is an accordion. The open group is the one holding
`selectedSessionID`; every other group is drawn as its chip alone. Select a
session in another project and that project unfolds while the one you left
folds, with no click spent on folding. This is Vivaldi's accordion tab stack
rule — "expand automatically when viewing a tab in the stack and collapse when
viewing other tabs" — and what *Auto Collapse for Tab Groups* bolts onto
Chrome. Terminals, Chats and worktrees are groups like any other, so the rule
has no special cases.

```
 selected: Claude Code in fyolo
 ┌─────────────────────────────────────────────────────────────────┐
 │ fyolo·main │ ● Claude Code ⧉2 │ ○ zsh │ fix-auth ● │ Terminals │
 └─────────────────────────────────────────────────────────────────┘
   open: fyolo                     folded: fix-auth (needs-you dot), Terminals

 selected: Codex in fix-auth
 ┌─────────────────────────────────────────────────────────┐
 │ fyolo·main ◐ │ fyolo ⎇ fix-auth │ ● Codex │ Terminals │
 └─────────────────────────────────────────────────────────┘
   folded: fyolo (working dot)   open: fix-auth     folded: Terminals
```

Three things follow:

- **Fold state is not state.** `openGroup == group(of: selectedSessionID)` is
  the whole of it. Nothing is stored, nothing goes stale, and Chrome's
  invariant — the active tab is never inside a collapsed group — holds by
  construction rather than by moving the activation around.
- **The chip's status dot is load-bearing.** With every other project folded,
  the aggregate dot is the only place a `needs-you` in another project can
  show. It carries the same fold the menu-bar pulse does, per group.
- **A folded chip is a menu, not a toggle.** Clicking it lists the group's
  tabs (Firefox's panel on a collapsed group); choosing one selects that
  session, and selecting is what opens the group. Nothing opens a group
  without selecting into it, so the strip never shows two open groups.

### Anatomy

A tab is the sidebar row turned sideways: agent icon, `StatusRing`, title, and
the same hover `×` that `SessionRowActionButton` draws. The active tab uses
`SidebarRowHighlight` — the row's selection vocabulary, not a new one, and not
an accent-blue fill. Hairline separators between inactive tabs, dropped beside
the active one, so the active tab's edges are the only edges in the strip.

A group is a chip carrying its label in the secondary colour, followed by its
run when open. The chip's underline is a hairline in the same colour, not a
hue: the name carries identity. A worktree group's chip carries the branch name
with the project's name as a quieter prefix, the way the sidebar row's
breadcrumb does. A folded chip has no run and gains the group's aggregate
status dot, so an agent that goes `needs-you` inside a folded project still
shows.

```
 open chip            tab (lone)          tab (split, active)         folded chip
 ┌─────────────┐  ┃  ┌──────────────┐  ┃  ┌─────────────────────────┐  ┃  ┌────────────┐
 │ fyolo·main │  ┃  │ ◐ ○ zsh    × │  ┃  │ ◐ ● Claude Code  ⧉2   × │  ┃  │ fix-auth ● │
 └─────────────┘  ┃  └──────────────┘  ┃  └─────────────────────────┘  ┃  └────────────┘
  label, secondary   icon ring title ×    SidebarRowHighlight fill;      no run; status dot;
  hairline under     hover-only ×         hairlines drop beside it       click = its tab menu
```

Overflow: tabs shrink to a floor (icon, ring, ~80pt of title) and then the
strip scrolls horizontally, keeping the active tab in view. The accordion
already holds the strip to one group's tabs plus a chip per other group; past
that, Open Quickly. No overflow menu.

### Verbs

- **Click a tab** → `selectedSessionID` becomes the tab's last-focused leaf. The
  terminal area follows through `splitRoot` as it does for a sidebar click.
- **×** → *Close Session* on a lone session. On a multi-leaf tab, × ends every
  leaf, each under the ⌘W rule from the keyboard design: a plain shell with a
  command in front of it confirms, an agent does not. Middle-click is ×.
- **Click a folded chip** → a menu of that group's tabs, each with its status;
  choosing one selects it, which opens the group. Clicking the open group's
  chip does nothing — there is no fold to toggle.
- **Chip context menu** → the section header's or project header's menu,
  unchanged: *New Terminal* / *New Chat* / the agent quick-adds, *Close All…*,
  the project's own items. Chrome's *New tab in group* is what these already are.
- **Strip `+`** → `makeNewSessionMenu`, the sidebar's global pull-down. It lands
  in a fixed place regardless of the active tab, per the rule; ⌘T remains the
  verb that follows focus.
- **Drag** → the sidebar's `SessionRowDrop` outcomes, sideways: release in the
  gap between tabs to reorder or move between groups (`moveSessionRow`), release
  on a tab to *Group with* it (`dropSession`, an edge zone). Release on a chip to
  move into that group's roster. A multi-leaf tab drags as a unit, the way
  Chrome drags a group. Drops into the terminal area (`sessionDropTarget`) work
  as they do from the sidebar.
- **Keyboard** → nothing new. ⌘⇧[ / ⌘⇧] cycle sessions in the same flattened
  order and the active tab follows; inside a multi-leaf tab they move the focus
  across the panes, which is what they do today. ⌘1–9 are workspaces. ⌥⌘ arrows
  focus panes. ⌘⇧O searches.

### Pinned

The sidebar's **Pinned** working set is a set of shortcut rows: a pinned session
is drawn there *and* in its tree position. That is fine in a list and wrong in a
strip, where every tab must be one thing — two tabs for one session cannot both
be active. The strip therefore omits the Pinned section. Pinning still orders:
`orderedProjects` already puts pinned projects first, so their groups lead.

The other thing Pinned carries is agents blocked on the user in *other*
workspaces. In the strip that becomes a dot on the workspace switcher — the
Chrome answer, where one window shows one window and the taskbar tells you
another wants you — and the sidebar keeps lifting the rows as it does.

A session the device reports that no row accounts for needs no group of its
own: the roster sweep (#528, RFC 20260830) auto-adopts it as an ordinary row,
so a session someone started from the `fyolod` CLI shows in the strip exactly
as any other session does. This supersedes the *Also running* group an earlier
revision of this RFC placed last in the strip.

## What changes in code

1. `FyoloStore`: `switcherRows` (the derivation lifted out of `SidebarView.body`
   and `sidebarSessionGroups`). The Session menu and `selectAdjacentSession`
   read `switcherRows`; behaviour is unchanged. No fold state is added.
2. `Sources/fyolo/Sidebar/SidebarView.swift`: renders `switcherRows`; its fold
   `@State` stays. A pure refactor with a screenshot before and after.
3. `Sources/fyolo/Sidebar/TabStripView.swift` (new — it is the sidebar's other
   geometry, so it lives beside it): chips, runs, tabs, the `+`, drag and drop
   through the existing delegates. The accordion is a render-time filter: the
   group containing `selectedSessionID` draws its tabs, every other group draws
   its chip.
4. `Sources/fyolo/App/App.swift`: a `.tabStrip` toolbar identifier, inserted and
   removed by `setNavigatorItemsVisible`, swapping the branch picker out and in
   with it; the workspace switcher survives the collapse; `.unifiedCompact` on
   macOS 26 in `installToolbar`.
5. `Sources/fyolo/Settings/AppearanceSettingsTab.swift`: the **Tabs** picker,
   bound to `store.sidebarVisible` through the collapse path; *Show Tabs
   Vertically* / *Horizontally* as context-menu items on the strip and the
   sidebar header.
6. No `StateFile` change, no `AppSettings` change, no `KeyCommandID`;
   localized strings for the picker, its subtext, the two menu items and the
   pane-count badge.

In three increments, each shippable: the model extraction alone (nothing
visible changes; the Session menu is the proof); the strip read-only (click,
status, the accordion, `+`, chip menus); then × and drag.

## Rejected

- **A tab-layout mode of its own.** Superlogical stores the choice as a mode
  beside the sidebar toggle, which leaves a state where the setting and the
  window disagree. Fyolo's picker is the navigator toggle's second handle on
  the one autosaved state. Collapsed means strip. Open means sidebar.
- **Strip and sidebar together.** Built and dropped 2026-07-06. Two switchers.
- **A second row under the toolbar.** Xcode's shape. It costs a line of terminal
  text, and the band above is empty. Kept only as the fallback if NSToolbar
  refuses a stretching custom item (see *To verify*).
- **Manual fold in the strip.** Chrome's per-chip collapse, Vivaldi's
  double-click pin-open, and its auto-expand switch are all fold state the
  selection does not derive — a second thing to keep in sync, and a knob. The
  selection is the fold.
- **A self-headed inspector, Chrome side-panel style.** Chrome needs the header
  because its strip is its own full-width row. One band, short strip: the
  inspector's controls stay in the band (see *Beside the inspector*). Its
  left/right alignment setting is a knob for the same reason.
- **Per-group colours.** Chrome needs them because its groups are arbitrary.
  Fyolo's groups are folders with names.
- **Tabs inside a pane.** Rejected by `SplitTree` at birth: a leaf is a session.
  A tab here is the whole layout, which is the opposite layer.
- **Native `NSWindow` tabbing.** Every tab would be a window, which fights the
  single-window split view — the reason Ghostty and Mux0 hand-draw theirs.
- **⌘1–9 → tab *n*, ⌃Tab → next tab.** ⌘digits are workspaces by decision;
  ⌘⇧[ / ⌘⇧] already cycle. The strip adds no key.
- **Showing every workspace in the strip.** One row cannot carry a second
  dimension. Chrome does not show other windows' tabs; the switcher is the
  dimension.

## To verify before building

- **NSToolbar stretch.** The branch picker proves a custom-view item with a
  width constraint works in the band; the strip needs one that *grows* to the
  space between the toggle and the inspector controls and shrinks first when
  the window narrows. Confirm the `»` overflow behaviour at the window's minimum width
  before committing to the band; otherwise fall back to the row.
- **A split group never spans rosters — holds today, keep it.** `canGroup`
  refuses a drop unless both sessions share a roster *and* a worktree path, and
  `splitSelectedPane` inserts the new leaf into the origin's own roster with its
  worktree inherited. The tab model leans on this; a future spawn path that
  places a leaf elsewhere would put one tab in two groups.
- **Full screen.** The strip lives in the title bar, and macOS 26 full-screen
  chrome has bitten before; the band's autohide must not take the strip with
  it while the sidebar is collapsed.
- **Launch order.** The sidebar's autosaved collapse state arrives after the
  toolbar is installed (`syncInspectorSwitch` exists for the inspector's copy
  of this problem); the strip must be present on a launch that restores
  collapsed, not only on a live toggle, and the Settings picker must read the
  restored state rather than the store's default `true`.
