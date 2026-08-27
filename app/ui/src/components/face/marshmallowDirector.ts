/**
 * Marshmallow's behaviour model.
 *
 * Pure logic: canonical state, authorised output amplitude and the existing
 * abstract gaze contract in; renderer uniforms out. Camera frames never enter
 * this class and the eyes never track independently — the whole ball moves.
 */

import type { Watched } from "./faceDirector";
import {
  MARSHMALLOW_BODY_RADIUS,
  MARSHMALLOW_STATE_PARAMS,
  type MarshmallowColour,
  type MarshmallowStateParams,
} from "./marshmallowStateParams";
import type { VisualState } from "./types";

export interface MarshmallowUniforms {
  readonly time: number;
  readonly bodyX: number;
  readonly bodyY: number;
  readonly scaleX: number;
  readonly scaleY: number;
  readonly tilt: number;
  readonly faceYaw: number;
  readonly facePitch: number;
  readonly eyeHeight: number;
  readonly eyeAsymmetry: number;
  readonly eyeColour: MarshmallowColour;
  readonly eyeGain: number;
  readonly smile: number;
  /** Smoothed authorised output amplitude. Silent states always resolve to 0. */
  readonly mouthOpen: number;
  readonly bodyGain: number;
  readonly seen: number;
  readonly looking: number;
  readonly reducedMotion: boolean;
}

interface Pose {
  bodyY: number;
  scaleX: number;
  scaleY: number;
  tilt: number;
  faceYaw: number;
  facePitch: number;
  eyeHeight: number;
  eyeAsymmetry: number;
  eyeColour: [number, number, number];
  eyeGain: number;
  smile: number;
  bodyGain: number;
}

const LOOK_ENTER_YAW = 14;
const LOOK_EXIT_YAW = 24;
const TRACK_EASE_S = 0.22;
const POSE_EASE_S = 0.34;

const clamp = (value: number, lower = 0, upper = 1) =>
  Math.min(upper, Math.max(lower, value));

const finite = (value: number | undefined, fallback = 0) =>
  typeof value === "number" && Number.isFinite(value) ? value : fallback;

const copyPose = (p: MarshmallowStateParams): Pose => ({
  bodyY: p.bodyY,
  scaleX: p.scaleX,
  scaleY: p.scaleY,
  tilt: p.tilt,
  faceYaw: p.faceYaw,
  facePitch: p.facePitch,
  eyeHeight: p.eyeHeight,
  eyeAsymmetry: p.eyeAsymmetry,
  eyeColour: [...p.eyeColour],
  eyeGain: p.eyeGain,
  smile: p.smile,
  bodyGain: p.bodyGain,
});

function ease(current: number, target: number, dt: number, seconds: number): number {
  if (seconds <= 0) return target;
  return current + (target - current) * (1 - Math.exp(-dt / seconds));
}

export class MarshmallowDirector {
  private state: VisualState = "idle";
  private stateStartedAt = 0;
  private lastTime: number | null = null;
  private pose: Pose = copyPose(MARSHMALLOW_STATE_PARAMS.idle);
  private watched: Watched | null = null;
  private trackX = 0;
  private trackY = 0;
  private presence = 0;
  private attention = 0;
  private lookingAtMe = false;
  private speak = 0;
  private reducedMotion = false;

  setState(state: VisualState, now: number): void {
    if (state === this.state) return;
    this.state = state;
    this.stateStartedAt = now;
  }

  setReducedMotion(reduced: boolean): void {
    this.reducedMotion = reduced;
  }

  /** The same bounded, frame-free observation consumed by NightBlood. */
  setWatched(watched: Watched | null): void {
    this.watched = watched?.present === true ? watched : null;
    const yaw = this.watched?.yaw;
    if (yaw == null || !Number.isFinite(yaw)) {
      this.lookingAtMe = false;
      return;
    }
    const threshold = this.lookingAtMe ? LOOK_EXIT_YAW : LOOK_ENTER_YAW;
    this.lookingAtMe = Math.abs(yaw) <= threshold;
  }

  private transitionPose(target: MarshmallowStateParams, dt: number): void {
    const k = (current: number, next: number) => ease(current, next, dt, POSE_EASE_S);
    this.pose.bodyY = k(this.pose.bodyY, target.bodyY);
    this.pose.scaleX = k(this.pose.scaleX, target.scaleX);
    this.pose.scaleY = k(this.pose.scaleY, target.scaleY);
    this.pose.tilt = k(this.pose.tilt, target.tilt);
    this.pose.faceYaw = k(this.pose.faceYaw, target.faceYaw);
    this.pose.facePitch = k(this.pose.facePitch, target.facePitch);
    this.pose.eyeHeight = k(this.pose.eyeHeight, target.eyeHeight);
    this.pose.eyeAsymmetry = k(this.pose.eyeAsymmetry, target.eyeAsymmetry);
    this.pose.eyeGain = k(this.pose.eyeGain, target.eyeGain);
    this.pose.smile = k(this.pose.smile, target.smile);
    this.pose.bodyGain = k(this.pose.bodyGain, target.bodyGain);
    for (let i = 0; i < 3; i++) {
      this.pose.eyeColour[i] = k(this.pose.eyeColour[i], target.eyeColour[i]);
    }
  }

  frame(now: number, authorisedAmplitude: number): MarshmallowUniforms {
    const dt = this.lastTime == null ? 1 / 60 : clamp(now - this.lastTime, 0, 0.1);
    this.lastTime = now;
    const params = MARSHMALLOW_STATE_PARAMS[this.state];
    this.transitionPose(params, dt);

    const targetTrackX = this.watched
      ? clamp(-finite(this.watched.x) * 0.30, -0.25, 0.25)
      : 0;
    const targetTrackY = this.watched
      ? clamp(-finite(this.watched.y) * 0.075, -0.065, 0.065)
      : 0;
    const trackSeconds = this.reducedMotion ? 0.75 : TRACK_EASE_S;
    this.trackX = ease(this.trackX, targetTrackX, dt, trackSeconds);
    this.trackY = ease(this.trackY, targetTrackY, dt, trackSeconds);
    this.presence = ease(this.presence, this.watched ? 1 : 0, dt, 0.7);
    this.attention = ease(this.attention, this.lookingAtMe ? 1 : 0, dt, 0.35);

    const rawLevel = this.state === "speaking"
      ? clamp(Number.isFinite(authorisedAmplitude) ? authorisedAmplitude : 0)
      : 0;
    this.speak = ease(this.speak, rawLevel, dt, rawLevel > this.speak ? 0.045 : 0.12);

    const t = Math.max(0, now - this.stateStartedAt);
    let motionY = 0;
    let motionX = 0;
    let motionScaleX = 1;
    let motionScaleY = 1;
    let motionTilt = 0;

    if (!this.reducedMotion) {
      const phase = t * Math.max(0, params.bounceHz);
      if (params.motion === "hover") {
        const wave = Math.sin(phase * Math.PI * 2);
        motionY = wave * params.bounceHeight;
        motionScaleY = 1 + Math.cos(phase * Math.PI * 2) * 0.025;
        motionScaleX = 1 / Math.sqrt(motionScaleY);
      } else if (params.motion === "bounce") {
        const cycle = phase - Math.floor(phase);
        const flight = Math.pow(Math.max(0, Math.sin(Math.PI * cycle)), 1.4);
        const velocity = Math.abs(Math.cos(Math.PI * cycle));
        const nearContact = 1 - clamp(flight / 0.25);
        motionScaleY = (1 + 0.10 * velocity) * (1 - 0.30 * Math.pow(nearContact, 1.5));
        motionScaleX = 1 / Math.sqrt(Math.max(0.55, motionScaleY));
        // Lower the centre as the body squashes so its underside meets the
        // floor instead of visibly hovering above it at the bottom of a hop.
        const contactCorrection = MARSHMALLOW_BODY_RADIUS * params.scaleY
          * (motionScaleY - 1);
        motionY = params.bounceHeight * flight + contactCorrection;
      } else if (params.motion === "route") {
        motionX = Math.sin(phase * Math.PI * 2) * 0.065;
        motionY = Math.abs(Math.sin(phase * Math.PI * 2)) * params.bounceHeight;
        motionTilt = -Math.cos(phase * Math.PI * 2) * 0.08;
      }
    }

    // A speaking body participates without pretending the input is louder:
    // the mouth is the direct amplitude channel; this is only a small response.
    motionY += this.speak * (this.reducedMotion ? 0.002 : 0.012);
    motionScaleY *= 1 + this.speak * (this.reducedMotion ? 0.006 : 0.03);
    motionScaleX /= Math.sqrt(1 + this.speak * (this.reducedMotion ? 0.006 : 0.03));

    const pulse = this.reducedMotion ? 0 : params.pulse * Math.sin(now * 2.03);
    const trackingAmount = this.reducedMotion ? 0.35 : 1;
    const trackedX = this.trackX * trackingAmount;
    const trackedY = this.trackY * trackingAmount;

    return {
      time: now,
      bodyX: trackedX + motionX,
      bodyY: this.pose.bodyY + trackedY + motionY,
      scaleX: this.pose.scaleX * motionScaleX,
      scaleY: this.pose.scaleY * motionScaleY,
      tilt: this.pose.tilt + motionTilt - trackedX * 0.32,
      faceYaw: this.pose.faceYaw - trackedX * 0.16,
      facePitch: this.pose.facePitch,
      eyeHeight: this.pose.eyeHeight,
      eyeAsymmetry: this.pose.eyeAsymmetry,
      eyeColour: this.pose.eyeColour,
      eyeGain: this.pose.eyeGain * (1 + pulse) * (1 + this.attention * 0.06),
      smile: this.pose.smile,
      mouthOpen: this.speak * 0.86,
      bodyGain: this.pose.bodyGain * (1 + this.presence * 0.035),
      seen: this.presence,
      looking: this.attention,
      reducedMotion: this.reducedMotion,
    };
  }
}
