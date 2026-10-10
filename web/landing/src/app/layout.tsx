import type { Metadata, Viewport } from "next";
import { Analytics } from "@vercel/analytics/next";
import "./globals.css";
import { DocsThemeScript } from "@/components/docs/theme-script";

const siteDescription =
  "Fyolo is the Terminal-first Agentic Development Environment — a native Mac app for your AI coding agents: Claude Code, Codex, OpenCode, Pi Agent and more. Run them side by side, each in a real terminal, switch between them instantly, and nothing ever leaves your machine.";

export const metadata: Metadata = {
  metadataBase: new URL("https://www.fyolo.sh"),
  title: {
    default: "Fyolo — one ADE connected to every tool",
    template: "%s — Fyolo",
  },
  description: siteDescription,
  keywords: [
    "Fyolo",
    "AI coding agents",
    "terminal",
    "macOS terminal",
    "Claude Code",
    "Codex",
    "git worktree",
    "Apple Silicon",
    "Intel Mac",
  ],
  applicationName: "Fyolo",
  alternates: {
    canonical: "/",
  },
  openGraph: {
    title: "Fyolo — one ADE connected to every tool",
    description: siteDescription,
    type: "website",
    siteName: "Fyolo",
    url: "/",
    images: [
      {
        url: "/og.webp",
        type: "image/webp",
        width: 2400,
        height: 1260,
        alt: "Fyolo — one ADE connected to every tool. Claude, Codex, files, Vitest, GitHub, Linear and Docker wired into one Fyolo terminal.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Fyolo — one ADE connected to every tool",
    description: siteDescription,
    images: ["/og.webp"],
  },
};

export const viewport: Viewport = {
  themeColor: "#08080a",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    // suppressHydrationWarning covers exactly one thing: the docs' theme script
    // (components/docs/theme-script.tsx) writes `data-docs-theme` onto <html>
    // before React hydrates, so the server markup and the live DOM legitimately
    // differ by that attribute. It suppresses only this element's own attributes,
    // not anything nested, so real mismatches below still report.
    <html
      lang="en"
      className="dark h-full antialiased"
      // globals.css sets scroll-behavior: smooth; Next wants it declared so it can
      // suppress the animation during route transitions.
      data-scroll-behavior="smooth"
      suppressHydrationWarning
    >
      {/* An explicit <head> so the theme script has a defined position: React
          refuses to place a synchronous <script> loose in the document, and this
          one has to run before the body is parsed. Metadata still flows in here
          from the Metadata API. */}
      <head>
        <DocsThemeScript />
      </head>
      <body className="min-h-full flex flex-col bg-background text-foreground">
        {children}
        <Analytics />
      </body>
    </html>
  );
}
