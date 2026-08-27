/**
 * FaceDirector: the behaviour model behind the eyes.
 *
 * The face has no pupils (blender/scripts/lib/nb_eyes.py: "almond shape, no
 * pupils or iris. Expression comes from aperture, tilt, asymmetry and gaze").
 * So every bit of life has to come out of those four channels, and the way to
 * get it is not more noise — it is *behaviour*: eyes that look at things,
 * dwell, look away to think, and come back to you when they are done.
 *
 * The single most human thing eyes do in conversation is avert while composing
 * and return when handing over the turn. That is modelled explicitly here
 * (see `moodFor` and the transition hooks in `setState`), because it is what
 * makes the face feel like it is with you rather than pointed at you.
 *
 * Pure logic — no DOM, no WebGL — so it stays unit-testable.
 */

import { FACE_STATE_PARAMS, type FaceStateParams } from "./stateParams";
import type { VisualState } from "./types";

export interface FaceUniforms {
  apertureL: number;
  apertureR: number;
  /** Animated lid tilt per eye, radians. Was a constant; now it emotes. */
  tiltL: number;
  tiltR: number;
  /** Lid tension 0..1. Raises the lower lid and flattens the top arch. */
  squintL: number;
  squintR: number;
  /** State colour carried by the eyes, and how far toward it. */
  eyeTint: readonly [number, number, number];
  eyeTintAmt: number;
  eyeGain: number;
  /** Gaze intent, normalised [-1, 1]. Kept for tests and the floor reflection. */
  gazeX: number;
  gazeY: number;
  /** Per-eye gaze including saccadic lag and vergence. */
  gazeLX: number;
  gazeLY: number;
  gazeRX: number;
  gazeRY: number;
  driftPhase1: number;
  driftPhase2: number;
  driftRadius: number;
  noiseContrast: number;
  backdropGain: number;
  violet: number;
  red: number;
  /** Shaped speech envelope 0..1 — fast attack, slow release. */
  speak: number;
  /** Integrates with speech so the backdrop churn accelerates without jumping. */
  speakPhase: number;
  /** Seconds since start, for effects that need their own frequency. */
  time: number;
  /** Telemetry: how much the camera can see. Not expression. */
  seen: number;
  looking: number;
  reducedMotion: boolean;
}

/**
 * What being seen does to the face. Switchable so they can be compared on the
 * panel rather than argued about — the same arrangement the speaking concepts
 * use. See docs/reference/face/GAZE_CONCEPTS.md.
 */
export const GAZE = {
  TRACK: 1,    // A: the eyes go where you are
  LOCK: 2,     // B: meeting its gaze holds it
  LIFT: 4,     // C: it brightens and opens while watched
  ACQUIRE: 8,  // D: a flick and a blink the moment it notices
  LINGER: 16,  // E: it keeps looking for a beat after you stop
  NEAR: 32,    // F: leaning in changes its register
  WAKE: 64,    // G: the room stirs when anyone is there at all
} as const;

/** The §4 contract as the face receives it. Never a frame, never a landmark. */
export interface Watched {
  readonly present: boolean;
  readonly x?: number;
  readonly y?: number;
  readonly distance?: number;
  readonly yaw?: number;
  readonly pitch?: number;
}

// Measured at the desk on 13 Aug 2026, not chosen: facing NightBlood reads yaw
// about -5, facing the monitor about +30. The band sits inside that gap, and
// entering is easier than leaving so a head hovering at the boundary cannot
// flicker the state on and off — which would be far more unsettling than
// either answer.
const LOOK_ENTER_YAW = 14;
const LOOK_EXIT_YAW = 24;

// Where they are, in the target space the director already thinks in. Both are
// negative because the camera and the face look at each other: someone moving
// to their own right crosses the frame the other way. Named, and checked on the
// panel rather than reasoned about — reasoning got the head-pose signs exactly
// backwards earlier the same day.
// Raised from 1.15/0.85 after the first live test. At that gain, sitting
// normally moved the eyes about 10px while the face's own postural drift and
// random saccades moved them 3-4 times further — the tracking was real and
// completely buried, which is indistinguishable from not working.
const TRACK_X = -2.4;
const TRACK_Y = -1.5;

// Detection jitters a degree or two frame to frame; a person does not. Easing
// the observed position before the eyes use it is what turns "following" into
// something smooth rather than a fine tremble on top of a real movement.
const WATCH_EASE_S = 0.18;

// Where someone habitually sits is not the middle of the frame. The camera is
// mounted above the panel looking down, so a seated person reads y ~ +0.5 all
// the time — which as an absolute position pinned the eyes at their downward
// clamp permanently. What matters is movement away from where you usually are,
// so the reference adapts, slowly enough that leaning across the desk is
// followed in full and only a genuinely new resting place is absorbed. It also
// means the mounting never needs measuring: it calibrates itself.
const REST_ADAPT_S = 40;

const TRANSITION_S = 0.6;
const BLINK_CLOSE_S = 0.07;
const BLINK_OPEN_S = 0.18;

/**
 * How the eyes are relating to you right now. This is the top of the
 * behaviour model: it picks where gaze targets come from and how long they
 * are held, which is most of what separates "alive" from "pointed at you".
 */
type Mood =
  /** With you. Targets cluster on your face, held long. */
  | "engaged"
  /** Composing. Looks up and away and mostly stays there. */
  | "averted"
  /** Busy. Scans the room, comes back to you occasionally. */
  | "wandering"
  /** Unoccupied. Long settled fixations — a creature at rest, not scanning. */
  | "resting"
  /** Locked. Barely moves — used for held, low-energy or waiting states. */
  | "fixed";

function moodFor(state: VisualState): Mood {
  switch (state) {
    case "listening":
    case "transcribing":
      return "engaged";
    case "waiting_approval":
      return "fixed";
    case "speaking":
    case "completed":
      return "engaged";
    case "voice_working":
    case "thinking":
    case "routing":
      return "averted";
    case "working":
      return "wandering";
    case "error":
      return "averted";
    case "offline":
    case "starting":
    case "degraded":
      return "fixed";
    default:
      // Idle. Deliberately NOT "wandering": nothing is happening, so the eyes
      // should settle rather than scan. Busy-looking idle reads as twitchy.
      return "resting";
  }
}

interface Target {
  x: number;
  y: number;
  /** Seconds to hold once arrived. */
  dwell: number;
}

interface BlinkState {
  nextAt: number;
  phase: "open" | "closing" | "opening" | "second_pause" | null;
  phaseStart: number;
  doubleQueued: boolean;
}

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function blinkInterval(policy: FaceStateParams["blink"], rng: () => number): number {
  switch (policy) {
    // Longer than it looks: gaze shifts now trigger their own blinks, so the
    // baseline timer only has to cover the gaps.
    case "natural": return 3.2 + rng() * 3.6;
    case "sparse": return 5 + rng() * 4.5;
    case "slow": return 4.5 + rng() * 3.5;
    default: return Number.POSITIVE_INFINITY;
  }
}

export class FaceDirector {
  private current: FaceStateParams = FACE_STATE_PARAMS.idle;
  private previous: FaceStateParams = FACE_STATE_PARAMS.idle;
  private transitionStart = 0;
  private lastTime = 0;
  private drift1 = 0;
  private drift2 = 0;
  private state: VisualState = "idle";
  // Must agree with `state`: setState early-returns when the state has not
  // changed, so a mismatch here would never be corrected and the face would
  // spend its whole opening in the wrong mood.
  private mood: Mood = moodFor("idle");

  // Gaze: where we are, where we are going, and when we may move again.
  private gaze = { x: 0, y: 0 };
  private from = { x: 0, y: 0 };
  private target: Target = { x: 0, y: 0, dwell: 1.2 };
  private moveStart = -10;
  private moveDur = 0.06;
  private holdUntil = 0;
  /** Set when a shift should also trigger a blink (real eyes do this). */
  private blinkOnArrival = false;

  private blink: BlinkState = { nextAt: 0, phase: "open", phaseStart: 0, doubleQueued: false };
  private rng: () => number;
  private speak = 0;
  private speakPhase = 0;
  /**
   * Which director-side speaking concepts are on. D articulates the lids on
   * stress; G quiets everything else while talking. Both default OFF — the
   * shipped answer is A+B+C in the shader. See SPEAKING_CONCEPTS.md.
   */
  speakLid = false;
  speakStill = false;

  /** Which gaze concepts are on. See GAZE and GAZE_CONCEPTS.md. */
  gazeMask: number = GAZE.TRACK | GAZE.LOCK | GAZE.LIFT | GAZE.ACQUIRE
    | GAZE.LINGER | GAZE.NEAR | GAZE.WAKE;
  private watched: Watched | null = null;
  /** Latched with hysteresis, so it is a decision rather than a flicker. */
  private lookingAtMe = false;
  /** Eased, because attention arriving as a step change reads as a light switch. */
  private attention = 0;
  private presence = 0;
  private lookEndedAt = -100;
  /** Eased observation, so detection jitter never reaches the eyes. */
  private watchPoint = { x: 0, y: 0 };
  /** Habitual position, adapted slowly. See REST_ADAPT_S. */
  private rest = { x: 0, y: 0 };
  private restSeen = false;
  /** True when the current fixation is the person rather than a virtual point. */
  private followingWatched = false;

  constructor(seed = 1103, private reducedMotion = false) {
    this.rng = mulberry32(seed);
    this.blink.nextAt = 2 + this.rng() * 4;
  }

  setReducedMotion(enabled: boolean): void {
    this.reducedMotion = enabled;
  }

  /**
   * What the camera can see. Absent or stale input means "we no longer know",
   * which resolves to alone — never to the last place someone was standing.
   */
  setWatched(watched: Watched | null, now: number): void {
    this.watched = watched && watched.present ? watched : null;
    const yaw = this.watched?.yaw;
    const was = this.lookingAtMe;
    if (this.watched == null || yaw == null) {
      this.lookingAtMe = false;
    } else {
      // Asymmetric thresholds: easier to be noticed than to be dismissed.
      this.lookingAtMe = was
        ? Math.abs(yaw) < LOOK_EXIT_YAW
        : Math.abs(yaw) < LOOK_ENTER_YAW;
    }
    if (this.lookingAtMe && !was) {
      // D: the double-take. Whatever it was doing, it comes straight to you and
      // blinks on arrival — the blink is what turns a movement into noticing.
      if (this.gazeMask & GAZE.ACQUIRE) {
        this.saccadeTo({ ...this.watchedTarget(), dwell: 2.4 }, now, 0.05);
        this.followingWatched = true;
        this.blinkOnArrival = true;
      }
    } else if (!this.lookingAtMe && was) {
      this.lookEndedAt = now;
    }
  }

  /** Where the person is, in the target space this director already uses. */
  private watchedTarget(): Target {
    return { x: this.watchPoint.x, y: this.watchPoint.y, dwell: 1.2 };
  }

  /**
   * Follow the person continuously once acquired, instead of re-aiming at them
   * every couple of seconds. Real eyes saccade to catch a target and then
   * pursue it smoothly; only doing the first half is what made the tracking
   * read as random twitching that happened to be near the right place.
   */
  private pursue(dt: number): void {
    const w = this.watched;
    if (!w) return;
    const ox = w.x ?? 0;
    const oy = w.y ?? 0;
    if (this.restSeen) {
      const adapt = Math.min(1, dt / REST_ADAPT_S);
      this.rest.x += (ox - this.rest.x) * adapt;
      this.rest.y += (oy - this.rest.y) * adapt;
    } else {
      // First sight: start from where they actually are rather than easing in
      // from the middle of the frame, which would swing the eyes across the
      // face for the first minute after anyone appeared.
      this.rest.x = ox;
      this.rest.y = oy;
      this.restSeen = true;
    }
    const tx = Math.max(-0.9, Math.min(0.9, (ox - this.rest.x) * TRACK_X));
    const ty = Math.max(-0.55, Math.min(0.55, (oy - this.rest.y) * TRACK_Y));
    const ease = Math.min(1, dt / WATCH_EASE_S);
    this.watchPoint.x += (tx - this.watchPoint.x) * ease;
    this.watchPoint.y += (ty - this.watchPoint.y) * ease;
    // Carry the live position into an in-flight or settled fixation on the
    // person, so they are followed rather than left behind between saccades.
    if (this.followingWatched) {
      this.target.x = this.watchPoint.x;
      this.target.y = this.watchPoint.y;
    }
  }

  setState(state: VisualState, now: number): void {
    if (state === this.state) return;
    const wasThinking = this.mood === "averted";
    this.previous = this.paramsAt(now);
    this.current = FACE_STATE_PARAMS[state];
    this.state = state;
    this.mood = moodFor(state);
    this.transitionStart = now;

    // The turn-taking cue. Coming out of thought and back into contact is a
    // deliberate, slightly slower return to your face — this is the gesture
    // that reads as "I'm back with you", and it only works if it is prompt.
    if (wasThinking && this.mood === "engaged") {
      this.saccadeTo({ x: 0, y: 0.02, dwell: 1.6 + this.rng() * 1.4 }, now, 0.1);
      this.blinkOnArrival = true;
    } else if (this.mood === "averted") {
      // Breaking gaze to compose. Up and to one side, the way people do when
      // recalling something.
      const side = this.rng() < 0.5 ? -1 : 1;
      this.saccadeTo(
        { x: side * (0.45 + this.rng() * 0.3), y: 0.3 + this.rng() * 0.25,
          dwell: 2.4 + this.rng() * 3.0 },
        now, 0.075,
      );
      this.blinkOnArrival = this.rng() < 0.5;
    } else {
      // Any other state change gets a fresh look, so transitions are visible.
      this.pickTarget(now);
      this.blinkOnArrival = this.rng() < 0.55;
    }

    if (this.current.blink === "suppressed" || this.current.blink === "none") {
      this.blink.phase = "open";
      this.blink.nextAt = now + blinkInterval(this.current.blink, this.rng);
    }
  }

  get visualState(): VisualState {
    return this.state;
  }

  /** Begin a saccade to a target. Duration follows amplitude, as real ones do. */
  private saccadeTo(target: Target, now: number, minDur = 0.045): void {
    this.from = { ...this.gaze };
    this.target = target;
    const amp = Math.hypot(target.x - this.gaze.x, target.y - this.gaze.y);
    // Main sequence: bigger movements take longer, but all of them are fast
    // enough to read as a flick rather than a glide.
    this.moveDur = Math.max(minDur, Math.min(0.13, 0.035 + amp * 0.075));
    this.moveStart = now;
    this.holdUntil = now + this.moveDur + target.dwell;
  }

  /** Choose somewhere to look, weighted by what the face is currently doing. */
  private pickTarget(now: number): void {
    const r = this.rng();
    let t: Target;

    // A person in the room outranks the virtual points of interest. The eyes
    // still break away and come back — a gaze that never leaves you is a stare,
    // and the returns are what read as attention rather than as a sensor lock.
    if (this.watched && (this.gazeMask & GAZE.TRACK)) {
      const at = this.watchedTarget();
      const lingering = (this.gazeMask & GAZE.LINGER)
        && now - this.lookEndedAt < 1.3;
      const holding = this.lookingAtMe && (this.gazeMask & GAZE.LOCK);
      // B: while you hold its gaze it holds yours, with only the small breaks
      // real eye contact has. E: and it does not drop you the instant you look
      // away — it keeps watching for a beat first.
      const stay = holding ? 0.86 : lingering ? 0.8 : 0.5;
      if (r < stay) {
        t = { x: at.x, y: at.y, dwell: holding ? 1.6 + this.rng() * 2.4 : 0.9 + this.rng() * 1.4 };
        this.followingWatched = true;
      } else if (r < stay + 0.22) {
        // The brief glance aside that stops eye contact becoming a stare.
        t = { x: at.x + (this.rng() * 2 - 1) * 0.3, y: at.y + (this.rng() * 2 - 1) * 0.2,
              dwell: 0.3 + this.rng() * 0.5 };
        this.followingWatched = false;
      } else {
        t = { x: (this.rng() * 2 - 1) * 0.7, y: (this.rng() * 2 - 1) * 0.35,
              dwell: 0.3 + this.rng() * 0.9 };
        this.followingWatched = false;
      }
      this.saccadeTo(t, now);
      const amp = Math.hypot(t.x - this.gaze.x, t.y - this.gaze.y);
      this.blinkOnArrival = this.rng() < 0.12 + Math.min(0.5, amp * 0.55);
      return;
    }

    switch (this.mood) {
      case "engaged": {
        // Mostly your face, with the small breaks that stop eye contact
        // becoming a stare — people glance away briefly even mid-sentence.
        if (r < 0.62) {
          t = { x: (this.rng() * 2 - 1) * 0.1, y: (this.rng() * 2 - 1) * 0.07,
                dwell: 1.1 + this.rng() * 2.2 };
        } else if (r < 0.85) {
          t = { x: (this.rng() * 2 - 1) * 0.34, y: (this.rng() * 2 - 1) * 0.2,
                dwell: 0.35 + this.rng() * 0.6 };
        } else {
          t = { x: (this.rng() * 2 - 1) * 0.7, y: -0.1 - this.rng() * 0.3,
                dwell: 0.25 + this.rng() * 0.4 };
        }
        break;
      }
      case "averted": {
        // Deep thought holds one long unfocused fixation and drifts within it
        // rather than hunting around. Staying put IS the expression; an eye
        // that keeps re-aiming looks like it is searching, not thinking.
        const side = this.gaze.x >= 0 ? 1 : -1;
        t = { x: side * (0.4 + this.rng() * 0.3), y: 0.26 + this.rng() * 0.26,
              dwell: 2.2 + this.rng() * 3.4 };
        break;
      }
      case "resting": {
        // At rest the eyes settle. Mostly small adjustments held a long time,
        // with the occasional proper look away so it never reads as frozen.
        if (r < 0.72) {
          t = { x: (this.rng() * 2 - 1) * 0.26, y: (this.rng() * 2 - 1) * 0.16,
                dwell: 2.6 + this.rng() * 3.8 };
        } else {
          t = { x: (this.rng() * 2 - 1) * 0.72, y: (this.rng() * 2 - 1) * 0.34,
                dwell: 1.6 + this.rng() * 2.6 };
        }
        break;
      }
      case "wandering": {
        // Scans, and returns to you every so often — the return is what makes
        // it feel like it knows you are there.
        if (r < 0.28) {
          t = { x: (this.rng() * 2 - 1) * 0.12, y: (this.rng() * 2 - 1) * 0.08,
                dwell: 0.8 + this.rng() * 1.6 };
        } else {
          t = { x: (this.rng() * 2 - 1) * 0.85, y: (this.rng() * 2 - 1) * 0.45,
                dwell: 0.3 + this.rng() * 1.1 };
        }
        break;
      }
      default: {
        t = { x: (this.rng() * 2 - 1) * 0.06, y: (this.rng() * 2 - 1) * 0.04,
              dwell: 2 + this.rng() * 3 };
      }
    }
    this.followingWatched = false;
    this.saccadeTo(t, now);
    // Large shifts pull a blink with them far more often than small ones.
    const amp = Math.hypot(t.x - this.gaze.x, t.y - this.gaze.y);
    this.blinkOnArrival = this.rng() < 0.12 + Math.min(0.5, amp * 0.55);
  }

  /** Interpolated params during the transition window. */
  private paramsAt(now: number): FaceStateParams {
    const t = Math.min(1, (now - this.transitionStart) / TRANSITION_S);
    const e = t * t * (3 - 2 * t);
    const a = this.previous;
    const b = this.current;
    const mix = (x: number, y: number) => x + (y - x) * e;
    return {
      aperture: mix(a.aperture, b.aperture),
      eyeGain: mix(a.eyeGain, b.eyeGain),
      gazeX: mix(a.gazeX, b.gazeX),
      gazeY: mix(a.gazeY, b.gazeY),
      blink: b.blink,
      squint: mix(a.squint, b.squint),
      pulse: mix(a.pulse, b.pulse),
      // Interpolate the colour itself, not just the amount, so a change of
      // target hue crossfades instead of snapping.
      eyeTint: [
        mix(a.eyeTint[0], b.eyeTint[0]),
        mix(a.eyeTint[1], b.eyeTint[1]),
        mix(a.eyeTint[2], b.eyeTint[2]),
      ],
      eyeTintAmt: mix(a.eyeTintAmt, b.eyeTintAmt),
      driftRadius: mix(a.driftRadius, b.driftRadius),
      driftLoops: mix(a.driftLoops, b.driftLoops),
      noiseContrast: mix(a.noiseContrast, b.noiseContrast),
      backdropGain: mix(a.backdropGain, b.backdropGain),
      violet: mix(a.violet, b.violet),
      red: mix(a.red, b.red),
    };
  }

  private blinkFactor(now: number, policy: FaceStateParams["blink"]): number {
    const b = this.blink;
    if (policy === "suppressed" || policy === "none") return 1;
    if (b.phase === "open" && now >= b.nextAt) {
      b.phase = "closing";
      b.phaseStart = now;
      b.doubleQueued = this.rng() < 0.4;
    }
    const dt = now - b.phaseStart;
    switch (b.phase) {
      case "closing": {
        const t = Math.min(1, dt / BLINK_CLOSE_S);
        if (t >= 1) {
          b.phase = "opening";
          b.phaseStart = now;
        }
        return 1 - t;
      }
      case "opening": {
        const t = Math.min(1, dt / BLINK_OPEN_S);
        if (t >= 1) {
          if (b.doubleQueued) {
            b.phase = "second_pause";
            b.phaseStart = now;
          } else {
            b.phase = "open";
            b.nextAt = now + blinkInterval(policy, this.rng);
          }
        }
        return b.doubleQueued ? t * 0.7 : t;
      }
      case "second_pause": {
        if (dt > 0.12) {
          b.phase = "opening";
          b.phaseStart = now;
          b.doubleQueued = false;
        }
        return 0.7;
      }
      default:
        return 1;
    }
  }

  /** Force a blink now, unless one is already running. */
  private triggerBlink(now: number, policy: FaceStateParams["blink"]): void {
    if (policy === "suppressed" || policy === "none") return;
    if (this.blink.phase !== "open") return;
    this.blink.nextAt = now;
  }

  /**
   * Per-frame uniforms. `amplitude` MUST be AuthorisedAmplitudeTracker.amplitude
   * — zero unless an authorised speech job is active (spec 14.6).
   */
  frame(now: number, amplitude: number): FaceUniforms {
    const dt = this.lastTime === 0 ? 0 : Math.min(0.1, now - this.lastTime);
    this.lastTime = now;
    const p = this.paramsAt(now);
    const slow = this.reducedMotion ? 0.3 : 1;

    // Speech envelope: rise instantly, fall over ~140ms. Gaps between words
    // must not read as silence, but the end of a sentence must.
    const level = Math.max(0, Math.min(1, amplitude));
    this.speak = level > this.speak ? level : this.speak * Math.exp(-dt / 0.14);
    // Integrated, so the churn it drives accelerates smoothly and never jumps.
    this.speakPhase += dt * this.speak * 0.9;

    // Drift phase advances by current speed: continuous across transitions.
    // Denominator raised from 12: the smoke should slosh, not seethe.
    this.drift1 += ((2 * Math.PI * p.driftLoops) / 19) * dt * slow;
    this.drift2 -= ((2 * Math.PI * p.driftLoops * 0.6) / 19) * dt * slow;

    // --- Gaze: move, arrive, dwell, choose again -------------------------
    // G: while speaking, everything else quiets — the eyes settle instead of
    // continuing to browse the room.
    if (this.speakStill && this.speak > 0.08) this.holdUntil = Math.max(this.holdUntil, now + 0.25);
    if (now >= this.holdUntil && !this.reducedMotion) this.pickTarget(now);
    this.pursue(dt);

    const mt = Math.min(1, Math.max(0, (now - this.moveStart) / this.moveDur));
    // Saccades decelerate hard into their target rather than easing both ends.
    const me = 1 - Math.pow(1 - mt, 3);
    this.gaze.x = this.from.x + (this.target.x - this.from.x) * me;
    this.gaze.y = this.from.y + (this.target.y - this.from.y) * me;

    if (this.blinkOnArrival && mt >= 1) {
      this.blinkOnArrival = false;
      this.triggerBlink(now, p.blink);
    }

    // Postural drift: a very slow settle so the resting pose is never twice
    // the same. Long periods, deliberately not in sync with anything else.
    const postX = Math.sin(now * 0.037) * 0.075 + Math.sin(now * 0.019 + 2.1) * 0.045;
    const postY = Math.cos(now * 0.028) * 0.05 + Math.sin(now * 0.013 + 0.7) * 0.03;

    // Ocular microtremor: real eyes never hold perfectly still. Tiny and fast
    // — invisible as motion, but its absence is what reads as "dead".
    const trem = this.reducedMotion ? 0 : 1;
    const tremX = (Math.sin(now * 7.3) * 0.004 + Math.sin(now * 11.7 + 1.3) * 0.0025) * trem;
    const tremY = (Math.cos(now * 8.9) * 0.003 + Math.sin(now * 13.1 + 0.4) * 0.002) * trem;

    const gx = p.gazeX + this.gaze.x + postX * slow + tremX;
    const gy = p.gazeY + this.gaze.y + postY * slow + tremY;

    // --- Asymmetry --------------------------------------------------------
    // One eye leads the other very slightly, and vergence pulls them together
    // when looking down and close. Neither is consciously visible; together
    // they are most of the difference between two lights and two eyes.
    const lag = this.reducedMotion ? 0 : 0.16;
    const lead = (this.target.x - this.from.x) * (1 - me) * lag;
    const verge = Math.max(0, -gy) * 0.05;

    const breath = 1 + Math.sin(now * 0.62) * 0.055 + Math.sin(now * 0.23) * 0.025;
    const breathR = 1 + Math.sin(now * 0.62 + 0.9) * 0.05 + Math.sin(now * 0.19) * 0.022;

    // --- Being seen -------------------------------------------------------
    // Both eased rather than switched: attention that arrives as a step change
    // reads as a light coming on, not as a creature noticing.
    const ease = Math.min(1, dt / 0.38);
    this.attention += ((this.lookingAtMe ? 1 : 0) - this.attention) * ease;
    this.presence += ((this.watched ? 1 : 0) - this.presence) * Math.min(1, dt / 0.9);
    const attention = (this.gazeMask & GAZE.LIFT) ? this.attention : 0;
    const presence = (this.gazeMask & GAZE.WAKE) ? this.presence : 0;
    // F: leaning in is quieter and closer-held; sitting back opens it out. The
    // room dims as you approach, so the eyes carry more of the frame.
    const near = (this.gazeMask & GAZE.NEAR) && this.watched
      ? 1 - Math.max(0, Math.min(1, this.watched.distance ?? 0.6))
      : 0;
    // C: awake to you — a little wider and a little brighter, held well under
    // the state colours so it reads as attention rather than as a new state.
    const lidAttend = 1 + attention * 0.10 - near * 0.09;
    const gainAttend = 1 + attention * 0.16;
    const roomAttend = 1 + presence * 0.10 - near * 0.16;

    const blink = this.blinkFactor(now, p.blink);
    // The right lid trails the left by a few milliseconds' worth of closure.
    const blinkR = Math.max(0, Math.min(1, blink * 1.06 - 0.06));

    // Lids respond to where the eye is looking: looking up opens them, looking
    // down lowers them. Squint rises as the gaze drops, and asymmetrically —
    // a perfectly matched pair of lids is the other half of the headlights.
    // D: lids flex a few percent on stress. Small — at speech rate anything
    // larger reads as fluttering, and fluttering already means something else.
    const lidSpeak = this.speakLid ? 1 - this.speak * 0.09 : 1;
    const lidLift = (1 + gy * 0.16) * lidSpeak;
    const squintBase =
      p.squint + Math.max(0, -gy) * 0.45 + Math.max(0, Math.abs(gx) - 0.5) * 0.3;
    const wobble = Math.sin(now * 0.087 + 1.7) * 0.06;

    return {
      apertureL: p.aperture * blink * breath * lidLift * lidAttend,
      apertureR: p.aperture * blinkR * breathR * lidLift * lidAttend * 0.985,
      // Tilt was a constant in the shader and never moved. Now the outer
      // corners settle and lift a little as the face looks around, which is
      // where most of the expression lives on a face with no brows.
      tiltL: -0.105 + gy * 0.05 - gx * 0.035 + wobble * 0.5,
      tiltR: 0.079 + gy * 0.045 + gx * 0.03 - wobble * 0.5,
      squintL: Math.max(0, Math.min(1, squintBase + wobble)),
      squintR: Math.max(0, Math.min(1, squintBase * 0.88 - wobble)),
      eyeTint: p.eyeTint,
      eyeTintAmt: p.eyeTintAmt,
      // A slow rhythmic swing, used only where a state must be obvious at a
      // glance. Period ~3.1s: fast enough to read as activity, slow enough
      // that it never reads as a spinner.
      eyeGain: p.eyeGain * (1 + p.pulse * Math.sin(now * 2.03)) * gainAttend,
      gazeX: gx,
      gazeY: gy,
      gazeLX: gx + lead - verge,
      gazeLY: gy,
      gazeRX: gx - lead * 0.7 + verge,
      gazeRY: gy + Math.sin(now * 0.41) * 0.006,
      driftPhase1: this.drift1,
      driftPhase2: this.drift2,
      driftRadius: p.driftRadius * (this.reducedMotion ? 0.5 : 1),
      noiseContrast: p.noiseContrast,
      backdropGain: p.backdropGain * roomAttend,
      violet: p.violet,
      red: p.red,
      speak: this.speak,
      speakPhase: this.speakPhase,
      time: now,
      seen: this.presence,
      looking: this.attention,
      reducedMotion: this.reducedMotion,
    };
  }
}
