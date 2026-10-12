# Fyolo Web — Architecture

This describes the `web/` project: the marketing site. Fyolo is **free to use**
— there is no checkout, no licensing service, and no backend. The desktop app
lives in the repository root (`Sources/fyolo`) and is out of scope here.

## One sub-project

### `web/landing` — marketing site

The public website. A developer evaluates Fyolo and clicks through to download
the Mac app.

- **Stack:** Next.js + TypeScript, styled with Tailwind CSS and
  [shadcn/ui](https://ui.shadcn.com/) components.
- **Design:** modeled on [superwhisper.com](https://superwhisper.com/) — clean,
  dark, product-forward. (We borrow superwhisper's *visual* language only.)
- **Responsibility:** present the product, and link out to the Mac download.

## Distribution

Fyolo ships as a notarized `.dmg` and updates itself in place:

- **Download** — the landing "Download for Mac" buttons point at the newest
  GitHub Release (`src/lib/site.ts`); the release workflow
  (`.github/workflows/release.yml`) publishes the `.dmg` there on every tag and
  bumps the Homebrew cask.
- **Updates** — the installed app reads the `latest.json` published with each
  release to learn of a newer version, and updates through Homebrew or the next
  `.dmg` (`docs/RELEASING.md`). No checking the website.

There is no account, no license key, and no server in the loop.

## Request flow

```
 ┌──────────┐   visit / read   ┌──────────────────┐
 │ Browser  │ ───────────────▶ │  web/landing     │
 │ (dev)    │                  │  Next.js + shadcn │
 └──────────┘                  └─────────┬─────────┘
      │                                  │ "Download for Mac"
      │                                  ▼
      │                        ┌───────────────────┐
      │        download .dmg ──│  GitHub Releases  │
      │                        │  + Homebrew tap   │
      │                        └─────────┬─────────┘
      ▼                                  │ latest.json (update check)
 ┌──────────────────────┐ ◀──────────────┘
 │  fyolo desktop app  │
 │  (macOS, local-only) │
 └──────────────────────┘
```

## Tech stack — role of each piece

| Piece | Where | Role |
|-------|-------|------|
| Next.js + TypeScript | landing | Marketing site, SSR/SSG pages |
| Tailwind + shadcn/ui | landing | Styling and component primitives |
| GitHub Releases | external | Hosts the `.dmg` + `latest.json`; the Homebrew tap points at it |

## Local dev quickstart

- **Landing:** see [`web/landing/README.md`](../landing/README.md) — typically
  `npm install` then `npm run dev` (Next.js dev server).

There is no server to run.

## Deployment

| Component | Target | Notes |
|-----------|--------|-------|
| `web/landing` | **Vercel** | Native Next.js host; preview deploys per PR. |
| App download | **GitHub Releases** | The `.dmg` + `latest.json`, published by the release workflow on tag. |

### Configuration (high level)

- **Landing:** the download URL in `src/lib/site.ts`.
- **Release:** the `.dmg` and `latest.json` are published on a GitHub Release by
  `.github/workflows/release.yml` on each version tag.
