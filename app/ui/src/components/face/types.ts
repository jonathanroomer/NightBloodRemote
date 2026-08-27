/**
 * NightBlood face — canonical input contract.
 *
 * The face is a pure consumer of canonical state (engineering-spec 13.3/13.4).
 * It never invents, infers, or independently changes task, approval,
 * connection or speech state. Every input may be absent, stale or
 * disconnected; the resolver maps those cases truthfully (never to idle).
 */

/** Canonical visual states rendered by the face. */
export const VISUAL_STATES = [
  "offline",
  "starting",
  "idle",
  "listening",
  "transcribing",
  "routing",
  "voice_working",
  "thinking",
  "working",
  "speaking",
  "waiting_approval",
  "completed",
  "error",
  "event_gap",
  "degraded",
] as const;

export type VisualState = (typeof VISUAL_STATES)[number];

/** Layered state model of engineering-spec 13.3. */
export type ConnectionState =
  | "offline"
  | "starting"
  | "connected"
  | "fatal"
  | "unknown";

export type InteractionState =
  | "idle"
  | "listening"
  | "transcribing"
  | "routing"
  | "voice_working"
  | "thinking"
  | "speaking"
  | "unknown";

export interface WorkState {
  /** Number of active tasks; the badge value. */
  readonly activeTaskCount: number;
}

export interface ApprovalState {
  /** Unresolved formal approval requests. */
  readonly pendingCount: number;
}

export interface DegradationState {
  readonly degraded: boolean;
  /** Recovery is missing transient events (error code EVENT_GAP). */
  readonly eventGap: boolean;
  /** Exact written limitation shown by the UI when degraded. */
  readonly reasons: readonly string[];
}

/** Short-lived transient from a confirmed semantic event. */
export interface TransientState {
  readonly kind: "completed" | "error";
  /** Monotonic timestamp (ms) at which the transient was received. */
  readonly startedAtMs: number;
  /** Duration the transient remains dominant over idle. */
  readonly durationMs: number;
}

export interface CanonicalFaceInputs {
  /** Missing layers are treated as unknown, never as idle. */
  readonly connection?: ConnectionState | null;
  readonly interaction?: InteractionState | null;
  readonly work?: WorkState | null;
  readonly approval?: ApprovalState | null;
  readonly degradation?: DegradationState | null;
  readonly transient?: TransientState | null;
  /**
   * True when the feed is known stale (e.g. WebSocket silence beyond the
   * freshness window, snapshot refresh in flight). Stale truth is shown as
   * uncertainty (event_gap), never as idle.
   */
  readonly stale?: boolean;
  /** Monotonic clock (ms) used to expire transients. */
  readonly nowMs: number;
}

/** Resolver output: one dominant state plus truthful overlays. */
export interface ResolvedFace {
  readonly state: VisualState;
  /** Approval card stays visible/authoritative regardless of dominant state. */
  readonly approvalPending: boolean;
  /** Task badge stays visible while NightBlood converses. */
  readonly activeTaskCount: number;
  /** Face dims/constrains when degraded even in non-dominant states. */
  readonly degraded: boolean;
  readonly eventGap: boolean;
}
