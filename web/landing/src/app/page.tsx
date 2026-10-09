import { SiteNav } from "@/components/site-nav";
import { Hero } from "@/components/sections/hero";
import { Orchestration } from "@/components/sections/orchestration";
import { FeatureGrid } from "@/components/sections/feature-grid";
import { GitHubBand } from "@/components/sections/github-band";
import { SiteFooter } from "@/components/site-footer";
import { HeroGradient } from "@/components/hero-gradient";
import { downloadUrl } from "@/lib/site";

// SoftwareApplication structured data — tells search engines this page is a
// free, native macOS developer app with a direct download.
const appJsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Fyolo",
  operatingSystem: "macOS",
  applicationCategory: "DeveloperApplication",
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  url: "https://www.fyolo.sh",
  downloadUrl,
  image: "https://www.fyolo.sh/og.webp",
  description:
    "Fyolo is the Terminal-first Agentic Development Environment — a native Mac app for your AI coding agents: Claude Code, Codex, OpenCode, Pi Agent and more. Run them side by side, each in a real terminal, and nothing ever leaves your machine.",
};

export default function Home() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(appJsonLd) }}
      />
      <SiteNav />
      <main className="flex-1">
        <Hero />
        <Orchestration />
        <FeatureGrid />
        <GitHubBand />
      </main>
      {/* Shaded outro — mirrors the hero. The footer floats over one slow
          aurora (same MeshGradient) as glass, echoing the way the nav floats
          over the hero shader up top. */}
      <div className="relative isolate overflow-hidden bg-background">
        {/* The aurora fades in from the page above through a mask rather than
            an overlay: the footer is short enough that an overlay's top edge
            and the WebGL canvas's snap to different pixel rows, leaving a seam. */}
        <HeroGradient className="absolute inset-0 -z-10 [mask-image:linear-gradient(to_bottom,transparent,black)]" />
        {/* Frosted film grain over the aurora, matching the hero. */}
        <div
          aria-hidden="true"
          className="grain-overlay pointer-events-none absolute -inset-[6%] -z-10"
        />
        <SiteFooter />
      </div>
    </>
  );
}
