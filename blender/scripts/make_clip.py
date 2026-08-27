#!/usr/bin/env python3
"""Encode a rendered PNG sequence into a review clip (and optional 3x soak).

Plain Python (no bpy). Examples:

  python3 blender/scripts/make_clip.py \
      --seq blender/renders/study_viscous/clip_ --start 151 --count 280 \
      --out blender/renders/study_viscous/study_viscous.mp4

  # soak test: the loop concatenated three times for seam review
  python3 blender/scripts/make_clip.py --seq ... --start 0 --count 300 \
      --out loop_soak.mp4 --repeat 3

Encoder settings are pinned here so every review clip is comparable:
H.264 yuv420p CRF 16 preset slow, 30 fps.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

FPS = 30


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seq", required=True, help="frame path prefix (before the number)")
    ap.add_argument("--start", type=int, required=True)
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--digits", type=int, default=4)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repeat", type=int, default=1, help="concatenate the range N times (soak)")
    args = ap.parse_args()

    seq = Path(args.seq)
    pattern = f"{seq.name}%0{args.digits}d.png"
    first = seq.parent / (f"{seq.name}{args.start:0{args.digits}d}.png")
    if not first.exists():
        sys.exit(f"missing first frame: {first}")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    if args.repeat == 1:
        cmd = [
            "ffmpeg", "-y", "-framerate", str(FPS),
            "-start_number", str(args.start),
            "-i", str(seq.parent / pattern),
            "-frames:v", str(args.count),
            "-c:v", "libx264", "-preset", "slow", "-crf", "16",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart",
            str(out),
        ]
        subprocess.run(cmd, check=True)
    else:
        # Encode once losslessly, then concat-demux N repeats and re-encode.
        tmp = out.with_suffix(".once.mp4")
        subprocess.run(
            [
                "ffmpeg", "-y", "-framerate", str(FPS),
                "-start_number", str(args.start),
                "-i", str(seq.parent / pattern),
                "-frames:v", str(args.count),
                "-c:v", "libx264", "-preset", "veryfast", "-qp", "0",
                "-pix_fmt", "yuv444p", str(tmp),
            ],
            check=True,
        )
        lst = out.with_suffix(".concat.txt")
        lst.write_text("".join(f"file '{tmp.resolve()}'\n" for _ in range(args.repeat)))
        subprocess.run(
            [
                "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                "-c:v", "libx264", "-preset", "slow", "-crf", "16",
                "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out),
            ],
            check=True,
        )
        tmp.unlink()
        lst.unlink()
    print(f"[make_clip] wrote {out}")


if __name__ == "__main__":
    main()
