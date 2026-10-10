"use client";

import { HeroGradient } from "@/components/hero-gradient";
import { FyoloMark } from "@/components/logo";
import { StackHub } from "@/components/sections/stack-hub";
import { brewInstallCommand } from "@/lib/site";

// Temporary render target for the static OG card (public/og.webp): screenshot
// /og-card at 2400×1260 with headless Chrome, then delete this route. It reuses
// the hero's real WebGL aurora, grain and stack hub so the card matches the
// live site. Not linked from anywhere.
//
// The hub's loop is frozen at one moment — Linear's port flaring and its line
// lit while the Codex line fades behind it — by pausing every hub animation and
// rewinding it a fixed time into the cycle, so each capture is identical.
const FROZEN_AT = "4.45s";

export default function OgCardPage() {
  return (
    <main
      className="relative overflow-hidden bg-background text-foreground"
      style={{ width: 2400, height: 1260 }}
    >
      <style>{`
        nextjs-portal { display: none; }
        .og-hub .hub-chip::after,
        .og-hub .hub-row::before,
        .og-hub .hub-comet,
        .og-hub .hub-port::after {
          animation-delay: calc(var(--hub-delay) - ${FROZEN_AT}) !important;
          animation-play-state: paused !important;
        }
        .og-hub .demo-cursor { animation: none; }
      `}</style>
      <HeroGradient className="absolute inset-0" />
      <div
        aria-hidden="true"
        className="grain-overlay pointer-events-none absolute -inset-[6%]"
      />
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 bottom-0 h-[420px] bg-gradient-to-b from-transparent to-background"
      />

      <div
        className="absolute flex items-center"
        style={{ left: 120, top: 96, gap: 24 }}
      >
        <FyoloMark className="h-[76px] w-[76px]" />
        <span style={{ fontSize: 56, fontWeight: 600, letterSpacing: "-0.01em" }}>
          fyolo
        </span>
      </div>

      <div
        className="absolute font-mono"
        style={{
          right: 120,
          top: 104,
          padding: "16px 28px",
          borderRadius: 20,
          fontSize: 30,
          color: "#ececf2",
          background: "rgba(0, 0, 0, 0.45)",
          border: "2px solid rgba(255, 255, 255, 0.12)",
        }}
      >
        <span style={{ color: "rgba(255,255,255,0.45)" }}>$ </span>
        {brewInstallCommand}
      </div>

      <div
        className="absolute inset-x-0 text-center"
        style={{ top: 250 }}
      >
        <h1
          style={{
            fontSize: 120,
            fontWeight: 600,
            lineHeight: 1.05,
            letterSpacing: "-0.025em",
          }}
        >
          One ADE connected to{" "}
          {/* The hero's rotating word, caught on the tool the frozen hub has
              lit, in the rotator's violet and glow. */}
          <span
            style={{
              color: "#c084fc",
              textShadow: "0 0 56px rgba(168, 85, 247, 0.5)",
            }}
          >
            Linear
          </span>
        </h1>
        <p
          style={{
            marginTop: 36,
            fontSize: 42,
            fontWeight: 500,
            color: "#c9c3d6",
            letterSpacing: "-0.005em",
          }}
        >
          GitHub, Linear, Docker, your tests, your files, Claude and Codex — in
          one terminal.
        </p>
      </div>

      <div
        className="og-hub absolute"
        style={{
          left: "50%",
          top: 580,
          width: 1060,
          transform: "translateX(-50%) scale(1.95)",
          transformOrigin: "top center",
        }}
      >
        <StackHub />
      </div>
    </main>
  );
}
