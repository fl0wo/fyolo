# fyolo web

The marketing site for **fyolo** — a native macOS (Apple Silicon) terminal for
AI coding agents. fyolo is **free to use**: no account, no license keys, no
payment backend. This folder is just the public site; the desktop app itself
lives in the repository root (`Sources/fyolo`).

## Sub-projects

- **[`landing/`](./landing)** — the marketing site. Next.js + TypeScript +
  Tailwind + shadcn/ui, with a visual design modeled on superwhisper.com. Tells
  the product story and links straight to the Mac download.

## Distribution

The app installs with Homebrew (`brew install --cask fl0wo/tap/fyolo`) or as a
`.dmg` from GitHub Releases, and checks those releases for updates
(`docs/RELEASING.md`). There is no checkout, no licensing service, and no server
to run.

> Source will be opened later — not yet.

## Docs

- **[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)** — what the `web/` project
  is and how the landing site is built and deployed.

## Quickstart

The site sets up from its own README: work in [`landing/`](./landing)
(`npm install && npm run dev`).
