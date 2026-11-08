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
unchanged when moving computers or hosting. The project is MIT-licensed; third-party
components retain their original terms.

GitHub Actions retains encrypted `SPARKLE_PRIVATE_KEY`, `AWAKE_SIGNING_P12` and
`AWAKE_SIGNING_PASSWORD` secrets. The first authenticates update feeds/archives;
the other two restore the persistent app code signing identity. Publication
uses GitHub's short-lived token with repository contents, Pages and OIDC write
permissions in the publish job only. Pull-request checks have no signing or
publication secrets.

GitHub Pages must use **GitHub Actions** as its publishing source. The `github-pages`
environment allows release tags matching `v*`. Keep releases mutable so the workflow
can remove old DMG assets after verification; never replace bytes under an existing
published version or move its tag. Other assets, source tags and release records
are preserved. There is one current DMG, with no version suffix in its filename.

## Publish

Build and package release artifacts only in GitHub Actions; publish the DMG on
GitHub Releases and the signed feed on GitHub Pages. Local checks and development
builds are not release artifacts. The personal website is outside this workflow;
do not inspect or change its content, listings, redirects or infrastructure.

1. Refresh shared instructions, read this guide and the latest signed feed.
2. Update version and build in `release.json`. Both identify a new published app;
   the build must exceed every published build. Run appropriate checks.
3. Review all maintained documentation against the whole current app. Record the
   review scope and evidence in the PR.
4. Push a branch, wait for required checks and merge the exact checked revision.
5. Push a new `v<version>` tag on that commit. Tag publication is deployment.
6. Wait for both **build** and **publish** jobs in **Release Awake**.
7. Verify the actual public DMG/feed bytes, Ed25519 signatures, version/build,
   length, `arm64` requirement, and both permanent URLs.

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

The macOS job validates configuration and imports the pinned release identity
into an isolated temporary keychain. A native signing preflight runs before tests
and compilation. It builds/signs the app and updater components, verifies bundle metadata and arm64 executables, and packages an APFS DMG containing
the app, Applications shortcut, LICENSE and THIRD_PARTY_NOTICES.md. It verifies the
previous feed signature and increasing build, then signs and verifies the new archive and single-entry feed.
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

The previous signed feed is read only from this repository's GitHub Pages URL.
An unavailable feed stops the release; no alternate host or first-release reset is used.
Verify the prior signature and increasing build before packaging.

## Licenses in released builds

The owner approved MIT for this app. `release.json` records `license: MIT` and
[LICENSE](../LICENSE) contains the complete terms and copyright notice. Do not
change the license, remove notices or regenerate the copyright year during a
routine release without an explicit owner instruction.

[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) includes Sparkle 2.10.1's complete
upstream license and external notices. When upgrading a dependency, review the
new version's actual license and update these notices before packaging.

`scripts/licenses.py` verifies complete MIT terms, the copyright notice and the
pinned Sparkle version. `build-app.sh` compares the notices with the actual SwiftPM
checkout license and copies both documents to `Contents/Resources/Licenses` before
code signing. This keeps notices with the installed app after a drag install or
a Sparkle update. Packaging verifies bundle copies, adds the same files to the DMG
root, mounts the finished image read-only and verifies both copies before update
signing. Missing, incomplete or mismatched notices stop the build/release.

Python regression tests cover notices surviving an app-only install, missing or
modified bundle/image files, incomplete MIT terms, removed copyright, dependency
license changes and an unapproved project-license change.

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
`AWAKE_OUTPUT_DIR`, `AWAKE_TOOLS_DIR`, `AWAKE_SIGN_KEYCHAIN`, and
`AWAKE_REQUIRE_RELEASE_SIGNING`. Without a keychain the build is ad hoc for local
development; packaging rejects it. Setting `AWAKE_REQUIRE_RELEASE_SIGNING=1`
also makes a missing keychain stop the build. `build-app.sh` replaces only its
generated bundle; do not copy an ad hoc build over the installed stable app.
`scripts/sparkle-tools.sh` downloads pinned Sparkle 2.10.1 and checks its archive
hash. Local signing uses the existing Keychain account; CI supplies the private
key to Sparkle tools over stdin, never in command arguments, files or logs.

Only when establishing a new app identity, use Sparkle's `generate_keys` tool.
Never regenerate an existing app's key. Keep a protected backup outside source and
build artifacts. Routine releases on another Mac need GitHub access, not copied
publication credentials.

## Persistent code signing and installation

Released apps use a dedicated self-signed **Awake Release** certificate. Its public
DER is `Resources/ReleaseSigning.cer`; `codeSigningCertificateSHA256` in
`release.json` pins it. This is separate from the unchanged Sparkle update key.
The default designated requirement binds each component's identifier to this
certificate, rather than to the changing executable hash. Keep the exact
certificate and private key for all subsequent releases. A newly generated
certificate with the same name does not preserve identity.

`scripts/signing.py` validates the public pin before signing. For non-PR builds,
CI imports the encrypted PKCS#12 identity into a temporary keychain, permits
`codesign` to use that key, and removes the keychain even when the job fails. The
user keychain search list is restored after import and no certificate is added to
system trust. While signing, the keychain is temporarily included in the search
list so codesign can construct its certificate chain; that list is restored even
on failure. A native signing preflight runs before compilation. PRs have no signing secrets and use ad hoc development builds.
The encrypted identity and password also have an owner-only local backup outside
source. Never print them, commit them or generate a replacement during a routine
build. A new Mac can publish through the configured CI without copying credentials.

Both the release build and packaging gate verify the exact embedded certificate and the
certificate-bound designated requirement for Awake and all Sparkle executables.
An absent secret, changed public certificate, wrong component signer, ad hoc
identity or identifier-only requirement stops publication. The finished DMG is
mounted read-only and checked as well. Two different executable builds were
installed consecutively with this certificate: the second retained cursor access,
input detection and the idle sleep assertion without reopening setup.

Open the DMG, drag the app to Applications or a writable per-user Applications
folder, eject the image and launch the installed copy. These builds are not
Developer ID signed or notarized; first downloaded launch may require **System
Settings → Privacy & Security → Open Anyway**. Users do not install or trust the
signing certificate. Sparkle defaults to four-hour checks while the app runs, with
saved preferences respected; installation can wait for quit or permission.

The transition from **0.2.5 and earlier** changes identity once. Existing users
must remove Awake's old permission entry and add the installed copy once more.
Subsequent releases using the pinned identity retain the grant. Keep bundle ID,
certificate and Sparkle key unchanged. Never work around this by weakening the
requirement to the bundle identifier alone. A later Developer ID migration needs
an explicitly planned identity transition, signing/notarization checks and an
update test; it must not silently replace this certificate.

## Runtime checks

The built app accepts `--diagnostics` without starting the UI, input tap or motion.
`--smoke-test` opens the main menu, motion-delay submenu and Updates submenu,
verifies visible row geometry, and checks all setup states and the drag helper
in light and dark appearances. It exits without requesting permission, starting monitoring, changing
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

For local ad hoc development builds, finish rebuilding before granting access:
their designated requirement remains bound to a changing code hash. Use the
persistent keychain for local permission-continuity tests. Query `--status` in the
running app's own context; a diagnostic process started by a trusted development
tool can inherit that tool's access and report a misleading result. If an old
ad hoc grant remains enabled-looking but unusable, remove only Awake's entry and
add the exact installed bundle once. Never reset unrelated application grants.

Permission setup uses a normal `NSWindowController` window with standard AppKit
labels, push buttons, system spacing and intrinsic content sizing. It does not
borrow `NSAlert.window` or show an alert outside its supported presentation API.
Missing access opens this window on launch; dismissing it preserves the menu bar
warning. Granting access closes an open warning window automatically. Reopening
an already ready app does not create a success window. The **Permissions…** menu
item can show readiness explicitly. An input-tap failure has its own paused state;
**Still Blocked?** expands recovery instructions in the same window.
**Open System Settings…** hides the setup window and opens a standard floating
window that first asks the user to turn on Awake in the list. **Not Listed?**
reveals a native file drag source for the running app bundle; an existing disabled
entry does not need to be dragged again. Dropping the icon adds that exact copy;
**Show in Finder** reveals it. The panel follows the Settings sidebar, floats only
while Settings or Awake is active and stops after permission is granted or its
close button is used. Window positioning reads only
public bounds metadata, without screen capture or another permission request.
Verify a real drag into Settings from an installed Applications copy when changing
this flow; a layout test cannot establish that Settings accepts the dropped file.

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
