"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useInView } from "@/lib/use-in-view";

const INTERVAL_MS = 2400;

// The hero headline's rotating tail: each word flips in letter by letter, the
// way a split-flap board turns, while the previous one flips out above it.
// The current word stays in flow so the line keeps its baseline (and its width
// on the server render); after mount the box's width is measured per word and
// eased between them, so the centered headline glides instead of jumping. The
// letters move on transform and opacity only (globals.css, .rotator-*).
export function RotatingWord({ words }: { words: readonly string[] }) {
  const [{ index, previous }, setTurn] = useState<{
    index: number;
    previous: number | null;
  }>({ index: 0, previous: null });
  const [widths, setWidths] = useState<number[] | null>(null);
  const measureRefs = useRef<(HTMLSpanElement | null)[]>([]);
  const { ref, inView } = useInView<HTMLSpanElement>();

  const measure = useCallback(() => {
    const measured = measureRefs.current.map((node) => node?.offsetWidth ?? 0);
    if (measured.every((width) => width > 0)) setWidths(measured);
  }, []);

  useLayoutEffect(() => {
    measure();
    // Web fonts swap in after first paint and change every width.
    document.fonts?.ready.then(measure).catch(() => {});
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, [measure]);

  useEffect(() => {
    if (!inView) return;
    const timer = window.setInterval(() => {
      setTurn(({ index: current }) => ({
        index: (current + 1) % words.length,
        previous: current,
      }));
    }, INTERVAL_MS);
    return () => window.clearInterval(timer);
  }, [inView, words.length]);

  return (
    <span
      ref={ref}
      aria-hidden="true"
      className="rotator relative inline-block whitespace-nowrap text-left align-bottom"
      style={widths ? { width: widths[index] } : undefined}
    >
      <Word key={`in-${index}`} text={words[index]} phase="in" />
      {previous !== null && previous !== index ? (
        <Word
          key={`out-${previous}`}
          text={words[previous]}
          phase="out"
          className="absolute left-0 top-0"
        />
      ) : null}
      <span className="pointer-events-none invisible absolute left-0 top-0">
        {words.map((word, wordIndex) => (
          <span
            key={word}
            ref={(node) => {
              measureRefs.current[wordIndex] = node;
            }}
            className="absolute left-0 top-0 whitespace-nowrap"
          >
            {word}
          </span>
        ))}
      </span>
    </span>
  );
}

function Word({
  text,
  phase,
  className,
}: {
  text: string;
  phase: "in" | "out";
  className?: string;
}) {
  return (
    <span className={`rotator-word rotator-${phase} inline-block ${className ?? ""}`}>
      {Array.from(text).map((letter, letterIndex) => (
        <span
          key={letterIndex}
          className="rotator-letter"
          style={{ "--i": letterIndex } as React.CSSProperties}
        >
          {letter === " " ? " " : letter}
        </span>
      ))}
    </span>
  );
}
