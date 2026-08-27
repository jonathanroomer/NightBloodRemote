"""Fourteen-state visual parameters in the minimal hero language:
strong eyes + subtle background motion.

Every state is eye behaviour plus background-motion character. Mapping is
traceable to the motion-vocabulary sheet and engineering-spec 13.4, seeded
from the face spec 8.3 matrix but reinterpreted for the minimal look:

- aperture/gaze/brightness carry attention and readiness;
- drift radius/speed carry energy;
- restrained violet near the core carries thinking/working energy;
- deep red exists ONLY in error; fragmentation only in event_gap/error;
- speaking adds the embedded ivory waveform below the eyes (the approved
  mouth-equivalent from the reference sheet);
- offline/degraded/event_gap are dimmed/constrained/uncertain and must
  never read as idle.
"""

from __future__ import annotations

STATE_PARAMS: dict[str, dict] = {
    "offline": dict(
        aperture=0.07, eye_gain=0.14, gaze=(0.0, -0.3), blink="none",
        drift_radius=0.05, drift_loops=0.25, noise_contrast=0.8,
        backdrop_gain=0.45, violet=0.0, red=0.0, waveform=0.0,
    ),
    "starting": dict(
        aperture=0.30, eye_gain=0.45, gaze=(0.0, 0.0), blink="slow",
        drift_radius=0.18, drift_loops=0.6, noise_contrast=0.9,
        backdrop_gain=0.7, violet=0.15, red=0.0, waveform=0.0,
    ),
    "idle": dict(
        aperture=0.55, eye_gain=1.0, gaze=(0.0, 0.0), blink="natural",
        drift_radius=0.35, drift_loops=1.0, noise_contrast=1.0,
        backdrop_gain=1.0, violet=0.0, red=0.0, waveform=0.0,
    ),
    "listening": dict(
        aperture=0.72, eye_gain=1.15, gaze=(0.0, 0.05), blink="sparse",
        drift_radius=0.45, drift_loops=1.4, noise_contrast=1.05,
        backdrop_gain=1.1, violet=0.1, red=0.0, waveform=0.0,
    ),
    "transcribing": dict(
        aperture=0.60, eye_gain=1.0, gaze=(0.0, -0.05), blink="sparse",
        drift_radius=0.28, drift_loops=1.2, noise_contrast=1.0,
        backdrop_gain=1.0, violet=0.1, red=0.0, waveform=0.0,
    ),
    "routing": dict(
        aperture=0.60, eye_gain=1.05, gaze=(0.35, 0.0), blink="none",
        drift_radius=0.55, drift_loops=1.8, noise_contrast=1.1,
        backdrop_gain=1.05, violet=0.2, red=0.0, waveform=0.0,
    ),
    "thinking": dict(
        aperture=0.50, eye_gain=1.05, gaze=(0.0, 0.12), blink="none",
        drift_radius=0.25, drift_loops=1.6, noise_contrast=1.15,
        backdrop_gain=1.0, violet=0.45, red=0.0, waveform=0.0,
    ),
    "working": dict(
        aperture=0.60, eye_gain=1.05, gaze=(0.0, 0.0), blink="sparse",
        drift_radius=0.55, drift_loops=2.2, noise_contrast=1.2,
        backdrop_gain=1.1, violet=0.35, red=0.0, waveform=0.0,
    ),
    "speaking": dict(
        aperture=0.62, eye_gain=1.1, gaze=(0.0, 0.0), blink="sparse",
        drift_radius=0.40, drift_loops=1.4, noise_contrast=1.05,
        backdrop_gain=1.05, violet=0.15, red=0.0, waveform=1.0,
    ),
    "waiting_approval": dict(
        aperture=0.78, eye_gain=1.2, gaze=(0.0, 0.0), blink="suppressed",
        drift_radius=0.06, drift_loops=0.3, noise_contrast=0.95,
        backdrop_gain=0.95, violet=0.2, red=0.0, waveform=0.0,
    ),
    "completed": dict(
        aperture=0.60, eye_gain=1.05, gaze=(0.0, -0.03), blink="natural",
        drift_radius=0.30, drift_loops=0.9, noise_contrast=0.95,
        backdrop_gain=1.0, violet=0.15, red=0.0, waveform=0.0,
    ),
    "error": dict(
        aperture=0.50, eye_gain=0.9, gaze=(0.0, -0.08), blink="sparse",
        drift_radius=0.30, drift_loops=1.3, noise_contrast=1.5,
        backdrop_gain=0.9, violet=0.0, red=0.5, waveform=0.0,
    ),
    "event_gap": dict(
        aperture=0.50, eye_gain=0.75, gaze=(0.0, 0.0), blink="sparse",
        drift_radius=0.35, drift_loops=1.1, noise_contrast=1.6,
        backdrop_gain=0.8, violet=0.1, red=0.0, waveform=0.0,
    ),
    "degraded": dict(
        aperture=0.50, eye_gain=0.6, gaze=(0.0, -0.05), blink="natural",
        drift_radius=0.15, drift_loops=0.6, noise_contrast=0.85,
        backdrop_gain=0.65, violet=0.1, red=0.0, waveform=0.0,
    ),
}

# Backdrop tint anchors (linear RGB, applied at backdrop_gain=1, on the
# 1-3% luminance band).
BACKDROP_BASE = (0.0085, 0.0080, 0.0105)
BACKDROP_VIOLET = (0.0095, 0.0070, 0.0165)
BACKDROP_RED = (0.0135, 0.0038, 0.0040)


def backdrop_colour(params: dict) -> tuple[float, float, float]:
    v, r, g = params["violet"], params["red"], params["backdrop_gain"]
    base = BACKDROP_BASE
    col = [
        base[i] + (BACKDROP_VIOLET[i] - base[i]) * v + (BACKDROP_RED[i] - base[i]) * r
        for i in range(3)
    ]
    return (col[0] * g, col[1] * g, col[2] * g)
