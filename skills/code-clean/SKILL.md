---
name: code-clean
description: "Cut dead code and over-long comments from fyolo's Swift, verifying every deletion against a build. Knows this repo's real failure mode (essay-length doc comments, not restated-code slop) and periphery's four known false-positive shapes. Invoke when the user says 'clean dead code', 'clean up the comments', 'the comments are too long', 'remove unused code', 'tighten this file', '清理死代码', '注释太啰嗦', '精简一下注释'."
---

# Code Clean

Two passes over fyolo's Swift: **dead code** (symbols nothing reaches) and
**over-long comments** (prose that outgrew what it explains). Both end in a
build. Neither is a refactor.

This is not a generic AI-slop sweep. Run one on this repo and it finds nothing:
a 2026-08 survey of all 69k tracked Swift lines turned up **1 TODO** (a false
match on an `mktemp` template), **0 commented-out code blocks**, and **1
deliberate debug print**. Don't spend the pass hunting those. The bloat here is
shaped differently, and §2 is where it lives.

## Scope

Default to the current branch's diff against `origin/main`. A whole-tree pass is
a standing request only — say so, and expect it to take real time.

Never touch:

- `Sources/fyolo/Editor/Highlightr/` — vendored; upstream API surface is kept
  intact on purpose (AGENTS.md).
- Anything under `skills/` recorded in `skills-lock.json` — re-pull from
  upstream instead of hand-editing.
- `ios/build/`, `ios/build-sim/` — Xcode artifacts, not tracked source. They
  hold ~100k lines of SPM checkouts that will swamp any tree-wide grep. Scope
  greps with `git ls-files`, never bare `find ios`.

## 1. Dead code

`periphery scan --targets fyolo` (SPM; no config file needed). It is installed
at `/opt/homebrew/bin/periphery`.

**Roughly three of every four hits are false.** Four shapes account for nearly
all of them — clear each before deleting anything:

1. **Retain-holders.** `private var toolbarDelegate / menuBar / hookListener /
   linkClickMonitor / scanTask / stream / source / window`. Flagged
   `assignOnlyProperty`, but holding the reference *is* the job — drop the
   property and the object deallocates and the feature dies. `App.swift` says so
   in comments ("must be retained").
2. **`Equatable` / `Hashable` key-struct fields.** Read only through the
   synthesized `==` / `hash(into:)`, which periphery cannot see. `BranchModel`'s
   `GitState` spells out why its field exists: so a same-HEAD refresh is
   recognized as a no-op.
3. **`@objc` selector-target `sender:` parameters.** The AppKit selector
   signature requires them.
4. **Vendored code.** See Scope.

Two more that are unused *and* must stay:

- Documented extension points — the `IssueProvider` protocol is unused as a
  type but is the seam for Linear (`docs/design/issue-tracker-integration.md`).
- Persisted fields — `Session.createdAt` is unread but lives in the state file.
  Deleting it is a schema change, not a cleanup.

Real finds cluster in **fetch-and-cache paths whose views were never wired** and
**utilities orphaned when their UI was removed**. Before deleting, grep the
symbol across `Sources`, `Shared`, `ios/Sources`, `Tests`, and `scripts/`. If
only a test references it, the test is holding a corpse upright — delete both.

## 2. Over-long comments

The repo's actual bloat. Of 3,293 doc-comment blocks in `Sources` + `Shared`,
81% are 1–5 lines and healthy. The tail is not: **636 blocks run 6+ lines, 151
run 12+, and the longest is 44 lines** — a design doc wearing a function header.

Find them:

```sh
git ls-files 'Sources/*.swift' 'Shared/*.swift' 'ios/Sources/*.swift' | xargs awk '
  /^[[:space:]]*\/\/\//{if(n==0)start=FNR; n++; next}
  {if(n>=12){print n" "FILENAME":"start}; n=0}
  END{if(n>=12)print n" "FILENAME":"start}' | sort -rn
```

### The test that matters

AGENTS.md says comments explain *why*, not *what*. These comments already do —
that is exactly the trap. **Length is not the defect; misfiling is.** A 20-line
block is wrong not because it is long but because a field's doc comment is the
wrong home for a design argument.

Sort every long block into three piles:

- **Keep, verbatim.** A foot-gun, an invariant, or a past bug that will be
  reintroduced without it. `Workspace.isAutoCreated`'s note on why `Bool?` has
  three states, not two, is load-bearing: collapsing it to `false` is what made
  an earlier version wrong. Length is irrelevant here. Leave it.
- **Move to `docs/design/`, leave a one-line pointer.** Architecture,
  alternatives considered, upstream asks, competitor comparisons. The 44-line
  block on `makeStatusTap` is three paragraphs of model plus a caveat with an
  upstream ask — that is a design doc. Use the `doc` skill to create or extend
  it, then leave `/// … see docs/design/<file>.md`. **Move, never delete.**
- **Cut.** Restating the signature, narrating the body line by line, hedging
  ("this should probably"), and prose that repeats the paragraph above it.

### Tautological one-liners

~130 docs open `/// Whether the …` and many just respell the property name:

```swift
/// Whether the "Projects" section is folded shut.
var isProjectsCollapsed: Bool
```

Delete that. But `/// Whether the machine answered at all. false is what turns
every agent row …` earns its line — it says what the value *causes*. Read each
one; do not pattern-match the opener.

### Ceilings, once a block is in the "cut" pile

One line is the target. Three is the ceiling for a field or inline comment, five
for a type or function. A block that cannot fit belongs in `docs/design/`.

### Leave alone

- `// MARK:` — all 602 of them. They are navigation, not narration, and they are
  spread thin (12 in the heaviest file). AGENTS.md's ban on "organizational
  comments" is about prose headers that summarize what the next block does.
- Comments on code this branch did not touch, in a diff-scoped run.
- An outdated comment: **fix it, don't reword it to match wrong code.** If the
  code is what's wrong, report that separately — it is a bug, not a comment.

## 3. Verify

```sh
swift build          # required, every time
swift test           # if anything under a covered unit moved
```

Covered units: split-tree layout, OSC parsing, stall probing, Markdown/HTML
rendering, git service, editor text, install feedback.

A comment pass that changes no code still needs `swift build` — a deleted line
inside a multi-line string or a stray `///` before an attribute breaks the
parse.

## Report

Per file: what was cut, what moved to `docs/design/`, and what was flagged but
kept and why. Name the periphery hits you rejected and which of the four shapes
each was — that list is how the next run gets faster.

Do not report a line count as the result. "Cut 400 lines" says nothing about
whether the right 400 went.
