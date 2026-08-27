/**
 * Marshmallow's platform-neutral visual contract.
 *
 * These are expression targets, not another state machine. The canonical
 * resolver remains authoritative and both faces consume its same 15 states.
 * Values are intentionally portable to Swift/Metal or SwiftUI Canvas.
 */

import type { VisualState } from "./types";

export type MarshmallowColour = readonly [number, number, number];
export type MarshmallowMotion = "rest" | "hover" | "bounce" | "still" | "route";

export const MARSHMALLOW_COLOURS = {
  ivory: [1.0, 0.86, 0.63],
  violet: [0.68, 0.08, 1.0],
  cobalt: [0.04, 0.16, 1.0],
  amber: [1.0, 0.48, 0.035],
  red: [1.0, 0.08, 0.12],
  ready: [0.02, 1.0, 0.12],
  bodyTop: [0.78, 0.91, 1.0],
  bodyBottom: [0.18, 0.46, 0.80],
} as const satisfies Record<string, MarshmallowColour>;

/** Shared silhouette measurements used by the director and WebGL renderer. */
export const MARSHMALLOW_BODY_RADIUS = 0.56;
export const MARSHMALLOW_FLOOR_Y = -0.56;

export interface MarshmallowStateParams {
  readonly motion: MarshmallowMotion;
  /** Vertical centre offset in aspect-correct shader coordinates. */
  readonly bodyY: number;
  readonly scaleX: number;
  readonly scaleY: number;
  readonly tilt: number;
  readonly bounceHeight: number;
  readonly bounceHz: number;
  /** Position of the fixed face graphics around the sphere. */
  readonly faceYaw: number;
  readonly facePitch: number;
  readonly eyeHeight: number;
  readonly eyeAsymmetry: number;
  readonly eyeColour: MarshmallowColour;
  readonly eyeGain: number;
  /** Slow state pulse. Reserved for waiting and concentrated work. */
  readonly pulse: number;
  /** -1 frown, 0 flat, +1 smile. */
  readonly smile: number;
  readonly bodyGain: number;
}

const IVORY = MARSHMALLOW_COLOURS.ivory;
const VIOLET = MARSHMALLOW_COLOURS.violet;
const COBALT = MARSHMALLOW_COLOURS.cobalt;
const AMBER = MARSHMALLOW_COLOURS.amber;
const RED = MARSHMALLOW_COLOURS.red;

/** Every canonical state is explicit; adding a new VisualState must fail here. */
export const MARSHMALLOW_STATE_PARAMS: Record<VisualState, MarshmallowStateParams> = {
  offline: {
    motion: "rest", bodyY: -0.075, scaleX: 1.08, scaleY: 0.84, tilt: 0,
    bounceHeight: 0, bounceHz: 0, faceYaw: 0.12, facePitch: 0.16,
    eyeHeight: 0.18, eyeAsymmetry: 0.18, eyeColour: IVORY, eyeGain: 0.14,
    pulse: 0, smile: 0, bodyGain: 0.18,
  },
  starting: {
    motion: "bounce", bodyY: -0.018, scaleX: 1.02, scaleY: 0.94, tilt: -0.03,
    bounceHeight: 0.09, bounceHz: 0.85, faceYaw: 0.14, facePitch: 0.18,
    eyeHeight: 0.48, eyeAsymmetry: 0.05, eyeColour: IVORY, eyeGain: 0.50,
    pulse: 0, smile: 0.15, bodyGain: 0.55,
  },
  idle: {
    motion: "hover", bodyY: 0.018, scaleX: 1, scaleY: 1, tilt: -0.035,
    bounceHeight: 0.032, bounceHz: 0.64, faceYaw: 0.17, facePitch: 0.20,
    eyeHeight: 1, eyeAsymmetry: 0.02, eyeColour: IVORY, eyeGain: 1,
    pulse: 0, smile: 0.58, bodyGain: 1,
  },
  listening: {
    motion: "hover", bodyY: 0.048, scaleX: 1.03, scaleY: 1.04, tilt: 0,
    bounceHeight: 0.022, bounceHz: 0.82, faceYaw: 0.08, facePitch: 0.17,
    eyeHeight: 1.12, eyeAsymmetry: 0, eyeColour: IVORY, eyeGain: 1.14,
    pulse: 0, smile: 0.48, bodyGain: 1.04,
  },
  transcribing: {
    motion: "hover", bodyY: 0.025, scaleX: 1, scaleY: 1, tilt: 0.025,
    bounceHeight: 0.016, bounceHz: 1.05, faceYaw: 0.12, facePitch: 0.16,
    eyeHeight: 0.88, eyeAsymmetry: 0.08, eyeColour: IVORY, eyeGain: 0.96,
    pulse: 0, smile: 0.18, bodyGain: 0.94,
  },
  routing: {
    motion: "route", bodyY: 0.025, scaleX: 1, scaleY: 1, tilt: -0.08,
    bounceHeight: 0.025, bounceHz: 0.82, faceYaw: 0.28, facePitch: 0.18,
    eyeHeight: 0.86, eyeAsymmetry: 0.06, eyeColour: IVORY, eyeGain: 1.02,
    pulse: 0, smile: 0.12, bodyGain: 0.98,
  },
  voice_working: {
    motion: "still", bodyY: 0.045, scaleX: 0.99, scaleY: 1.02, tilt: -0.055,
    bounceHeight: 0, bounceHz: 0, faceYaw: -0.02, facePitch: 0.27,
    eyeHeight: 0.56, eyeAsymmetry: 0.08, eyeColour: COBALT, eyeGain: 0.98,
    pulse: 0.16, smile: 0.10, bodyGain: 0.92,
  },
  thinking: {
    motion: "still", bodyY: 0.045, scaleX: 0.99, scaleY: 1.02, tilt: 0.055,
    bounceHeight: 0, bounceHz: 0, faceYaw: 0.31, facePitch: 0.29,
    eyeHeight: 0.54, eyeAsymmetry: -0.08, eyeColour: VIOLET, eyeGain: 0.96,
    pulse: 0.16, smile: 0.06, bodyGain: 0.91,
  },
  working: {
    motion: "hover", bodyY: 0.026, scaleX: 1, scaleY: 1, tilt: -0.025,
    bounceHeight: 0.012, bounceHz: 0.48, faceYaw: 0.16, facePitch: 0.20,
    eyeHeight: 0.92, eyeAsymmetry: 0.04, eyeColour: VIOLET, eyeGain: 1.04,
    pulse: 0, smile: 0.32, bodyGain: 0.96,
  },
  speaking: {
    motion: "hover", bodyY: 0.026, scaleX: 1, scaleY: 1, tilt: -0.015,
    bounceHeight: 0.018, bounceHz: 0.72, faceYaw: 0.12, facePitch: 0.18,
    eyeHeight: 1.04, eyeAsymmetry: 0, eyeColour: IVORY, eyeGain: 1.10,
    pulse: 0, smile: 0.56, bodyGain: 1.02,
  },
  waiting_approval: {
    motion: "still", bodyY: 0.036, scaleX: 1.02, scaleY: 1.01, tilt: 0,
    bounceHeight: 0, bounceHz: 0, faceYaw: 0.08, facePitch: 0.16,
    eyeHeight: 1.24, eyeAsymmetry: 0, eyeColour: AMBER, eyeGain: 1.10,
    pulse: 0.20, smile: 0.14, bodyGain: 0.98,
  },
  completed: {
    motion: "bounce", bodyY: 0.055, scaleX: 0.98, scaleY: 1.04, tilt: -0.035,
    bounceHeight: 0.17, bounceHz: 0.72, faceYaw: 0.16, facePitch: 0.22,
    eyeHeight: 1.08, eyeAsymmetry: -0.03, eyeColour: IVORY, eyeGain: 1.14,
    pulse: 0, smile: 0.98, bodyGain: 1.05,
  },
  error: {
    motion: "rest", bodyY: -0.078, scaleX: 1.12, scaleY: 0.79, tilt: 0.035,
    bounceHeight: 0, bounceHz: 0, faceYaw: 0.08, facePitch: 0.13,
    eyeHeight: 0.72, eyeAsymmetry: 0.12, eyeColour: RED, eyeGain: 0.92,
    pulse: 0, smile: -0.65, bodyGain: 0.80,
  },
  event_gap: {
    motion: "still", bodyY: -0.005, scaleX: 1.02, scaleY: 0.97, tilt: -0.06,
    bounceHeight: 0, bounceHz: 0, faceYaw: 0.10, facePitch: 0.16,
    eyeHeight: 0.68, eyeAsymmetry: 0.24, eyeColour: IVORY, eyeGain: 0.62,
    pulse: 0, smile: -0.08, bodyGain: 0.58,
  },
  degraded: {
    motion: "rest", bodyY: -0.045, scaleX: 1.06, scaleY: 0.90, tilt: 0.025,
    bounceHeight: 0, bounceHz: 0, faceYaw: 0.10, facePitch: 0.15,
    eyeHeight: 0.66, eyeAsymmetry: -0.12, eyeColour: IVORY, eyeGain: 0.50,
    pulse: 0, smile: 0.02, bodyGain: 0.48,
  },
};
