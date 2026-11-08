# Awake

A macOS menu bar app that prevents idle sleep. After one or five minutes without
mouse or keyboard activity, the cursor slowly moves in a small circle. Move the
mouse, scroll, click or type to stop the motion.

**Apple Silicon only · macOS 13 or later**

## Install and update

Download **[Awake.dmg](https://teren.in/apps/Awake.dmg)**, drag Awake to Applications,
eject the image, then open the installed app. Current builds are ad hoc signed
and not notarized. If macOS blocks its first launch, approve the installed app
with **System Settings → Privacy & Security → Open Anyway**.

Allow Awake in **System Settings → Privacy & Security → Accessibility**. Until
permission is granted, Awake shows a permission reminder and does not prevent sleep
or move the cursor. **Allow Accessibility…** in its menu opens the relevant settings.

Signed Sparkle updates use a permanent feed and download URL. Scheduled checks and
automatic installation are enabled by default, with checks every four hours while
Awake runs. The **Updates** submenu offers **Check for Updates…**, **Check
automatically**, and **Install automatically**. Installation may wait for quit or
permission. These preferences persist between launches.

To remove Awake, choose **Quit Awake** and move the app from Applications to Trash.

## Use

The sun icon in the menu bar has an on/off switch: **Keep Mac awake**. It defaults
to on and remembers your choice between launches. **Start cursor motion after**
lets you choose **1 minute** or **5 minutes** (the default). The delay also persists
between launches. Changing it stops any current motion and starts a fresh countdown.
The menu shows the current state and the countdown until cursor movement.

The nominal circle radius is six points and each
turn takes 24 seconds. Near screen edges the path is adjusted and clipped to stay
on the current display, without an initial jump. Move, scroll, click or type to
stop movement and restart the countdown. Awake does not click, drag or type.

While enabled with Accessibility permission and working input monitoring, a macOS
power assertion prevents idle display and system sleep, including during the
idle countdown. Choosing Sleep, closing the lid or a low battery can still
put the Mac to sleep. Awake pauses during inactive/locked sessions and starts a
fresh countdown on return. It does not disable macOS screen locking.

Turning it off or quitting releases the assertion and restores normal idle sleep.
Awake does not change your sleep settings or start at login. If permission is
revoked or monitoring fails, it pauses and shows the problem in the menu. Restore
Accessibility permission or reopen Awake to retry.

## Privacy and help

There is no telemetry. Awake never records input, reads typed characters, or
transmits mouse/keyboard activity. Input events are observed only to reset the
in-memory countdown and are returned unchanged. Network requests are limited to
Sparkle update checks/downloads from `teren.in`; system profiling is disabled.

Maintained by [Vitaly Terenin](https://teren.in/). Source access holders can report
problems in the [private repository's issues](https://github.com/vitalyterenin/awake/issues).
The source repository is private; no open-source license has been assigned.

## Build

From the repository root on an Apple Silicon Mac with Swift 6+ and Command Line Tools:

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

Output: `~/Library/Developer/Awake/Awake.app`.
See [release operations](docs/releases.md) for signing, CI and publication.
