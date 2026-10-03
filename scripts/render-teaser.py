#!/usr/bin/env python3
"""Render the typography teaser and README preview. Requires Pillow and ffmpeg."""
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
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="connect-android-teaser-") as temp:
        scratch = Path(temp)
        entries = ["ffconcat version 1.0"]
        for index, (duration, label, headline, body) in enumerate(SCENES):
            card = Image.new("RGB", (1920, 1080), "#101714")
            draw = ImageDraw.Draw(card)
            draw.rounded_rectangle((140, 110, 230, 122), radius=6, fill="#78e58b")
            draw.text((140, 158), label, font=font(30, True), fill="#78e58b")
            draw.text((1780, 158), "CONNECT ANDROID", anchor="ra", font=font(30, True), fill="#8b9c91")
            y = 265
            for line in headline:
                draw.text((135, y), line, font=font(108, True), fill="#fff5df")
                y += 125
            y = max(665, y + 40)
            for line in body:
                draw.text((140, y), line, font=font(38), fill="#c1ccc3")
                y += 55
            draw.text((140, 930), "macOS 14+  /  Android 11+  /  Platform-Tools  /  Same local network", font=font(26), fill="#8b9c91")
            draw.text((140, 986), "WIRELESS ADB PAIRING FOR MACOS", font=font(20, True), fill="#8b9c91")
            for dot in range(len(SCENES)):
                x = 140 + dot * 40
                draw.ellipse((x, 865, x + 12, 877), fill="#78e58b" if dot == index else "#39473e")
            path = scratch / f"card-{index}.png"
            card.save(path)
            entries.extend([f"file '{path.name}'", f"duration {duration}"])
        entries.append(f"file 'card-{len(SCENES) - 1}.png'")
        timeline = scratch / "cards.ffconcat"
        timeline.write_text("\n".join(entries) + "\n")
        total = sum(scene[0] for scene in SCENES)
        filters = f"fps=30,fade=t=in:st=0:d=0.4,fade=t=out:st={total - 0.5}:d=0.5,format=yuv420p"
        subprocess.run([
            ffmpeg, "-hide_banner", "-loglevel", "warning", "-y",
            "-f", "concat", "-safe", "0", "-i", str(timeline),
            "-vf", filters, "-t", str(total),
            "-r", "30", "-c:v", "libx264", "-preset", "medium", "-crf", "20",
            "-movflags", "+faststart", "-an", str(args.output),
        ], check=True)
        preview = args.output.with_suffix(".gif")
        subprocess.run([
            ffmpeg, "-hide_banner", "-loglevel", "warning", "-y", "-i", str(args.output),
            "-filter_complex", "fps=8,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=bayer",
            "-loop", "0", str(preview),
        ], check=True)
    print(args.output)
    print(preview)


if __name__ == "__main__":
    main()
