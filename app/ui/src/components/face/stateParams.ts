/**
 * Visual parameters for the canonical face states. The original fourteen are
 * the runtime mirror of blender/scripts/lib/nb_states.py; voice_working is a
 * live-only V2.5 state because it distinguishes NightBlood from observed work.
 */

import type { VisualState } from "./types";

/**
 * The state palette.
 *
 * Deliberately small, because a palette you cannot remember is not a signal.
 * Violet means observed Codex or Claude work; electric blue means NightBlood
 * is working directly for the user; amber means it needs attention; red means
 * something failed. Everything else is warm ivory — NightBlood being itself.
 *
 * Colour only carries meaning because the states you spend most time in are
 * untinted. Tinting more of them would turn the neon into decoration.
 *
 * Every colour here keeps one channel near zero. The eye's own light is a warm
 * ivory, so any of it surviving the mix desaturates the result to pastel —
 * saturation is the whole difference between neon and a dull wash.
 */
type Tint = readonly [number, number, number];
/**
 * The eye's own warm ivory. Untinted states target this rather than carrying a
 * dead placeholder colour: `eyeTint` interpolates across the 0.6s transition,
 * so a state holding an unused violet would crossfade THROUGH violet on its
 * way to cyan. Targeting ivory means the amount ramp does all the work and the
 * intermediate is simply a less saturated version of the destination.
 */
const IVORY: Tint = [0.98, 0.88, 0.67];
/** Observed Codex or Claude reasoning and execution. */
const NEON_VIOLET: Tint = [0.60, 0.015, 1.0];
/** NightBlood's foreground voice request is being reasoned about or executed. */
const ELECTRIC_BLUE: Tint = [0.015, 0.22, 1.0];
/** Something failed. */
const ALARM_RED: Tint = [1.0, 0.05, 0.09];
/** Waiting on a human. The universal "your move". */
const AMBER: Tint = [1.0, 0.46, 0.03];

export interface FaceStateParams {
  readonly aperture: number;
  readonly eyeGain: number;
  readonly gazeX: number;
  readonly gazeY: number;
  readonly blink: "natural" | "sparse" | "slow" | "suppressed" | "none";
  /**
   * Baseline lid tension, 0..1. Concentration narrows the lids independently
   * of aperture — it is what separates "deep in thought" from "half asleep",
   * which otherwise look identical on a face with no brows.
   */
  readonly squint: number;
  /**
   * Slow rhythmic swing in eye brightness, 0..1, period ~3.1s. Reserved for
   * states that need to be unmistakable at a glance: nothing else about this
   * face is rhythmic, so a pulse cannot be confused with idle life.
   */
  readonly pulse: number;
  /**
   * State colour, carried by the eyes rather than the backdrop. Tinting the
   * smoke floods the frame and loses the dark-on-dark design; a cool glow off
   * the eyes is more visible and more in character. `eyeTint` is the target
   * colour, `eyeTintAmt` how far toward it — the halo takes the most, the
   * core the least, so low amounts read as a coloured glow around the eye.
   */
  readonly eyeTint: readonly [number, number, number];
  readonly eyeTintAmt: number;
  readonly driftRadius: number;
  readonly driftLoops: number;
  readonly noiseContrast: number;
  readonly backdropGain: number;
  readonly violet: number;
  readonly red: number;
}

export const FACE_STATE_PARAMS: Record<VisualState, FaceStateParams> = {
  offline: {
    aperture: 0.07, eyeGain: 0.14, gazeX: 0, gazeY: -0.3, blink: "none", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.05, driftLoops: 0.25, noiseContrast: 0.8,
    backdropGain: 0.45, violet: 0, red: 0,
  },
  starting: {
    aperture: 0.3, eyeGain: 0.45, gazeX: 0, gazeY: 0, blink: "slow", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.18, driftLoops: 0.6, noiseContrast: 0.9,
    backdropGain: 0.7, violet: 0.15, red: 0,
  },
  idle: {
    aperture: 0.55, eyeGain: 1, gazeX: 0, gazeY: 0, blink: "natural", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.35, driftLoops: 1, noiseContrast: 1,
    backdropGain: 1, violet: 0, red: 0,
  },
  listening: {
    aperture: 0.72, eyeGain: 1.15, gazeX: 0, gazeY: 0.05, blink: "sparse", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.45, driftLoops: 1.4, noiseContrast: 1.05,
    backdropGain: 1.1, violet: 0.1, red: 0,
  },
  transcribing: {
    aperture: 0.6, eyeGain: 1, gazeX: 0, gazeY: -0.05, blink: "sparse", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.28, driftLoops: 1.2, noiseContrast: 1,
    backdropGain: 1, violet: 0.1, red: 0,
  },
  routing: {
    aperture: 0.6, eyeGain: 1.05, gazeX: 0.35, gazeY: 0, blink: "none", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.55, driftLoops: 1.8, noiseContrast: 1.1,
    backdropGain: 1.05, violet: 0.2, red: 0,
  },
  // The user has finished asking and NightBlood is producing the result. Blue
  // is exclusive to this foreground voice lane; observed Codex/Claude work
  // remains violet. It keeps thinking's concentrated gaze and slow pulse.
  voice_working: {
    aperture: 0.30, eyeGain: 0.96, gazeX: 0, gazeY: 0.16, blink: "none",
    squint: 0.68, pulse: 0.22,
    eyeTint: ELECTRIC_BLUE, eyeTintAmt: 1,
    driftRadius: 0.25, driftLoops: 1.7, noiseContrast: 1.1,
    backdropGain: 0.7, violet: 0.12, red: 0,
  },
  // Deep in thought — the state that most needs to be unmistakable, because
  // it is the one the user is waiting on. Four signals at once: the eyes
  // narrow hard with concentration, dim, hold one long unfocused fixation up
  // and away, and pulse slowly — while the eyes go cold. The colour is on the
  // EYES, not the smoke: tinting the backdrop flooded the frame and lost the
  // dark-on-dark design, whereas a cold glow off the eyes against a near-black
  // room is both more visible and more like the creature changing rather than
  // the room changing. The backdrop only dims, so the glow has somewhere dark
  // to sit. Narrowing alone read as "tired"; the pulse is what reads as work.
  thinking: {
    aperture: 0.30, eyeGain: 0.94, gazeX: 0, gazeY: 0.16, blink: "none",
    squint: 0.68, pulse: 0.22,
    eyeTint: NEON_VIOLET, eyeTintAmt: 1,
    driftRadius: 0.25, driftLoops: 1.7, noiseContrast: 1.1,
    backdropGain: 0.7, violet: 0.18, red: 0,
  },
  // Same violet as thinking: both mean busy. The states still differ in the
  // ways that carry no vocabulary cost — working keeps its eyes open and
  // scanning, thinking narrows and holds — but the colour says one thing.
  working: {
    aperture: 0.6, eyeGain: 1.05, gazeX: 0, gazeY: 0, blink: "sparse", squint: 0, pulse: 0,
    eyeTint: NEON_VIOLET, eyeTintAmt: 1,
    driftRadius: 0.55, driftLoops: 2.2, noiseContrast: 1.2,
    backdropGain: 1.1, violet: 0.35, red: 0,
  },
  speaking: {
    aperture: 0.62, eyeGain: 1.1, gazeX: 0, gazeY: 0, blink: "sparse", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.4, driftLoops: 1.4, noiseContrast: 1.05,
    backdropGain: 1.05, violet: 0.15, red: 0,
  },
  // Waiting on you. Wide, unblinking, and amber — hot enough to be clearly
  // not the resting ivory, and pulsing so it reads as waiting rather than
  // stuck.
  waiting_approval: {
    aperture: 0.78, eyeGain: 1.2, gazeX: 0, gazeY: 0, blink: "suppressed", squint: 0, pulse: 0.16,
    eyeTint: AMBER, eyeTintAmt: 0.85,
    driftRadius: 0.06, driftLoops: 0.3, noiseContrast: 0.95,
    backdropGain: 0.95, violet: 0.2, red: 0,
  },
  completed: {
    aperture: 0.6, eyeGain: 1.05, gazeX: 0, gazeY: -0.03, blink: "natural", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.3, driftLoops: 0.9, noiseContrast: 0.95,
    backdropGain: 1, violet: 0.15, red: 0,
  },
  // Red belongs on the eyes now, so the backdrop wash drops right back — the
  // room is not what failed.
  error: {
    aperture: 0.5, eyeGain: 0.9, gazeX: 0, gazeY: -0.08, blink: "sparse", squint: 0, pulse: 0,
    eyeTint: ALARM_RED, eyeTintAmt: 0.92,
    driftRadius: 0.3, driftLoops: 1.3, noiseContrast: 1.5,
    backdropGain: 0.9, violet: 0, red: 0.12,
  },
  event_gap: {
    aperture: 0.5, eyeGain: 0.75, gazeX: 0, gazeY: 0, blink: "sparse", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.35, driftLoops: 1.1, noiseContrast: 1.6,
    backdropGain: 0.8, violet: 0.1, red: 0,
  },
  degraded: {
    aperture: 0.5, eyeGain: 0.6, gazeX: 0, gazeY: -0.05, blink: "natural", squint: 0, pulse: 0,
    eyeTint: IVORY, eyeTintAmt: 0,
    driftRadius: 0.15, driftLoops: 0.6, noiseContrast: 0.85,
    backdropGain: 0.65, violet: 0.1, red: 0,
  },
};
