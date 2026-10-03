#!/usr/bin/env python3
"""Render the illustrated promotional teaser. Requires Pillow and ffmpeg."""
import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SCENES = [
    (5, "THE CONNECTION DETOUR", ["I wanted to", "debug my app."], ["I ended up debugging", "the connection."]),
    (5, "WHY I BUILT THIS", ["Wireless debugging", "was wearing", "me out."], ["I got tired of fighting the setup", "in Android Studio. So I built this."]),
    (6, "CONNECT ANDROID", ["Open. Scan.", "Connect."], ["QR pairing for wireless ADB.", "Verifies the device before calling it connected."]),
    (5, "BACK TO BUILDING", ["Your real phone.", "Your terminal.", "Your agent."], ["Close the helper. Keep using ADB.", "Agent control uses your configured Android tools."]),
    (5, "CONNECT ANDROID", ["Less pairing.", "More building."], ["Get the Mac app on GitHub.", "github.com/StoneHub/connect-android"]),
]


def font(size, bold=False):
    paths = [
        Path("/System/Library/Fonts/Supplemental") / ("Arial Bold.ttf" if bold else "Arial.ttf"),
        Path("/usr/share/fonts/truetype/dejavu") / ("DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"),
    ]
    for path in paths:
        if path.exists():
            return ImageFont.truetype(str(path), size)
    raise SystemExit("Install Arial or DejaVu Sans, or update the font paths in this script.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/media/connect-android-teaser.mp4")
    args = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required.")
    poster = ROOT / "docs/media/connect-android-ad-concept.png"
    if not poster.exists():
        raise SystemExit(f"Missing artwork: {poster}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="connect-android-teaser-") as temp:
        scratch = Path(temp)
        entries = ["ffconcat version 1.0"]
        for index, (duration, label, headline, body) in enumerate(SCENES):
            # These are new typography cards. The original illustration stays unchanged.
            card = Image.new("RGB", (1920, 1080), "#101714")
            draw = ImageDraw.Draw(card)
            draw.rounded_rectangle((100, 120, 165, 130), radius=5, fill="#78e58b")
            draw.text((100, 165), label, font=font(27, True), fill="#78e58b")
            y = 265
            for line in headline:
                draw.text((95, y), line, font=font(78, True), fill="#fff5df")
                y += 95
            y = max(640, y + 50)
            for line in body:
                draw.text((100, y), line, font=font(30), fill="#c1ccc3")
                y += 46
            draw.text((100, 930), "macOS 14+  /  Android 11+  /  Platform-Tools  /  Same local network", font=font(22), fill="#8b9c91")
            draw.text((100, 986), "ILLUSTRATED TEASER", font=font(19, True), fill="#8b9c91")
            for dot in range(len(SCENES)):
                x = 100 + dot * 35
                draw.ellipse((x, 865, x + 10, 875), fill="#78e58b" if dot == index else "#39473e")
            path = scratch / f"card-{index}.png"
            card.save(path)
            entries.extend([f"file '{path.name}'", f"duration {duration}"])
        entries.append(f"file 'card-{len(SCENES) - 1}.png'")
        timeline = scratch / "cards.ffconcat"
        timeline.write_text("\n".join(entries) + "\n")
        total = sum(scene[0] for scene in SCENES)
        filters = f"[0:v]fps=30[cards];[1:v]scale=760:760[art];[cards][art]overlay=1080:160,fade=t=in:st=0:d=0.4,fade=t=out:st={total - 0.5}:d=0.5,format=yuv420p[v]"
        subprocess.run([
            ffmpeg, "-hide_banner", "-loglevel", "warning", "-y",
            "-f", "concat", "-safe", "0", "-i", str(timeline),
            "-loop", "1", "-i", str(poster),
            "-filter_complex", filters, "-map", "[v]", "-t", str(total),
            "-r", "30", "-c:v", "libx264", "-preset", "medium", "-crf", "20",
            "-movflags", "+faststart", "-an", str(args.output),
        ], check=True)
    print(args.output)


if __name__ == "__main__":
    main()
