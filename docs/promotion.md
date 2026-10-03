# Connect Android video materials

## Typography teaser

[Watch or download the video](media/connect-android-teaser.mp4).

26 seconds, 1920 × 1080, 30 fps, H.264 MP4 with fast start. Silent, with all messaging on screen. It uses text cards; it does not show a measured pairing time or real device interaction. The README features an animated GIF preview that links to the full MP4.

Render source: [render-teaser.py](../scripts/render-teaser.py). Requires Python with Pillow, ffmpeg with libx264, and Arial or DejaVu Sans fonts. Rendering creates both the MP4 and GIF without external artwork.

```sh
python3 scripts/render-teaser.py
```

## YouTube teaser upload draft

Title: **I Got Tired of Android Studio Wireless Pairing, So I Built This**

Description:

> I wanted to debug my app. I ended up debugging the connection.
>
> Connect Android is a small Mac app I built after getting frustrated with wireless debugging setup in Android Studio. Open it, scan a QR code from your phone's Wireless debugging settings, and let it pair, connect over ADB, and verify the device. Close the helper and keep working from your terminal.
>
> Once connected, agents with separately configured Android tools or MCP integrations can use the device through ADB. Connect Android handles the connection step.
>
> This is a short teaser. A real-device walkthrough is planned.
>
> Source and downloads: https://github.com/StoneHub/connect-android
>
> Requirements: macOS 14+, Android 11+, Android SDK Platform-Tools, and the same local network. Check the latest release notes for signing, notarization, and installation details.

The teaser is stored in this repository. The copy above is the YouTube upload draft.

## Real-device walkthrough plan

Working title: **Connect Your Android Phone to Your Coding Agent with a QR Code**

Target length: about two minutes, with actual screen and phone footage.

| Segment | Show | Explain |
| --- | --- | --- |
| Origin | Presenter or sample development project | “I got tired of fighting wireless debugging setup in Android Studio, so I built this.” |
| Prerequisites | Platform-Tools installed, Mac and Android phone ready | macOS 14+, Android 11+, same local network, Wireless debugging enabled. |
| Connection | Open Connect Android, scan a fresh QR, wait for verified connection | Pairing and debugging use separate endpoints; the app handles both and checks the device shell. |
| Terminal proof | Close helper; run `adb devices -l` and a bounded command | ADB remains available after the helper closes. |
| Agent proof | Show the exact Android tool/MCP configuration; agent captures a screenshot and taps a harmless sample-app control | The agent tools provide device control. Document installation and configuration so viewers can reproduce it. |
| End card | Repository and release link | Invite developers to try it and report setup friction. |

Record the real sequence. Label cuts and accelerated waits. Use a sample app and exclude pairing secrets, private notifications, and personal app data. Keep the exact agent setup instructions alongside the completed walkthrough.

## Review before upload

- Watch the teaser for text readability and pacing.
- Check that the repository and current download links work.
- For the walkthrough, confirm fresh pairing, device identity, and visible agent interaction were recorded.
- Review the exact video, title, description, channel, and visibility before uploading.
