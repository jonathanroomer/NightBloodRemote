import { useEffect, useRef } from "react";

import { readyFlashEnvelope, type FaceCanvasProps } from "./FaceCanvas";
import { MarshmallowDirector } from "./marshmallowDirector";
import { MarshmallowRenderer } from "./webglMarshmallow";

/**
 * The complete live Marshmallow surface. It consumes exactly the same three
 * truthful inputs as NightBlood: resolved state, authorised output amplitude
 * and the abstract gaze observation.
 */
export function MarshmallowCanvas({
  resolved,
  authorisedAmplitude,
  liveAmplitude,
  readyFlashStartedAtMs = null,
  liveWatched,
  reducedMotion = false,
  className,
}: FaceCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const inputs = useRef({
    state: resolved.state,
    amplitude: authorisedAmplitude,
    liveAmplitude,
    readyFlashStartedAtMs,
    liveWatched,
    reducedMotion,
  });

  inputs.current = {
    state: resolved.state,
    amplitude: authorisedAmplitude,
    liveAmplitude,
    readyFlashStartedAtMs,
    liveWatched,
    reducedMotion,
  };

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const director = new MarshmallowDirector();
    let renderer: MarshmallowRenderer;
    try {
      renderer = new MarshmallowRenderer(canvas);
    } catch (error) {
      console.error("[marshmallow] WebGL unavailable:", error);
      return;
    }

    let animationFrame = 0;
    const startedAt = performance.now();
    const frame = () => {
      const now = (performance.now() - startedAt) / 1_000;
      const current = inputs.current;
      const level = current.liveAmplitude ? current.liveAmplitude() : current.amplitude;
      director.setReducedMotion(current.reducedMotion);
      director.setState(current.state, now);
      director.setWatched(current.liveWatched ? current.liveWatched() : null);
      const uniforms = director.frame(now, level);
      const ready = current.readyFlashStartedAtMs == null
        ? 0
        : readyFlashEnvelope(performance.now() - current.readyFlashStartedAtMs);
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      const width = Math.max(1, Math.round(canvas.clientWidth * dpr));
      const height = Math.max(1, Math.round(canvas.clientHeight * dpr));
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
      }
      renderer.render(uniforms, width, height, 0, 0, ready);
      animationFrame = requestAnimationFrame(frame);
    };
    animationFrame = requestAnimationFrame(frame);
    return () => {
      cancelAnimationFrame(animationFrame);
      renderer.dispose();
    };
  }, []);

  return (
    <canvas
      ref={canvasRef}
      className={className}
      style={{ width: "100%", height: "100%", display: "block", background: "#000" }}
      aria-label={`Marshmallow face: ${resolved.state}`}
      role="img"
    />
  );
}
