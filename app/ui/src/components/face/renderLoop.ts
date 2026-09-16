import type { VisualState } from "./types";

export interface RenderDemand {
  state: VisualState;
  level: number;
  ready: boolean;
}

/** Cached layout, explicit hidden suspension, 30 fps at rest and 60 in use. */
export function startFaceRenderLoop(
  canvas: HTMLCanvasElement,
  demand: () => RenderDemand,
  draw: (nowMs: number, width: number, height: number) => void,
): () => void {
  let width = 1, height = 1;
  let cssWidth = 1, cssHeight = 1;
  let frame = 0, lastDraw = -Infinity, activeUntil = 0;
  let intersecting = true, disposed = false;
  let lastState: VisualState | null = null;
  const settings = new URLSearchParams(location.search);
  // Comparison switches for a like-for-like hardware profile. Active display
  // quality remains full resolution until a physical-device test justifies it.
  const fullRate = settings.get("faceFps") === "60";
  const scaleValue = Number(settings.get("faceScale") ?? "1");
  const scale = Number.isFinite(scaleValue) ? Math.max(0.5, Math.min(1, scaleValue)) : 1;
  const visible = () => !document.hidden && intersecting
    && (window as Window & { nightbloodRenderVisible?: boolean }).nightbloodRenderVisible !== false;
  const size = () => {
    const dpr = Math.min(2, window.devicePixelRatio || 1) * scale;
    width = Math.max(1, Math.round(cssWidth * dpr));
    height = Math.max(1, Math.round(cssHeight * dpr));
    if (canvas.width !== width) canvas.width = width;
    if (canvas.height !== height) canvas.height = height;
  };
  const tick = (now: number) => {
    frame = 0;
    if (disposed || !visible()) return;
    const current = demand();
    if (current.state !== lastState || current.ready || current.level > 0.002) {
      activeUntil = now + 1_000;
      lastState = current.state;
    }
    const atRest = current.state === "idle" || current.state === "offline";
    const interval = !fullRate && atRest && now > activeUntil ? 1000 / 30 : 1000 / 60;
    if (now - lastDraw >= interval - 1) {
      // Never produce catch-up frames after a stall or a hidden interval.
      lastDraw = now;
      draw(now, width, height);
    }
    frame = requestAnimationFrame(tick);
  };
  const visibilityChanged = () => {
    if (!visible()) {
      cancelAnimationFrame(frame);
      frame = 0;
    } else if (!frame && !disposed) {
      lastDraw = -Infinity;
      frame = requestAnimationFrame(tick);
    }
  };
  const initial = canvas.getBoundingClientRect();
  cssWidth = initial.width; cssHeight = initial.height;
  size();
  const resize = new ResizeObserver(entries => {
    const box = entries[0]?.contentRect;
    if (box) { cssWidth = box.width; cssHeight = box.height; size(); }
  });
  resize.observe(canvas);
  const intersection = new IntersectionObserver(entries => {
    intersecting = entries[0]?.isIntersecting ?? true;
    visibilityChanged();
  });
  intersection.observe(canvas);
  document.addEventListener("visibilitychange", visibilityChanged);
  window.addEventListener("nightblood-render-visibility", visibilityChanged);
  window.addEventListener("resize", size);
  visibilityChanged();
  return () => {
    disposed = true;
    cancelAnimationFrame(frame);
    resize.disconnect();
    intersection.disconnect();
    document.removeEventListener("visibilitychange", visibilityChanged);
    window.removeEventListener("nightblood-render-visibility", visibilityChanged);
    window.removeEventListener("resize", size);
  };
}
