# Project conventions

Write interface text, documentation and comments in English.
Write GitHub descriptions, commits, PRs and release notes in English as well.
Describe functions, requirements and usage concisely, without advertising or slogans.
Keep in-app message explanations to one short action; put recovery details behind help.
Awake supports Apple Silicon (arm64) only, macOS 13 or later.
Keep one on/off switch and a motion delay choice of 1 or 5 minutes (default 5).
Circle radius and speed are fixed. Persist the chosen delay and reset its countdown
when it changes. Keep native screen dimming and battery operation as separate,
persisted opt-ins, both off by default. Restore the captured brightness on input,
pause, disable and normal quit, and retain a recovery value until restoration succeeds.
Never collect keystrokes, record input, add telemetry, or suppress user events.
Stop synthetic movement on real activity, session suspension or lost permission.
Use standard AppKit styling and controls; no custom-drawn interface, cards, fonts,
colors or fixed button/window dimensions. Size content intrinsically and use semantic
system fonts. Missing cursor control must open the setup window and leave a visible warning in
the menu bar until resolved. Never imply Awake is working while access is blocked.
Verify real rendered UI and actual window dismissal; accessibility text alone is
insufficient. Never display NSAlert.window as a modeless window.
Run `bash scripts/test.sh` and `bash scripts/build-app.sh` before release.

Release apps and every updater component must use the persistent certificate in
Resources/ReleaseSigning.cer, pinned by release.json. Never regenerate it, change
the bundle ID, use an identifier-only requirement or publish an ad hoc build.
Keep its private key outside source and in encrypted repository Secrets. Do not
add certificate trust or disable platform protections. Local development can use
ad hoc signing, but never replace the installed stable app with that identity.
Test permission continuity between different executables signed by the same key.

Use the `app-release` skill and its refreshed shared publishing guide.
Keep app-specific release operations in `docs/releases.md`.
Publish the current Awake.dmg through this repository's GitHub Releases and the
signed appcast through its GitHub Pages deployment. Never add cloud storage keys.

MIT is approved for this app. Preserve LICENSE and complete third-party notices
in both the app bundle and DMG; use the build/package license checks before release.
Do not change licensing or copyright notices by inference.
