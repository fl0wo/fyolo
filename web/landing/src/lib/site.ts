// Shared site constants. Fyolo is free to use and ships with Sparkle
// auto-updates — no account, no license keys, no payment backend.

// The agents Fyolo ships a manifest for, in the order the app itself lists
// them (`Sources/fyolo/Resources/agents/*.json`, the `order` field). The hero
// marquee and the FAQ answer read this list; the agent showcase draws a panel
// for the subset of it we have a capture of, and its names are checked against
// this type so the two can't drift apart again. The app bundles a few more
// manifests than this — an agent joins the list once it has a brand mark and
// someone has run it.
export const supportedAgents = [
  "Claude Code",
  "Codex",
  "OpenCode",
  "Pi",
  "Amp",
  "Cursor",
  "Copilot",
  "Kimi",
  "Antigravity",
  "Crush",
  "Grok",
] as const;

export type SupportedAgent = (typeof supportedAgents)[number];

export const navLinks = [
  { label: "Docs", href: "/docs" },
  { label: "Changelog", href: "/changelog" },
] as const;

// Community Discord invite, surfaced in the site nav.
export const discordUrl = "https://discord.gg/H9DKVwsE5f";

// The public source repository, surfaced in the site nav and footer.
export const githubUrl = "https://github.com/fl0wo/fyolo";

// GitHub's repo API endpoint for the star count shown in the hero.
export const githubApiUrl = githubUrl.replace(
  "https://github.com/",
  "https://api.github.com/repos/",
);

export function formatStarCount(stars: number): string {
  return stars >= 1000
    ? `${(stars / 1000).toFixed(1).replace(/\.0$/, "")}k`
    : String(stars);
}

// The desktop build download — the stable Cloudflare R2 URL (behind
// downloads.fyolo.sh) that always serves the newest notarized DMG. The release
// workflow (.github/workflows/release.yml) overwrites this object on every tag.
export const downloadUrl = "https://downloads.fyolo.sh/fyolo.dmg";

export const testflightUrl = "https://testflight.apple.com/join/1Arf1UKR";

// Real app captures for the hero carousel (public/screenshots/hero*.png, all
// 3024×1898 @2x). The hero cross-fades through these; the first one is the LCP
// image, so lead with the strongest shot.
export const heroSlides = [
  {
    src: "/screenshots/hero1.png",
    alt: "Fyolo in dark mode: a live Claude Code session next to the project sidebar.",
  },
  {
    src: "/screenshots/hero2.png",
    alt: "Fyolo in light mode: a Codex session running beside the session sidebar.",
  },
  {
    src: "/screenshots/hero3.png",
    alt: "Fyolo's built-in file editor showing a Markdown file next to the project file tree.",
  },
  {
    src: "/screenshots/hero4.png",
    alt: "The inspector panel with working-directory and agent actions beside a Claude Code session.",
  },
  {
    src: "/screenshots/hero5.png",
    alt: "Split panes in Fyolo: a Claude Code session alongside a dev server and a shell terminal.",
  },
].map((slide) => ({ ...slide, width: 3024, height: 1898 }));
