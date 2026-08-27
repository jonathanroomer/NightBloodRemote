"""Seamless-loop assembly and seam verification.

Technique (face spec 6.4): render loop_len + overlap frames; the loop's first
`overlap` frames are a crossfade from the tail continuation into the head:

    out[j] = mix(src[loop_len + j], src[j], j / (overlap - 1))   for j < overlap
    out[j] = src[j]                                              otherwise

Continuity: out[loop_len-1] = src[loop_len-1] and next iteration begins at
out[0] = src[loop_len], the natural continuation frame, so the seam falls
inside the crossfade window instead of between two unrelated frames.

Also provides a frame-difference seam check used by the soak test.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import bpy
import numpy as np


def _load_pixels(path: Path) -> np.ndarray:
    img = bpy.data.images.load(str(path), check_existing=False)
    w, h = img.size
    arr = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(arr)
    bpy.data.images.remove(img)
    return arr.reshape(h, w, 4)


def _save_pixels(arr: np.ndarray, path: Path, file_format: str) -> None:
    h, w = arr.shape[:2]
    is_float = file_format.startswith("OPEN_EXR")
    img = bpy.data.images.new("nb_loop_tmp", width=w, height=h, alpha=True, float_buffer=is_float)
    img.pixels.foreach_set(arr.astype(np.float32).ravel())
    img.file_format = file_format
    img.filepath_raw = str(path)
    img.save()
    bpy.data.images.remove(img)


def assemble_crossfade_loop(
    src_dir: Path,
    prefix: str,
    first_frame: int,
    loop_len: int,
    overlap: int,
    out_dir: Path,
    ext: str = "png",
) -> dict:
    """Build the looped sequence from rendered frames.

    Source frames named {prefix}{frame:04d}.{ext}, frames
    [first_frame, first_frame + loop_len + overlap - 1] must exist.
    Output frames are written as {prefix}loop_{j:04d}.{ext}, j in [0, loop_len).
    """
    src_dir, out_dir = Path(src_dir), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    fmt = "OPEN_EXR" if ext == "exr" else "PNG"

    def src_path(offset: int) -> Path:
        return src_dir / f"{prefix}{first_frame + offset:04d}.{ext}"

    for j in range(loop_len):
        dst = out_dir / f"{prefix}loop_{j:04d}.{ext}"
        if j < overlap:
            alpha = j / max(1, overlap - 1)
            tail = _load_pixels(src_path(loop_len + j))
            head = _load_pixels(src_path(j))
            _save_pixels(tail * (1.0 - alpha) + head * alpha, dst, fmt)
        else:
            shutil.copyfile(src_path(j), dst)

    report = seam_check(out_dir, f"{prefix}loop_", 0, loop_len, ext)
    report_path = out_dir / "loop_report.json"
    report.update(
        {
            "src_dir": str(src_dir),
            "prefix": prefix,
            "first_frame": first_frame,
            "loop_len": loop_len,
            "overlap": overlap,
        }
    )
    with open(report_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    return report


def seam_check(seq_dir: Path, prefix: str, first: int, count: int, ext: str = "png") -> dict:
    """Compare the wrap-around frame difference to typical in-sequence motion.

    seam_ratio ~ 1.0 means the loop boundary moves no more than a typical
    frame step; > 2.0 is a visible pop and fails the gate.
    """
    seq_dir = Path(seq_dir)

    def load(i: int) -> np.ndarray:
        return _load_pixels(seq_dir / f"{prefix}{first + i:04d}.{ext}")

    diffs = []
    stride = max(1, count // 24)  # sample up to ~24 interior steps
    prev = load(0)
    sampled = [0]
    for i in range(stride, count, stride):
        cur = load(i)
        diffs.append(float(np.mean(np.abs(cur - prev))))
        prev = cur
        sampled.append(i)
    last = load(count - 1)
    head = load(0)
    seam = float(np.mean(np.abs(head - last)))
    typical = float(np.median(diffs)) if diffs else 0.0
    # Interior samples are `stride` frames apart; scale to a per-frame step.
    typical_per_frame = typical / stride if stride else typical
    ratio = seam / typical_per_frame if typical_per_frame > 1e-8 else float("inf")
    return {
        "seam_mean_abs_diff": seam,
        "typical_per_frame_diff": typical_per_frame,
        "seam_ratio": ratio,
        "interior_samples": len(diffs),
        "passes": bool(ratio < 2.0),
    }
