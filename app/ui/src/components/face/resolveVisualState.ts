/**
 * Dominant-state resolution per engineering-spec 13.3:
 *
 *   1. offline/fatal; 2. pending approval; 3. user speaking/listening;
 *   4. NightBlood speaking; 5. routing/coordinator thinking; 6. active work;
 *   7. completion/error transient; 8. idle.
 *
 * Binding invariants (face spec section 2):
 * - Never represent unloaded, stale, disconnected or unknown state as idle.
 * - The face does not infer state; it renders what canonical state says.
 * - offline/degraded/event_gap must read as themselves, never as idle.
 */

import type { CanonicalFaceInputs, ResolvedFace, VisualState } from "./types";

function transientActive(inputs: CanonicalFaceInputs): "completed" | "error" | null {
  const t = inputs.transient;
  if (!t) return null;
  const elapsed = inputs.nowMs - t.startedAtMs;
  if (elapsed < 0 || elapsed >= t.durationMs) return null;
  return t.kind;
}

export function resolveVisualState(inputs: CanonicalFaceInputs): ResolvedFace {
  const connection = inputs.connection ?? "unknown";
  const interaction = inputs.interaction ?? "unknown";
  const approvalPending = (inputs.approval?.pendingCount ?? 0) > 0;
  const activeTaskCount = inputs.work?.activeTaskCount ?? 0;
  const degraded = inputs.degradation?.degraded ?? false;
  const eventGap = (inputs.degradation?.eventGap ?? false) || (inputs.stale ?? false);

  const overlays = { approvalPending, activeTaskCount, degraded, eventGap };

  const state = ((): VisualState => {
    // 1. Connection dominates everything: an unreachable bridge means no
    // canonical truth exists, so nothing else may be shown.
    if (connection === "offline" || connection === "fatal" || connection === "unknown") {
      return "offline";
    }
    if (connection === "starting") return "starting";

    // 2. Pending approval: arrested watchfulness while the card is actionable.
    if (approvalPending) return "waiting_approval";

    // 3-5. Interaction layer.
    if (interaction === "listening") return "listening";
    if (interaction === "transcribing") return "transcribing";
    if (interaction === "speaking") return "speaking";
    if (interaction === "routing") return "routing";
    if (interaction === "voice_working") return "voice_working";
    if (interaction === "thinking") return "thinking";

    // 6. Active work.
    if (activeTaskCount > 0) return "working";

    // 7. Confirmed transients.
    const transient = transientActive(inputs);
    if (transient) return transient;

    // Uncertain or constrained truth is itself the state, never idle.
    if (eventGap) return "event_gap";
    if (interaction === "unknown") return "event_gap";
    if (degraded) return "degraded";

    // 8. Idle: only a connected bridge with known-quiet state earns it.
    return "idle";
  })();

  return { state, ...overlays };
}
