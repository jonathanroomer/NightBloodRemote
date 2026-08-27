/**
 * FaceCanvas: the NightBlood face as a live WebGL canvas.
 *
 * Consumes ONLY (face spec Phase 4): resolved canonical state, the
 * authorised amplitude (AuthorisedAmplitudeTracker.amplitude — zero without
 * an authorised speech job), and the reduced-motion flag. It renders
 * truthfully when any input is absent: missing state resolves to offline
 * upstream, absent amplitude means no mouth activity.
 */

import { useEffect, useRef } from "react";

import { FaceDirector } from "./faceDirector";
import type { Watched } from "./faceDirector";
import type { ResolvedFace } from "./types";
import { FaceRenderer } from "./webglFace";

export interface FaceCanvasProps {
  readonly resolved: ResolvedFace;
  /** Must come from AuthorisedAmplitudeTracker.amplitude — never raw audio. */
  readonly authorisedAmplitude: number;
  /**
   * Optional per-frame amplitude source, read inside the render loop rather
   * than passed as a prop. The speaker level updates ~80 times a second and
   * the speech effects follow it directly; routing that through React state
   * would mean 80 renders a second to move one number.
   */
  readonly liveAmplitude?: () => number;
  /** Monotonic `performance.now()` timestamp for one confirmed Voice opening. */
  readonly readyFlashStartedAtMs?: number | null;
  /**
   * What the camera can see, read per frame like the amplitude rather than
   * passed as a prop — it changes 20 times a second and none of those changes
   * need React to hear about them.
   */
  readonly liveWatched?: () => Watched | null;
  readonly reducedMotion?: boolean;
  readonly className?: string;
}

const READY_ATTACK_MS = 80;
const READY_HOLD_MS = 350;
const READY_FADE_MS = 2_200;

/** Fast green arrival, a readable beat, then a soft return to ivory. */
export function readyFlashEnvelope(elapsedMs: number): number {
  if (elapsedMs < 0) return 0;
  if (elapsedMs < READY_ATTACK_MS) {
    const t = elapsedMs / READY_ATTACK_MS;
    return t * t * (3 - 2 * t);
  }
  if (elapsedMs < READY_ATTACK_MS + READY_HOLD_MS) return 1;
  const fade = (elapsedMs - READY_ATTACK_MS - READY_HOLD_MS) / READY_FADE_MS;
  if (fade >= 1) return 0;
  const t = Math.max(0, fade);
  const eased = t * t * (3 - 2 * t);
  return 1 - eased;
}

export function FaceCanvas({
  resolved,
  authorisedAmplitude,
  liveAmplitude,
  readyFlashStartedAtMs = null,
  liveWatched,
  reducedMotion = false,
  className,
}: FaceCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const directorRef = useRef<FaceDirector | null>(null);
  const rendererRef = useRef<FaceRenderer | null>(null);
  const inputs = useRef({
    state: resolved.state, amplitude: authorisedAmplitude, reducedMotion, liveAmplitude,
    readyFlashStartedAtMs, liveWatched,
  });

  inputs.current = {
    state: resolved.state, amplitude: authorisedAmplitude, reducedMotion, liveAmplitude,
    readyFlashStartedAtMs, liveWatched,
  };

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const director = new FaceDirector();
    directorRef.current = director;
    let renderer: FaceRenderer;
    try {
      renderer = new FaceRenderer(canvas);
    } catch (err) {
      // Graceful degradation (spec 6.3): leave the canvas black; the status
      // caption elsewhere in the UI remains the truthful surface.
      console.error("[face] WebGL unavailable:", err);
      return;
    }
    rendererRef.current = renderer;

    let raf = 0;
    const t0 = performance.now();
    const frame = () => {
      const now = (performance.now() - t0) / 1000;
      const {
        state, amplitude, reducedMotion: rm, liveAmplitude: live,
        readyFlashStartedAtMs: flashStartedAt, liveWatched: watchedNow,
      } = inputs.current;
      const level = live ? live() : amplitude;
      director.setReducedMotion(rm);
      director.setState(state, now);
      if (watchedNow) director.setWatched(watchedNow(), now);
      renderer.pushAmplitude(level);
      const uniforms = director.frame(now, level);
      const ready = flashStartedAt == null
        ? 0
        : readyFlashEnvelope(performance.now() - flashStartedAt);
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      const w = Math.round(canvas.clientWidth * dpr);
      const h = Math.round(canvas.clientHeight * dpr);
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
      }
      // The renderer applies this only inside each almond. It deliberately
      // bypasses the state-tint path, which colours the surrounding halo too.
      renderer.render(uniforms, w, h, 0, 0, ready);
      raf = requestAnimationFrame(frame);
    };
    raf = requestAnimationFrame(frame);
    return () => {
      cancelAnimationFrame(raf);
      renderer.dispose();
      rendererRef.current = null;
      directorRef.current = null;
    };
  }, []);

  return (
    <canvas
      ref={canvasRef}
      className={className}
      style={{ width: "100%", height: "100%", display: "block", background: "#000" }}
      aria-label={`NightBlood face: ${resolved.state}`}
      role="img"
    />
  );
}
