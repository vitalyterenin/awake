# Awake

Awake keeps your Mac awake from the macOS menu bar. After one or five minutes
without activity, the cursor moves in a small circle. Move the mouse, scroll,
click or type to stop the motion and restart the countdown.

**Apple Silicon only · macOS 13 or later**

## Install

1. Download [Awake.dmg](https://teren.in/apps/Awake.dmg), drag Awake to
   Applications, eject the disk image, and open the installed app.
2. The app is ad hoc signed and is not notarized. If macOS blocks its first launch,
   use **System Settings → Privacy & Security → Open Anyway**.
3. Allow Awake in **Privacy & Security → Accessibility**, called **Device Control
   and Data Access** on newer macOS versions. The setup dialog links to this pane.

Until cursor control is allowed, Awake does not prevent sleep or move the cursor.
The setup dialog opens on each launch with missing permission. A warning triangle
and the name **Awake** replace the coffee cup in the menu bar; closing the dialog
leaves the warning visible. **Finish Setup…** reopens it. The dialog updates
automatically after access is granted. **Permissions…** opens it when access is ready.

If the switch is on but Awake is still blocked after an update, macOS may have
kept permission for the previous copy. Remove only Awake from that list with
**−**, then add the installed `Awake.app` with **+**. The setup dialog's standard
help button explains this recovery. Input detection failures have a separate
paused message and recovery instructions; no additional permission is requested.

## Use

Open the coffee cup in the menu bar:

| Control | Behavior and default |
| --- | --- |
| **Keep Mac awake** | On/off switch, on by default. Requires cursor control and an allowed power source. |
| **Start cursor motion after** | Choose **1 minute** or **5 minutes**; default 5. Changing it starts a fresh countdown. |
| **Dim display while idle** | Off by default. Dim supported displays when cursor motion starts. |
| **Allow on battery power** | Off by default. Enable to keep Awake running on battery. |

These choices persist between launches. The menu shows whether Awake is keeping
the Mac awake, counting down, moving the cursor or paused. All interface controls,
menus, setup/help dialogs and About panel use standard AppKit components and system
styling.

Cursor motion follows the display refresh rate on macOS 14+, with a 60 Hz fallback
on macOS 13. The circle has a fixed 12-point radius and takes four seconds per turn.
At display edges the cursor eases into a full circle within that display. Awake
does not click, drag or type.

With **Dim display while idle**, the native system brightness slider lowers to
1/16 (about 6%) over five seconds. Input restores the captured level over half a
second, including if dimming was still in progress. Both directions use an eased
cubic Bézier curve. An already darker display stays unchanged. This option works
only with displays supporting native brightness control; it does not use an overlay.
Turning the option or Awake off, pausing, or quitting restores brightness as well.
Normal quit and session suspension restore immediately. If forced termination
interrupts dimming, the next launch recovers saved levels. A disconnected display
keeps its recovery value until it can be restored.

With battery use disabled, Awake pauses on battery, restores brightness and allows
normal idle sleep. Connecting power starts a fresh countdown. Unknown power sources
also pause the app.

While enabled with permission, working activity detection and an allowed power
source, Awake prevents idle display and system sleep, including during the countdown.
Choosing Sleep, closing the lid or a low battery can still put the Mac to sleep.
Awake pauses during locked or inactive sessions and restarts the countdown on return.
It does not change sleep settings, disable screen locking or start at login.

## Updates and removal

The **Updates** submenu contains **Check for Updates…**, **Check automatically**
and **Install automatically**. Automatic checks and installation default to on,
with checks every four hours while Awake runs. Saved preferences are respected;
installation can wait for quit or permission. Both the update feed and downloaded
DMG are authenticated with Sparkle signatures before installation.

To remove Awake, choose **Quit Awake**, then move it from Applications to Trash.
Quitting restores brightness and normal idle sleep behavior.

## Privacy and support

Awake has no telemetry and never records input or reads typed characters. Activity
is used only to reset the in-memory countdown; events are returned unchanged.
Network requests are limited to Sparkle updates from `teren.in`; system profiling
is disabled.

Maintained by [Vitaly Terenin](https://teren.in/). Contact the maintainer through
that page. Source access holders can also report problems in the
[repository's issues](https://github.com/vitalyterenin/awake/issues).
The source repository is private; no open-source license has been assigned.

## Build and release

From the repository root on an Apple Silicon Mac with Swift 6+ and Command Line Tools:

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

Output: `~/Library/Developer/Awake/Awake.app`.
See [release operations](docs/releases.md) for runtime checks, publication tests,
signing and the CI release process.
