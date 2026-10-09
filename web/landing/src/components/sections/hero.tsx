import { Reveal } from "@/components/reveal";
import { HeroGradient } from "@/components/hero-gradient";
import { BrewInstall } from "@/components/brew-install";
import { StackHub } from "@/components/sections/stack-hub";

export function Hero() {
  return (
    <section
      id="top"
      className="hero-cinematic relative isolate flex min-h-screen flex-col overflow-hidden text-foreground"
    >
      {/* Slow navy→indigo→violet aurora (WebGL MeshGradient) behind the hero. */}
      <HeroGradient className="absolute inset-0 -z-10" />
      {/* Frosted film grain over the aurora so it reads matte, not glossy. */}
      <div
        aria-hidden="true"
        className="grain-overlay pointer-events-none absolute -inset-[6%] -z-10"
      />
      {/* Fade the hero into the page below. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-72 bg-gradient-to-b from-transparent to-background"
      />
      <div className="relative mx-auto flex w-full max-w-6xl flex-1 flex-col items-center justify-center px-5 pb-20 pt-36 text-center sm:px-8 sm:pt-40">
        <Reveal>
          {/* Category line: quiet title-case medium text, not an
              uppercase letterspaced label. */}
          <p className="text-base font-medium text-muted-foreground sm:text-xl">
            Terminal-first Agentic Development Environment
          </p>
        </Reveal>
        <Reveal delayMs={40}>
          <h1 className="mt-5 text-balance text-5xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-6xl">
            One ADE. Every tool connected.
          </h1>
        </Reveal>
        <Reveal delayMs={80}>
          <p className="mx-auto mt-6 max-w-xl text-balance text-base leading-relaxed text-muted-foreground sm:text-lg">
            GitHub, Linear, Docker, your tests, your files, Claude and Codex — in
            one terminal, on machines you own.
          </p>
        </Reveal>
        <Reveal delayMs={120} className="mt-10 flex w-full flex-col items-center gap-3">
          <BrewInstall />
          {/* Below 14 the app will not launch, and macOS reports only a generic
              Finder error — so the floor is stated where the install happens. */}
          <p className="text-sm text-muted-foreground">
            Requires macOS 14 or later
          </p>
        </Reveal>
        <Reveal delayMs={200} className="mt-16 w-full">
          <StackHub />
        </Reveal>
      </div>
    </section>
  );
}
