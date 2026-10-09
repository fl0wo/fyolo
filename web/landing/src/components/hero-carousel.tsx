"use client";

import Image from "next/image";
import { useCallback, useEffect, useRef, useState } from "react";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

export type HeroSlide = {
  src: string;
  alt: string;
  width: number;
  height: number;
};

const AUTOPLAY_MS = 5000;
const SWIPE_THRESHOLD_PX = 40;

// Cross-fade hero carousel (otty.sh-style): slides are stacked absolutely and
// fade between each other instead of sliding, so the window "changes content"
// in place. Autoplays, pauses on hover/focus, respects reduced motion, and
// supports touch swipe on mobile (where the side arrows are hidden).
export function HeroCarousel({ slides }: { slides: readonly HeroSlide[] }) {
  const [active, setActive] = useState(0);
  const [paused, setPaused] = useState(false);
  // Slides are stacked absolutely inside the viewport, so `loading="lazy"`
  // alone doesn't defer anything — the browser fetches all of them on first
  // paint. Instead, only mount slides the user has seen plus the upcoming one
  // (mounted a full autoplay interval early, so it's loaded before it fades in).
  const [visited, setVisited] = useState<ReadonlySet<number>>(
    () => new Set([0]),
  );
  const reducedMotion = useRef(false);
  const touchStart = useRef<{ x: number; y: number } | null>(null);
  const { ref: viewRef, inView } = useInView<HTMLDivElement>();

  useEffect(() => {
    setVisited((prev) =>
      prev.has(active) ? prev : new Set(prev).add(active),
    );
  }, [active]);

  const goTo = useCallback(
    (index: number) => setActive((index + slides.length) % slides.length),
    [slides.length],
  );

  useEffect(() => {
    reducedMotion.current = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
  }, []);

  useEffect(() => {
    if (paused || !inView || slides.length < 2 || reducedMotion.current) return;
    const timer = setInterval(
      () => setActive((i) => (i + 1) % slides.length),
      AUTOPLAY_MS,
    );
    return () => clearInterval(timer);
  }, [paused, inView, slides.length]);

  if (slides.length === 0) return null;
  const { width, height } = slides[0];
  const upNext = (active + 1) % slides.length;

  return (
    <div
      ref={viewRef}
      role="region"
      aria-roledescription="carousel"
      aria-label="Fyolo screenshots"
      className="group @container relative w-full"
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocus={() => setPaused(true)}
      onBlur={() => setPaused(false)}
      onKeyDown={(e) => {
        if (e.key === "ArrowLeft") goTo(active - 1);
        if (e.key === "ArrowRight") goTo(active + 1);
      }}
      onTouchStart={(e) => {
        setPaused(true);
        touchStart.current = {
          x: e.touches[0].clientX,
          y: e.touches[0].clientY,
        };
      }}
      onTouchEnd={(e) => {
        setPaused(false);
        if (!touchStart.current) return;
        const dx = e.changedTouches[0].clientX - touchStart.current.x;
        const dy = e.changedTouches[0].clientY - touchStart.current.y;
        touchStart.current = null;
        // Only a mostly-horizontal drag counts, so vertical page scrolling
        // over the carousel doesn't change slides.
        if (Math.abs(dx) > SWIPE_THRESHOLD_PX && Math.abs(dx) > Math.abs(dy)) {
          goTo(active + (dx < 0 ? 1 : -1));
        }
      }}
    >
      {/* The screenshot frame. Corner radius scales with the rendered image
          width (cqw of the @container wrapper) so it matches at every size. */}
      <div
        className="relative w-full overflow-hidden rounded-[clamp(6px,1cqw,12px)] shadow-soft"
        style={{ aspectRatio: `${width} / ${height}` }}
      >
        {slides.map((slide, i) =>
          visited.has(i) || i === upNext ? (
            <Image
              key={slide.src}
              src={slide.src}
              width={slide.width}
              height={slide.height}
              alt={slide.alt}
              priority={i === 0}
              // The captures are 3024px wide but render in a max-w-5xl (64rem)
              // column; without `sizes` the browser downloads the 3840px rendition.
              sizes="(max-width: 68rem) 100vw, 64rem"
              draggable={false}
              aria-hidden={i !== active}
              className={cn(
                "absolute inset-0 h-full w-full object-cover transition-[opacity,transform] duration-700 ease-out",
                i === active
                  ? "opacity-100 scale-100"
                  : "pointer-events-none opacity-0 scale-[1.012]",
              )}
            />
          ) : null,
        )}

        {slides.length > 1 && (
          <div
            aria-label="Choose screenshot"
            className="absolute bottom-3 left-1/2 z-10 inline-flex -translate-x-1/2 items-center gap-1.5 rounded-full bg-black/40 px-2 py-1.5 backdrop-blur-md"
          >
            {slides.map((slide, i) => (
              <button
                key={slide.src}
                type="button"
                aria-label={`Show screenshot ${i + 1}`}
                aria-current={i === active}
                onClick={() => goTo(i)}
                className={cn(
                  "h-1.5 rounded-full transition-all duration-200",
                  i === active
                    ? "w-4 bg-white"
                    : "w-1.5 bg-white/50 hover:bg-white/80",
                )}
              />
            ))}
          </div>
        )}
      </div>

      {/* Arrows flank the image instead of overlapping it; they only show on
          screens wide enough to have room beside it (mobile swipes instead). */}
      {slides.length > 1 && (
        <>
          <CarouselArrow
            dir="prev"
            placement="outside"
            onClick={() => goTo(active - 1)}
          />
          <CarouselArrow
            dir="next"
            placement="outside"
            onClick={() => goTo(active + 1)}
          />
        </>
      )}
    </div>
  );
}

export function CarouselArrow({
  dir,
  onClick,
  placement = "overlay",
}: {
  dir: "prev" | "next";
  onClick: () => void;
  placement?: "overlay" | "outside";
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={dir === "prev" ? "Previous screenshot" : "Next screenshot"}
      className={cn(
        "absolute top-1/2 z-10 grid size-12 -translate-y-1/2 place-items-center rounded-full sm:size-14",
        "bg-white/90 text-neutral-900 shadow-[0_1px_rgba(10,10,10,0.06),0_6px_18px_-6px_rgba(10,10,10,0.22)] backdrop-blur-md",
        "opacity-0 transition-[opacity,background-color] duration-200",
        "hover:bg-white active:scale-95",
        "group-hover:opacity-100 group-focus-within:opacity-100",
        placement === "overlay"
          ? dir === "prev"
            ? "left-4"
            : "right-4"
          : cn(
              "hidden xl:grid",
              dir === "prev" ? "right-full mr-5" : "left-full ml-5",
            ),
      )}
    >
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={2}
        strokeLinecap="round"
        strokeLinejoin="round"
        className="size-5 sm:size-6"
      >
        <path d={dir === "prev" ? "M15 6l-6 6 6 6" : "M9 6l6 6-6 6"} />
      </svg>
    </button>
  );
}
