#!/usr/bin/env python3
"""Generate the README preview from the supplied promo without changing the MP4."""
import shutil
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg:
    raise SystemExit("ffmpeg is required.")
video = root / "docs/media/connect-android-teaser.mp4"
preview = video.with_suffix(".gif")
subprocess.run([
    ffmpeg, "-hide_banner", "-loglevel", "warning", "-y", "-i", str(video),
    "-filter_complex", "fps=8,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer",
    "-loop", "0", str(preview),
], check=True)
print(preview)
