# Awake release operations

Follow the refreshed `app-release` skill and
[shared publishing guide](https://github.com/vitalyterenin/app-release-kit/blob/main/skills/app-release/references/publishing.md).

Awake is a native AppKit/SwiftPM menu bar app for **arm64 only, macOS 13+**.
The permanent bundle ID and Sparkle Keychain account are
`com.vitalyterenin.awake`. Never replace an established update identity.

The release owns exactly two Yandex Object Storage objects in `teren.in`:

- `apps/Awake.dmg` → `https://teren.in/apps/Awake.dmg`
- `apps/feeds/awake.xml` → `https://teren.in/apps/feeds/awake.xml`

Source stays private. No GitHub Release assets, Intel builds, telemetry or
historical distribution objects are created. The website catalog belongs to the
separate `teren-in` repository. The publisher cannot write it.

## Initial setup

Generate this app's distinct update key once with the pinned Sparkle tool:

```sh
tools="$(bash scripts/sparkle-tools.sh)"
"$tools/bin/generate_keys" --account com.vitalyterenin.awake
```

Keep the private identity in Keychain and encrypted repository secrets; commit
only the public key in `release.json`. GitHub Actions needs `SPARKLE_PRIVATE_KEY`,
`YC_ACCESS_KEY_ID`, `YC_SECRET_ACCESS_KEY`. The storage publisher is a dedicated
service account with bucket-scoped uploader access and an exact-object bucket
policy. Its name is `awake-release`, ID `ajedgk1fm1eiv8ndihom`.
Preserve existing policy statements/public reads; exclude this account
from any pre-existing permissive `NotPrincipal` statement. The applied policy is
recorded in `deployment/teren-in-policy.json`. A committed policy alone does not
change cloud access.

## Routine release

1. Update semantic version and increase the positive build in `release.json`.
2. Run `bash scripts/test.sh` and `bash scripts/build-app.sh`.
3. Review all maintained app documentation against the complete current app using
   the shared skill's mandatory documentation gate. Correct inconsistencies and
   record review scope and evidence in the release PR before tagging.
4. Push a branch, wait for PR checks, merge the checked revision into main.
5. Tag that exact commit `v<version>` and push the tag.
6. Wait for both **build** and **publish** jobs in **Release Awake**.
7. Verify the publicly served feed/DMG, both Ed25519 signatures, length,
   arm64 requirement and version/build. A source commit is not a release.
8. Review the [Apps catalog card](https://teren.in/apps/) using the shared
   [catalog workflow](https://github.com/vitalyterenin/app-release-kit/blob/main/skills/app-release/references/catalog.md).
   Create a missing card or update changed facts through the separate website
   repository, then verify the live page and download. Leave an accurate card
   unchanged; app publisher credentials must not gain website access.

PR checks have no secrets. Ordinary main pushes do not publish. The matching tag
builds and ad hoc signs the app, creates/verifies an APFS DMG with Applications
shortcut, signs both archive and single-entry appcast, then conditionally uploads
the DMG before its feed. Both objects use `no-store, max-age=0`. Read-back checks,
ETags, build monotonicity and credential-boundary probes reject stale/overbroad
publication. Actions artifacts are retained for 14 days.

Never rebuild different bytes under a published build or force-move a release
tag. Retry a failed upload with the same verified artifact or increment the app
version/build for a fix. Developer ID and notarization can be added before final
packaging later, without changing the updater identity or permanent URLs.

Build/cache paths are outside Documents to avoid file-provider metadata breaking
signatures. Overrides: `AWAKE_BUILD_DIR`, `AWAKE_OUTPUT_DIR`, `AWAKE_TOOLS_DIR`,
`AWAKE_SIGN_IDENTITY` (default `-`, ad hoc).

The local test script runs Swift Testing (including with Command Line Tools that
lack XCTest). CI always runs the Python publication tests as well. To run these
locally without changing system Python:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install 'boto3==1.42.97'
.venv/bin/python -m unittest discover -s Tests -p 'test_*.py'
```

## Runtime checks

The built app accepts `--diagnostics` without starting the UI, input tap or motion.
`--smoke-test` opens the main menu, motion-delay submenu and Updates submenu,
verifies that every visible row fits their
rendered frames, and exits without asking for permission or starting monitoring.
`--preview-menu` opens the menu for manual visual inspection without monitoring.
Never use live cursor movement tests without the user
granting Accessibility to the installed app. Secure Input is handled using only
key-event ages; no key codes or characters are read. Session lock detection also
consults the optional WindowServer lock flag and otherwise uses workspace session
and display notifications. The macOS sleep/lock policy remains in control.
