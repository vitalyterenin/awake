# Project conventions

Write interface text, documentation and comments in English.
Awake supports Apple Silicon (arm64) only, macOS 13 or later.
Keep one behavior switch. Idle delay, circle radius and speed are fixed.
Never collect keystrokes, record input, add telemetry, or suppress user events.
Stop synthetic movement on real activity, session suspension or lost permission.
Run `bash scripts/test.sh` and `bash scripts/build-app.sh` before release.

Use the `app-release` skill and its refreshed shared publishing guide.
Keep app-specific release operations in `docs/releases.md`.
Publish only `apps/Awake.dmg` and `apps/feeds/awake.xml` from this repository.
