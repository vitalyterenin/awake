# Awake

A small macOS menu bar app that keeps your Mac awake. After five minutes without
mouse or keyboard activity, the cursor slowly moves in a small circle. Move the
mouse, scroll, click or type and movement stops immediately.

**Apple Silicon only · macOS 13 or later**

## Use

Open Awake and allow it in **System Settings → Privacy & Security → Accessibility**.
The sun icon in the menu bar has one behavior switch: **Keep Mac awake**.
The idle delay is five minutes; the circle has a six-point radius and takes
24 seconds per turn. Motion stays on the current display, including at its edges.
Awake does not click, drag or type. It never records or transmits your input.

While enabled with permission granted, a macOS power assertion prevents idle
display and system sleep, including during the five-minute countdown. Choosing
Sleep, closing the lid or a low battery can still put the Mac to sleep. Awake
pauses during inactive/locked sessions and starts a fresh countdown on return.
Turning it off or quitting releases the assertion and restores normal idle sleep.
It does not change your sleep settings or start at login.

## Install and update

Download **[Awake.dmg](https://teren.in/apps/Awake.dmg)**, drag Awake to Applications,
eject the image, then open the installed app. The initial build is ad hoc signed
and is not notarized. If macOS blocks its first launch, approve the installed app
with **System Settings → Privacy & Security → Open Anyway**.

Signed Sparkle updates use a permanent feed and download URL. Scheduled checks and
automatic installation are enabled by default. The **Updates** submenu offers a
manual check and controls for both update preferences.

There is no telemetry. Network requests are limited to update checks/downloads.

## Build

On an Apple Silicon Mac with Swift 6+ and Command Line Tools:

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

Output: `~/Library/Developer/Awake/Awake.app`.
See [release operations](docs/releases.md) for signing, CI and publication.
