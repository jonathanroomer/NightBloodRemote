/** Offline export of the iPhone's actual face for CPVoiceControlState.
 * 30 unique frames, 6 columns by 5 rows, 450px square (150pt at 3x).
 * Swift plays forward then backward without duplicated endpoints: a smooth
 * 58-frame / 24fps loop with no jump at the seam and 30 decoded frames.
 * The speaking loop indicates state; it is not live audio metering.
 */
import { FaceDirector } from "./components/face/faceDirector";
import type { VisualState } from "./components/face/types";
import { FaceRenderer } from "./components/face/webglFace";
import { readyFlashEnvelope } from "./components/face/FaceCanvas";

const STATES: Record<string, VisualState> = {
  ready: "idle",
  unavailable: "offline",
  listening: "listening",
  working: "thinking", // Same violet state as iosDirect.tsx, not Mac voice_working.
  speaking: "speaking",
  welcoming: "idle",
};
const name = new URLSearchParams(location.search).get("state") ?? "speaking";
const state = STATES[name];
if (!state) throw new Error(`Unknown CarPlay state: ${name}`);
const FRAMES = 30, COLUMNS = 6, TILE = 450, FPS = 24, SIMULATION_FPS = 120;
const canvas = document.querySelector<HTMLCanvasElement>("#atlas");
if (!canvas) throw new Error("missing atlas canvas");
canvas.width = TILE * COLUMNS;
canvas.height = TILE * (FRAMES / COLUMNS);
const renderer = new FaceRenderer(canvas, true);
const director = new FaceDirector(1103 + Object.keys(STATES).indexOf(name));
director.setState(state, 0);
const settle = 1.5;
let frameIndex = 0;
for (let tick = 0; frameIndex < FRAMES; tick++) {
  const now = tick / SIMULATION_FPS;
  const amplitude = state === "speaking"
    ? Math.max(0.10, Math.min(1, 0.52 + 0.34 * Math.sin(now * 11.7)
      + 0.16 * Math.sin(now * 21.3 + 0.8)))
    : 0;
  renderer.pushAmplitude(amplitude);
  const uniforms = director.frame(now, amplitude);
  const frameTime = name === "welcoming"
    ? frameIndex * 2.7 / (FRAMES - 1) : frameIndex / FPS;
  if (now + 0.5 / SIMULATION_FPS < settle + frameTime) continue;
  const x = (frameIndex % COLUMNS) * TILE;
  const y = (FRAMES / COLUMNS - 1 - Math.floor(frameIndex / COLUMNS)) * TILE;
  renderer.render(uniforms, TILE, TILE, x, y,
    name === "welcoming" ? readyFlashEnvelope(frameTime * 1_000) : 0);
  frameIndex++;
}
document.documentElement.dataset.exportReady = "true";
document.title = `NightBlood CarPlay ${name} artwork ready`;
