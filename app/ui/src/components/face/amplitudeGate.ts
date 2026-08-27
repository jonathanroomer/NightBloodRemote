/**
 * Authorised-amplitude tracking per engineering-spec 14.6.
 *
 * All remote audio routes through a Web Audio GainNode whose gain is zero
 * except while an authorised speech job is active. The face NEVER animates
 * speech from timers, model state or unauthorised audio: it follows this
 * tracker, which follows the gate. Amplitude samples are accepted only when
 * they carry the active authorised speech_job_id while the gate is open.
 * Interruption or job end zeroes output immediately.
 */

export interface AmplitudeGateState {
  readonly activeJobId: string | null;
  readonly gateOpen: boolean;
  readonly amplitude: number;
}

const SMOOTHING_ATTACK = 0.55; // fast rise so speech onsets read immediately
const SMOOTHING_RELEASE = 0.25; // slightly slower settle; still sub-100 ms

export class AuthorisedAmplitudeTracker {
  private activeJobId: string | null = null;
  private gateOpen = false;
  private smoothed = 0;

  /** speech_job_state message: a job became active. */
  jobStarted(speechJobId: string): void {
    this.activeJobId = speechJobId;
    // The gate message authorises audio separately; starting a job does not
    // by itself open the gate.
    this.smoothed = 0;
  }

  /** speech_job_state message: ended, cancelled or interrupted. */
  jobEnded(speechJobId: string): void {
    if (this.activeJobId === speechJobId) {
      this.activeJobId = null;
      this.gateOpen = false;
      this.smoothed = 0; // interruption kills motion immediately
    }
  }

  /** audio_gate message from the bridge, tied to a job id. */
  gateChanged(open: boolean, speechJobId: string | null): void {
    if (open && speechJobId !== null && speechJobId === this.activeJobId) {
      this.gateOpen = true;
    } else {
      this.gateOpen = false;
      this.smoothed = 0;
    }
  }

  /**
   * output_amplitude telemetry. Samples not carrying the active authorised
   * job id while the gate is open are discarded: rogue audio produces zero
   * face motion (the gain gate keeps it silent; the face follows the gate,
   * not the speaker).
   */
  amplitudeSample(speechJobId: string, value: number): void {
    if (!this.gateOpen || this.activeJobId === null || speechJobId !== this.activeJobId) {
      return;
    }
    const v = Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
    const k = v > this.smoothed ? SMOOTHING_ATTACK : SMOOTHING_RELEASE;
    this.smoothed += (v - this.smoothed) * k;
  }

  /** Bridge reconnect/reload: no claim survives without canonical truth. */
  reset(): void {
    this.activeJobId = null;
    this.gateOpen = false;
    this.smoothed = 0;
  }

  get state(): AmplitudeGateState {
    return {
      activeJobId: this.activeJobId,
      gateOpen: this.gateOpen,
      amplitude: this.gateOpen && this.activeJobId !== null ? this.smoothed : 0,
    };
  }

  /** The only value the face may use for speech-driven displacement. */
  get amplitude(): number {
    return this.state.amplitude;
  }
}
