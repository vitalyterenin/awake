# Awake release operations

Use the refreshed `app-release` skill and
[shared publishing guide](https://github.com/vitalyterenin/app-release-kit/blob/main/skills/app-release/references/publishing.md).
This app supports Apple Silicon only, macOS 13 or later, with one stable channel.

## Hosting and identity

- Public source: https://github.com/vitalyterenin/awake
- Current download: https://github.com/vitalyterenin/awake/releases/latest/download/Awake.dmg
- Signed feed: https://vitalyterenin.github.io/awake/appcast.xml
- Bundle ID and existing Sparkle Keychain account: `com.vitalyterenin.awake`.

`release.json` owns the three-part version, increasing positive build, app name,
repository, URLs and public Ed25519 update key. Keep the bundle ID and update key
unchanged when moving computers or hosting. The source is public; no open-source
license has been assigned. The personal Apps catalog is owned by the separate
`teren-in` repository and is optional for downloading and updating this app.

GitHub Actions retains only the encrypted `SPARKLE_PRIVATE_KEY` secret. Publication
uses GitHub's short-lived token with repository contents, Pages and OIDC write
permissions in the publish job only. Pull-request checks have no signing or
publication secrets. No Yandex/S3 credentials are required.

GitHub Pages must use **GitHub Actions** as its publishing source. The `github-pages`
environment allows release tags matching `v*`. Keep releases mutable so the workflow
can remove old DMG assets after verification; never replace bytes under an existing
published version or move its tag. Other assets, source tags and release records
are preserved. There is one current DMG, with no version suffix in its filename.

## Publish

1. Refresh shared instructions, read this guide and the latest signed feed.
2. Update version and build in `release.json`. Both identify a new published app;
   the build must exceed every published build. Run appropriate checks.
3. Review all maintained documentation against the whole current app and prepare
   any changed Apps card facts. Record the review scope and evidence in the PR.
4. Push a branch, wait for required checks and merge the exact checked revision.
5. Push a new `v<version>` tag on that commit. Tag publication is deployment.
6. Wait for both **build** and **publish** jobs in **Release Awake**.
7. Verify the actual public DMG/feed bytes, Ed25519 signatures, version/build,
   length, `arm64` requirement, and both permanent URLs.
8. Reconcile the [Apps card](https://teren.in/apps/) through the
   [catalog workflow](https://github.com/vitalyterenin/app-release-kit/blob/main/skills/app-release/references/catalog.md).
   Commit/deploy changed facts in the website repository and inspect the live card.
   An accurate card needs no cosmetic edit.

From the repository root, after merging the intended source revision:

```sh
set -euo pipefail
python3 scripts/release.py validate
release_tag="$(python3 -c 'import json; print("v" + json.load(open("release.json"))["version"])')"
git tag "$release_tag"
git push origin "$release_tag"
```

Ordinary source pushes do not publish. PRs run tests and an arm64 build without
secrets. A manual workflow on a branch builds/prepares artifacts but does not publish;
a manual run selecting a matching tag does publish. Do not rebuild a published build
with different bytes. If only publication failed, retry the failed publish job with
the same verified artifact. A bad app or changed DMG requires a new version/build.

## Pipeline order and failure handling

The macOS job validates configuration, tests, builds and ad hoc signs the app,
verifies bundle metadata and arm64 executables, and packages an APFS DMG containing
the app and Applications shortcut. It verifies the previous feed signature and
increasing build, then signs and verifies the new archive and single-entry feed.
The internal artifact includes SHA-256 hashes and the previous feed hash; it is
retained for 14 days. The feed and DMG remain authenticated separately from the
app's code signature.

The Linux job verifies hashes, repository/tag/commit identity, publication state
and the previous feed snapshot before creating a draft release. It uploads the
DMG, publishes the release and reads the public bytes back. Only then does it
stage the signed appcast for Pages. Pages deploys the feed; public verification
must pass before older DMG assets are removed. A failed feed deployment preserves
older downloads and must be fixed before declaring the release complete. The
workflow serializes releases rather than cancelling an in-flight publisher.

GitHub controls CDN caching. A cached older feed can briefly disagree with the
current DMG; Sparkle rejects the mismatch and a fresh check can retry. Never disable
signature checks to mask caching or deployment failures. Bounded verification waits
for Pages propagation and fails if the public objects do not converge.

Former feed/download addresses on `teren.in`, including the early Display Dials
`/updates/display-dials/` paths where applicable, remain compatible redirects.
Installed apps with an old feed address must still reach the signed current feed.
Do not remove those redirects after deleting obsolete storage objects. The first
GitHub release can use `legacyFeedURLs` to read the prior signed feed; it must not
silently treat an unreachable established app as a first publication.

## Local checks and tools

From the repository root on an Apple Silicon Mac with Swift 6+, Python 3 and
Xcode or Command Line Tools:

```sh
python3 scripts/release.py validate
python3 -m unittest discover -s Tests -p 'test_*.py'
bash scripts/test.sh
bash scripts/build-app.sh
```

Publication tests use fake GitHub/network clients and never upload live files.
They cover artifact tampering, stale feeds, repository/tag boundaries, downgrade
and build reuse rejection, exact-byte retry, and cleanup only after public
verification. All Python publication code uses the standard library.

Build/cache paths stay outside Documents. Overrides: `AWAKE_BUILD_DIR`,
`AWAKE_OUTPUT_DIR`, `AWAKE_TOOLS_DIR`, and `AWAKE_SIGN_IDENTITY`
(default `-`, ad hoc). `build-app.sh` replaces its generated app bundle.
`scripts/sparkle-tools.sh` downloads pinned Sparkle 2.10.1 and checks its archive
hash. Local signing uses the existing Keychain account; CI supplies the private
key to Sparkle tools over stdin, never in command arguments, files or logs.

Only when establishing a new app identity, use Sparkle's `generate_keys` tool.
Never regenerate an existing app's key. Keep a protected backup outside source and
build artifacts. Routine releases on another Mac need GitHub access, not copied
publication credentials.

## Installation and Developer ID

Open the DMG, drag the app to Applications or a writable per-user Applications
folder, eject the image and launch the installed copy. Current builds are ad hoc
signed and not notarized; first downloaded launch may require **System Settings →
Privacy & Security → Open Anyway**. Sparkle defaults to four-hour checks while the
app runs, with saved preferences respected; installation can wait for quit or
permission. The running app displays its own bundle version.

Later, import the Developer ID identity into the CI signing keychain and set
`AWAKE_SIGN_IDENTITY`. Notarize and staple after building and before DMG
packaging/update signing. Preserve bundle ID, update key, URLs and increasing
versions; test an update from an ad hoc release before publishing the transition.

## Runtime checks

The built app accepts `--diagnostics` without starting the UI, input tap or motion.
`--smoke-test` opens the main menu, motion-delay submenu and Updates submenu,
verifies visible row geometry, and checks all setup states in light and dark
appearances. It exits without requesting permission, starting monitoring, changing
brightness or writing runtime preferences.
`--preview-menu` opens the menu for manual visual inspection without monitoring.
`--status` queries the already running app over a read-only local notification
exchange, reporting its own permission state, power policy, dimming recovery count
and animation frame count. It does not start Awake or change settings. Use this
for live checks instead of inferring app permission from the diagnostic CLI process.
Never use live cursor movement tests without the user
granting Accessibility to the installed app. Secure Input is handled using only
key-event ages; no key codes or characters are read. Session lock detection also
consults the optional WindowServer lock flag and otherwise uses workspace session
and display notifications. The macOS sleep/lock policy remains in control.

For local ad hoc builds, finish rebuilding before granting cursor-control access.
The designated requirement is a code hash, so replacing the executable can leave
an enabled-looking TCC entry that still rejects the new build. Confirm this in
the app's actual launch context; a diagnostic executable started by an already
trusted development tool can inherit that tool's access and give a misleading
result. Remove only Awake's stale entry in the macOS permission UI and add the
exact current app bundle again. This preserves unrelated permissions and updates
the grant to the intended binary. Then verify the Awake-owned power assertion
and real, Awake-tagged mouse motion after the selected idle interval.

Permission setup uses a normal `NSWindowController` window with standard AppKit
labels, push buttons, system spacing and intrinsic content sizing. It does not
borrow `NSAlert.window` or show an alert outside its supported presentation API.
Missing access opens this window on launch; dismissing it preserves the menu bar
warning. Granting access closes an open warning window automatically. Reopening
an already ready app does not create a success window. The **Permissions…** menu
item can show readiness explicitly. An input-tap failure has its own paused state;
**Still Blocked?** expands recovery instructions in the same window.

`--smoke-test` presents each actual window state in light/dark appearances, invokes
its real dismiss button and asserts that the window is no longer visible. It also
checks closure when access becomes ready. `--status` includes `setupVisible` for
verification without reopening a window. Inspect and save a real, nonblank window
screenshot during UI changes; accessibility text and valid layout bounds alone do
not prove that a window renders. `--preview-setup` shows the missing-access state
without starting input monitoring.

Native dimming dynamically resolves DisplayServices read/write functions and checks
their results. The target is 1/16 of the system brightness slider. Unsupported and
sleeping displays are skipped; brightness is never raised to reach the dim target.
Saved levels use stable display UUIDs and are journaled in UserDefaults before a
write, then removed only after successful restoration. Input, pause, disable and
normal quit restore levels; startup recovers values left by forced termination.
The private framework may change with macOS, so check the real hardware path when
changing this code. There is no overlay/gamma dimming fallback.

Brightness transitions use a separate short-lived 60 Hz timer and monotonic time:
five seconds down and half a second back up. Both directions use
`cubic-bezier(0.65, 0, 0.35, 1)`, solving the x coordinate for normalized elapsed
time before evaluating y, with zero endpoint velocities and no overshoot. Input reverses an
unfinished dimming fade from the actual current slider level. Repeated input and
idle heartbeat ticks do not restart the transition. The restore journal is cleared
only after the final original-level write succeeds. Sleep/session suspension and
normal termination restore immediately so cleanup does not depend on a timer that
may no longer run. Native display identifiers are refreshed at transition start
and cached during the fade, avoiding screen enumeration for every write.

Power-source notifications and a heartbeat read pause the app on battery unless the user
enabled that option. Unknown power sources fail closed. Switching between AC and
battery resets the countdown. Motion uses a screen display link on macOS 14+ and
a 60 Hz timer on macOS 13; per-frame work avoids power queries, brightness reads
and screen enumeration.
