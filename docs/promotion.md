# Connect Android video materials

The current promo was published publicly on October 3, 2026: **[Watch on YouTube](https://youtu.be/jyxFQRuv46U)**.

## Animated promo

[Watch or download the video](media/connect-android-teaser.mp4).

35 seconds, 1920 × 1080, 60 fps, H.264 video with AAC audio. This is the supplied animated promo, preserved byte for byte. It illustrates the pairing frustration, QR connection, and coding-agent workflow. Its UI and timings are illustrative. The README features an animated GIF preview that links to YouTube.

Preview source: [make-promo-preview.py](../scripts/make-promo-preview.py). Requires Python and ffmpeg. It regenerates only the GIF; it does not alter the supplied MP4. The prior typography renderer was removed so it cannot overwrite this video.

```sh
python3 scripts/make-promo-preview.py
```

## YouTube teaser

Title: **I Got Tired of Android Studio Wireless Pairing—So I Built Connect Android**

Description:

> I wanted to debug my app. I ended up debugging the connection.
>
> Connect Android is a small Mac app I built after getting frustrated with wireless debugging setup in Android Studio. Open it, scan a QR code from your phone's Wireless debugging settings, and let it pair, connect over ADB, and verify the device. Close the helper and keep working from your terminal.
>
> Once connected, agents with separately configured Android tools or MCP integrations can use the device through ADB. Connect Android handles the connection step.
>
> This animated promo illustrates the pairing and agent workflow. The UI and timings are illustrative. A recorded real-device walkthrough is planned.
>
> Source and downloads: https://github.com/StoneHub/connect-android
>
> Requirements: macOS 14+, Android 11+, Android SDK Platform-Tools, and the same local network. Check the latest release notes for signing, notarization, and installation details.

The teaser is stored in this repository. The description above is reusable promotional copy; the published video includes the source, current release link, requirements, and a note that a real-device walkthrough is planned.

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
