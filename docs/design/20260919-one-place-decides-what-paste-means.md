---
title: One place decides what paste means
status: active
type: rfc
created: 2026-09-19
updated: 2026-09-19
related:
  - 20260730-fyolod-session-protocol.md
  - 20260819-unify-server-plane.md
---

# One place decides what paste means

> ⌘V is answered in three code paths that do not know about each other; this
> collapses them onto ghostty's own boundary and says what it would take to
> stop translating clipboards into keystrokes at all.

## Where the decision lives today

One ⌘V is intercepted three times. The order is not obvious from any one file,
and it is the whole story:

| # | Where | What it decides |
| --- | --- | --- |
| 1 | app — `FyolodPasteInterceptor` (`Terminal/Fyolod/FyolodTransfer.swift`) | A local `NSEvent` monitor. Runs **before the view sees the key**, so it silently wins over 2 and 3. |
| 2 | wrapper — `AppTerminalView+Input.swift` | `pasteboardHoldsImageOnly` → `surface.submitCtrlV()`, handing the TUI a Ctrl+V so the agent reads the Mac clipboard itself. |
| 3 | wrapper — `TerminalController+Callbacks.swift` | `readClipboard` serves `isTextMime` only; `pasteboardText()` is a bare `NSPasteboard.general.string(forType:.string)`. |

Layer 2 is a real asset and should be understood as one: **upstream ghostty does
not have it.** In ghostty, ⌘V onto an image-only clipboard silently does nothing
(discussion #10478) because `getOpinionatedStringContents()` handles file URLs
and strings and nothing else. Only Ctrl+V works there. fyolo is ahead.

Layer 3 is the liability. Upstream's clipboard read maps a file URL to a
shell-escaped absolute path, per pasteboard item, joined by spaces:

```swift
// ghostty macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift
func getOpinionatedStringContents() -> String? {
    let strings = (pasteboardItems ?? []).compactMap { item in
        if let plist = item.propertyList(forType: .fileURL),
           let fileURL = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
           fileURL.isFileURL {
            return Ghostty.Shell.escape(fileURL.path)
        } else {
            return item.string(forType: .string)
        }
    }
    return strings.isEmpty ? nil : strings.joined(separator: " ")
}
```

Our fork never picked that up. That omission **is** issue #625: a real Finder ⌘C
writes the basename as the string flavor — captured from an actual copy —

```
public.file-url, NSFilenamesPboardType, Apple URL pasteboard type,
com.apple.finder.noderef, public.utf8-plain-text, com.apple.icns, public.tiff
string flavor = "example image.png"
```

so the naive read inserts `example image.png` and the location is gone. On a
multi-select Finder concatenates basenames with no separator —
`example image.pngit's fine.txt` — one unusable token.

PR #666 fixed #625 in layer 1 instead of layer 3. It works, and it also gave a
remote session a confident, fully-quoted, entirely **local** path. PR #670 closed
that by deciding the machine boundary first.

## What is already settled

PR #670 shipped the rule that the machine boundary is decided before anything
else, because it is the only question the terminal itself cannot answer:

| clipboard | local session | remote session |
| --- | --- | --- |
| screenshot (image, no text) | Ctrl+V to the TUI | upload, paste remote path |
| lone image file | absolute path | upload, paste remote path |
| `.txt` / directory / video | absolute path | absolute path |
| multi-file selection | absolute paths | absolute paths |
| plain text | ordinary paste | ordinary paste |

Only a lone image file crosses. Naming a file on the far side is a legitimate
thing to want — composing an `scp`, writing docs, pointing at a shared mount —
and only the user knows which they meant, so turning every file reference into
an upload is too strong. Past a 32 MB cap the paste is refused out loud, because
falling through would insert the local path the change exists to prevent and
silence would read as a dropped keystroke.

This RFC covers what is left.

## Proposal 1 — move the file-URL rule to layer 3 — **shipped**

Landed as libghostty-swift PR #9 (release `1.1.1`) and the pin bump that follows
it. `NSPasteboard.terminalPasteText()` reads the file reference per pasteboard
item; layer 1's file branch is gone. Two departures from upstream were taken
deliberately and are documented at the call site: POSIX single quotes rather
than ghostty's backslash-escaping, so pasting and dropping a path agree, and a
trailing space after a file reference but never after plain text. Layer 2's
guard now asks the same question the read asks, closing the first open question
below.

**A trap worth the next person's time.** The wrapper's release CI rebuilds
against ghostty *main*, so cutting a release moves the engine whether or not the
change needs it: `1.1.0` came out carrying ghostty `-2671-gb32f20f` against a
pin on `-2555-g7aab0a0`, 116 commits of drift. `fyolod/vt/Cargo.toml` requires
the Rust VT and the Swift clients to run **one** ghostty, and says a mismatched
`GHOSTTY_SOURCE_DIR` "does not fail to build — it corrupts the heap". The fix
was to re-cut with the workflow's `ghostty_ref` input pinned to the sha already
in use (`1.1.1 · ghostty v1.3.1-2555-g7aab0a0`). **Any wrapper-only release must
pass `ghostty_ref`**, or it silently becomes an engine bump that breaks host /
client VT parity. `1.1.0` is published and should not be adopted.

The original reasoning, kept for the record:


Port `getOpinionatedStringContents()` into the wrapper's `pasteboardText()`, then
drop PR #666's file branch from layer 1.

Why the wrapper and not the app:

- it is where ghostty puts it, so the fork stops diverging and the patch can be
  dropped when upstream moves;
- paste confirmation and paste protection still apply — layer 1 bypasses both;
- it fixes the OSC 52 read path too, not only the keystroke;
- it leaves layer 1 with exactly one job.

**Sequencing is not optional.** The wrapper is a separate repo
(`termio-sh/libghostty-swift`, shipped as a rebased patch file). Land the fork
change and bump `Package.swift` **first**, confirm the integrated build inserts
absolute paths, and only then revert the app branch. Reversed, #625 reappears for
the length of the gap.

**Do not delete PR #666's Edit ▸ Paste interception as part of this.** Before it,
Edit ▸ Paste reached `AppTerminalView.paste(_:)` and never
`FyolodPasteInterceptor`, so **remote image paste through the Edit menu was
broken** and #666 fixed it by accident. Removing it would reintroduce a bug that
predates the PR. Whether the hand-rolled `NSMenuItemValidation` shim it uses is
the right way to keep that coverage is a separate question, and needs a real run
to answer — it governs the Paste item's enablement in every text field in the app.

Two things this does **not** buy:

- **iOS parity.** The upstream helper is an `NSPasteboard` extension; iOS paste is
  `UIPasteboard.general.string`, both in the callback and in
  `UITerminalView+InputAccessory.swift`. A `UIPasteboard` equivalent has to be
  written separately, against `itemProviders` rather than `pasteboardItems`.
- **A collapsed layer 2.** Its predicate is "image data AND no string flavor", not
  "no file URL". A clipboard carrying a file URL and image bytes but no string
  still becomes Ctrl+V before layer 3 runs. If layer 3 becomes authoritative for
  file references, layer 2's guard should be tightened to match, or the two will
  disagree on exactly the clipboards that matter.

## Proposal 2 — stop translating clipboards into keystrokes

`submitCtrlV()` is a good hack with a ceiling. It works only for agents that
reach for a macOS clipboard API themselves, it cannot cross the machine boundary
(Ctrl+V on a VPS reads the VPS's clipboard), and a plain shell does nothing
useful with it.

The shipped `ghostty.h` already carries the mechanism that replaces it:

```c
typedef ghostty_clipboard_read_result_e (*ghostty_runtime_read_clipboard_cb)(
    void*, ghostty_clipboard_e, void*,
    const char* const* mimes, size_t mimes_len, bool list);

typedef struct { const char *mime; const char *data; size_t len; }
    ghostty_clipboard_content_s;   // binary-safe, explicit length
```

with `GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ` alongside the OSC 52 kinds. The core
already models "the clipboard holds `image/png`". Our `isTextMime` is what
refuses to serve it.

Lifting that would let a TUI pull the image **in band over the PTY**: no keystroke
translation, no temp file, and it works over SSH for free because it rides the
same pipe the session already has. That is also the shape upstream prefers —
mitchellh's answer on the SSH image-paste request (discussion #10517) was that it
should be cross-platform in the Zig core and that the OSC 52 extension probably
addresses it, with explicit unease about auto-upload as a default.

**This stays an RFC until a client participates.** A terminal advertising the
capability changes nothing on its own: the agent has to make the request. An agent
that today shells out to a Mac clipboard utility will not start issuing in-band
reads because we can answer them, and opencode #25806 suggests the ecosystem is
not there. Before retiring `submitCtrlV`, demonstrate an end-to-end read through
fyolod and an SSH hop, decide how paste confirmation applies to a binary read,
and keep a working path for clients that never adopt it.

Until then the upload crossing in PR #670 is the honest answer for remote
sessions, and it is strictly more capable than what ghostty ships.

## Open questions

- Should layer 2's guard become "no file URL either", so layers 2 and 3 agree?
- Is the hand-rolled paste-menu validation shim worth keeping, or is there a way
  to hold Edit ▸ Paste coverage without replacing a standard responder item?
- Does the 32 MB cap belong in the app, or is it really a property of the
  transfer plane that every caller should inherit?
- Multi-image selection aimed at a remote session currently pastes local paths.
  Is "upload all or none" worth the progress UI it would need?
