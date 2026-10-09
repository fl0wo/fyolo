---
title: "Competitive analysis: Conductor"
status: done
type: research
created: 2026-06-27
updated: 2026-08-24
---

# Conductor

> The representative of the **opposite philosophy** to Fyolo: Mac-native,
> worktree parallelism, but **diff-heavy / in-app review**.

## One-line positioning

Native Mac app that runs multiple Claude Code agents in parallel in git
worktrees and **reviews diffs and merges inside the app**.

## Vendor / open source / links

- Closed-source commercial product. Site: https://www.conductor.build

## Tech stack & form factor

- Native macOS (details undisclosed). Runs Claude Code agents locally.

## Core capabilities

- One isolated workspace per agent; **copies only git-tracked files** (avoids
  duplicating `node_modules`/`.env`), each workspace runs its own setup.
- A closed loop of **review diff → merge** inside the app; sessions grouped by
  project.

## Strengths

- The "run in parallel + inspect results + merge" loop is complete — very
  smooth for users who want to review agent output.
- Clean worktree file-copy strategy (tracked files only).

## Weaknesses

- Opposite philosophy to Fyolo — **heavy diff/review panels**, large surface
  area.
- Closed-source, details opaque.

## vs. Fyolo / takeaways

- This is the watershed on "**should we build diff?**". Fyolo should stick to
  **no code panels** (betting on "the agent lives in the code + humans review
  with git/IDE") and use clear copy to redirect users who want in-app review,
  rather than bolting on a panel mid-course and breaking the positioning.
- **Worth borrowing**: the worktree strategy of "copy only tracked files +
  `.worktreeinclude`" to avoid duplicating giant directories.

## Business model & funding

> Researched 2026-08-24. Disambiguation: this is **conductor.build**, not the
> same-named SEO platform at conductor.com (Conductor Inc., ~$130M revenue) —
> web searches conflate the two constantly.

- **Vendor**: Melty Labs (YC), founded 2024 by Charlie Holtz and Jackson de
  Campos, ~8 people in SF. Pivoted here from Melty, an open-source AI code
  editor.
- **Funding**: **$22M Series A** from Spark and Matrix. Ilya Sukhar (Matrix) led
  both the seed and the A and took a board seat; Nabeel Hyatt at Spark; YC; the
  founders of Notion and Linear as angels. Third-party trackers list **$60–63M
  across 4 rounds**, which does not reconcile with the announced $22M — treat
  the total as unverified.
- **Revenue**: **never disclosed.** No ARR figure exists publicly, which is true
  of every product in this category.
- **Pricing**:

  | Tier | Price | Unlocks |
  | --- | --- | --- |
  | Free | $0 | Multiple agents, local workspaces |
  | Pro | **$50/mo flat** (per person, not per seat) | Cloud workspaces, **multiplayer up to 5 users**, API, mobile app |
  | Teams | **$60/seat/mo** | Live team collaboration, admin portal, central billing |
  | Enterprise | Custom | DPA, PO billing, SAML SSO, SCIM, dedicated support |

- **Where the paywall sits**: cloud workspaces **and** the 6th person. Conductor
  charges individuals and sells compute — both of which Fyolo has excluded.

### vs. Fyolo's pricing

Fyolo's decided shape is Free (one person, everything, forever) → Team
$20/seat, with the second person as the only wall and no Enterprise tier.

- Conductor charges a solo developer **$50/mo**; Fyolo charges them nothing.
- **For a 5-person team Fyolo is more expensive**: Conductor bundles up to 5
  collaborators into the $50 flat Pro plan, so 5 people cost $50/mo there versus
  5 × $20 = $100/mo on Fyolo. Worth knowing before the price is public.
- Part of Conductor's $50 is real machine cost (cloud workspaces). Fyolo's $20
  is pure software value, since non-negotiable #3 rules out selling compute.

### The fundraising read

Conductor raised **$22M with no disclosed revenue**, at ~8 people, less than two
years old, with Matrix and Spark leading. In this category the Series A is
priced on form factor, growth curve and endorsement — not ARR. The same is true
of cmux and herdr. Revenue only becomes the gating question at Series B.

## References

- https://www.conductor.build
- Pricing: https://www.conductor.build/pricing
- YC profile: https://www.ycombinator.com/companies/conductor
- Series A announcement: https://x.com/charlieholtz/status/2039027121901957349
