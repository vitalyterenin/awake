# Project conventions

Write interface text, documentation and comments in English.
Awake supports Apple Silicon (arm64) only, macOS 13 or later.
Keep one on/off switch and a motion delay choice of 1 or 5 minutes (default 5).
Circle radius and speed are fixed. Persist the chosen delay and reset its countdown
when it changes. Keep native screen dimming and battery operation as separate,
persisted opt-ins, both off by default. Restore the captured brightness on input,
pause, disable and normal quit, and retain a recovery value until restoration succeeds.
Never collect keystrokes, record input, add telemetry, or suppress user events.
Stop synthetic movement on real activity, session suspension or lost permission.
Use standard AppKit styling and controls; no custom-drawn interface, cards, fonts,
colors or button/window dimensions. Missing cursor control must open the setup dialog and leave a visible warning in
the menu bar until resolved. Never imply Awake is working while access is blocked.
Run `bash scripts/test.sh` and `bash scripts/build-app.sh` before release.

Use the `app-release` skill and its refreshed shared publishing guide.
Keep app-specific release operations in `docs/releases.md`.
Publish only `apps/Awake.dmg` and `apps/feeds/awake.xml` from this repository.
