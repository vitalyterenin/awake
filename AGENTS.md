# Project conventions

Write interface text, documentation and comments in English.
Awake supports Apple Silicon (arm64) only, macOS 13 or later.
Keep one on/off switch and a motion delay choice of 1 or 5 minutes (default 5).
Circle radius and speed are fixed. Persist the chosen delay and reset its countdown
when it changes.
Never collect keystrokes, record input, add telemetry, or suppress user events.
Stop synthetic movement on real activity, session suspension or lost permission.
Run `bash scripts/test.sh` and `bash scripts/build-app.sh` before release.

Use the `app-release` skill and its refreshed shared publishing guide.
Keep app-specific release operations in `docs/releases.md`.
Publish only `apps/Awake.dmg` and `apps/feeds/awake.xml` from this repository.
