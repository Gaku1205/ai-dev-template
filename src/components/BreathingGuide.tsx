"use client";

import { useEffect, useState, type CSSProperties } from "react";
import { breathingState, TOTAL_SECONDS, type BreathingPhase } from "@/lib/breathing";

type Status = "idle" | "running" | "done";

const PHASE_LABEL: Record<BreathingPhase, string> = {
  inhale: "吸って",
  hold: "止めて",
  exhale: "吐いて",
};

const MIN_DIAMETER = 72;
const MAX_DIAMETER = 240;
const MIN_OPACITY = 0.35;
const MAX_OPACITY = 0.9;

export function BreathingGuide() {
  const [status, setStatus] = useState<Status>("idle");
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    if (status !== "running") return;
    const startedAt = performance.now();
    let frame = 0;
    const tick = (now: number) => {
      const seconds = (now - startedAt) / 1000;
      if (seconds >= TOTAL_SECONDS) {
        setElapsed(TOTAL_SECONDS);
        setStatus("done");
        return;
      }
      setElapsed(seconds);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [status]);

  const state = breathingState(status === "idle" ? 0 : elapsed);
  const scale = status === "running" ? state.scale : 0;
  const diameter = MIN_DIAMETER + (MAX_DIAMETER - MIN_DIAMETER) * scale;
  const lightStyle = {
    "--light-scale": diameter / MAX_DIAMETER,
    "--light-opacity": MIN_OPACITY + (MAX_OPACITY - MIN_OPACITY) * scale,
  } as CSSProperties;

  const start = () => {
    setElapsed(0);
    setStatus("running");
  };

  return (
    <section className="breathing" aria-label="1分の深呼吸">
      <div className="breathing-stage">
        <div className="breathing-light" style={lightStyle} aria-hidden="true" />
      </div>

      <div className="breathing-text">
        {status === "running" && (
          <>
            <p className="breathing-phase" aria-live="polite">
              {PHASE_LABEL[state.phase]}
            </p>
            <p className="breathing-sub">あと{Math.ceil(state.phaseRemaining)}秒</p>
            <p className="breathing-sub">全体であと{Math.ceil(state.totalRemaining)}秒</p>
          </>
        )}
        {status === "done" && <p className="breathing-done">おつかれさまでした</p>}
      </div>

      {status === "running" ? null : (
        <button type="button" className="breathing-button" onClick={start}>
          {status === "done" ? "もう一度" : "はじめる"}
        </button>
      )}
    </section>
  );
}
