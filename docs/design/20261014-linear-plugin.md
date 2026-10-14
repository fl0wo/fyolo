---
title: "Linear plugin: inspector pane, OAuth PKCE, pull requests linked by title"
status: active
type: design
created: 2026-10-14
updated: 2026-10-14
related:
  - 20260726-issue-tracker-integration.md
  - 20260812-agent-plugins.md
---

# Linear plugin

> A read-only Linear pane beside Issues and Docker: the project's team tickets, yours first, each showing the GitHub pull requests whose titles name it.

## Shape

- **A plugin, not a provider.** `LinearPlugin` sits in `PluginRegistry`, so Settings ▸ Plugins switches it on and off. It is on by default. Off means no toolbar segment, no pane, no network.
- **Read-only.** Agents write to Linear over MCP. fyolo asks only for the `read` scope and has no write controls; every ticket links out to Linear.
- **Its own pane.** `InspectorTab.linear`, with the detail pushed in inside the pane (the Docker pattern), not the center overlay Issues uses. A plugin that can vanish at any time stays out of the store's detail presentation.

## Connection

| Way in | How |
| --- | --- |
| Sign in with Linear | OAuth 2.0 authorization code with **PKCE** through `ASWebAuthenticationSession`, redirect `fyolo://oauth/linear`. PKCE makes `client_secret` optional, so the public client id ships in source like GitHub's (`FYOLO_LINEAR_CLIENT_ID` overrides it). The secret is never used. |
| API key | A pasted personal API key, for workspaces whose admins block OAuth apps. |

This corrects the 2026-07-26 doc's "Linear OAuth needs a client secret": Linear accepts PKCE without one.

Access tokens last 24 hours. The refresh token renews them before expiry and once after a 401. Both live in the Keychain under the issues service, account `linear`. Disconnecting revokes the OAuth token and deletes the item. `LinearAuth.connectionDidChange` tells every surface to reload.

## Binding and list

- One project, one team. The pick is written to the repo's local git config (`fyolo.linearTeam`), the same precedent as `fyolo.issuesRepo`, so worktrees share it. A workspace with a single team needs no pick.
- One GraphQL request (paged up to 300) reads the team's tickets whose state type is not `completed` or `canceled`.
- **Order:** tickets assigned to the viewer first, then everyone else's. Within each group: priority Urgent → High → Medium → Low → None, then state In Progress → Todo → Triage → Backlog, then most recently updated.

## Pull requests by title

The company rule is that a PR title names its ticket, so the title is the link. Shown only when GitHub is connected and the project has a GitHub remote.

1. **Pattern from real keys.** Built from the workspace's team keys: `(?<![A-Za-z0-9])(ENG|OPS)-0*(\d+)(?![0-9])`, case-insensitive. Look-alikes such as `UTF-8` never match, and `eng-12` and `[ENG-012]` both resolve to `ENG-12`.
2. **One request, one index.** A GitHub GraphQL request reads the bound repo's 100 most recently updated PRs. One pass over their titles builds `identifier → [PR]`, so each row's chips are a dictionary lookup.
3. **Older PRs on demand.** Opening a ticket the index has nothing for runs one search: `"ENG-123" in:title is:pr user:<owner>`. It covers the owner's other repos, and its results are checked again with the pattern, because GitHub's search is fuzzy.

**Status**, first match wins:

| Status | Rule | Color |
| --- | --- | --- |
| Merged | `state == MERGED` | purple |
| Closed | `state == CLOSED` | red |
| Draft | `isDraft` | gray |
| Failing | checks `FAILURE` / `ERROR` | red |
| Pending | checks `PENDING` / `EXPECTED` | yellow |
| In review | review `REVIEW_REQUIRED` / `CHANGES_REQUESTED` | orange |
| Ready to merge | `mergeStateStatus == CLEAN` | green |
| Open | anything else | blue |

## Detail

A native header (back, identifier, title, Open in Linear) above the shared issue web view. The page holds state, priority, assignee, labels, PR chips, related tickets, the description and comments. A related ticket's link pushes that ticket into the pane; every other link opens in the browser. Linear's private uploads (`uploads.linear.app`) load through the existing asset scheme handler, which attaches the Linear credential to that host only.

## Out of scope

- Any write to Linear.
- Linear's own GitHub attachments. Title matching is the rule.
- Checkouts on another machine. The pane names the machine instead, like Issues does, because the team pick lives in the local checkout's git config. A folder git doesn't track keeps its pick in memory until fyolo quits.
