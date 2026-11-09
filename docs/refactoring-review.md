# Awake refactoring review

This document records the audit of 0.2.8 and its follow-up fixes. It also preserves
the earlier audit and implementation that led to 0.2.8. See [architecture](architecture.md)
for the current system and [release operations](releases.md) for procedures.

## 2026-11-10 audit of 0.2.8

Baseline: clean `main` at `3868ada946379293e0a25982da469e0b7e2549fd`,
version 0.2.8, build 11. This audit changed only documentation. It focused on
runtime and platform boundaries, Swift scenarios, packaging and publication
order, Python publication fixtures, SwiftPM pins, and the workflow. AppKit
presentation was smoke-tested. Dependency internals and artwork were outside scope.

Keep the current core/runtime/AppKit split, Sparkle, and the GitHub-only release
path. The two issues below can be fixed through existing boundaries; they do not
justify a rewrite or dependency upgrade. No performance improvement is claimed.

### A1 — Brightness restoration can stop retrying while the cursor moves

**P2, reproduced.** [The controller](../Sources/AwakeRuntime/AwakeController.swift#L69)
requests a forced restore when the dimming option is turned off. A failed write
ends that display's transition while retaining its journal entry, as intended.
But the [moving branch with dimming off](../Sources/AwakeRuntime/AwakeController.swift#L205)
only sets the menu message. It skips the throttled restore that runs while the
cursor is stationary. A temporary failure can leave the display dim until
further input, a pause or quit, even after writes work again.

**Evidence:** An isolated Swift Testing scenario used the actual controller, a
manual clock and a fake display. It dimmed from `0.8125` to `0.0625`, turned
dimming off, rejected the first restoration write, then allowed writes again.
Three subsequent heartbeat ticks and brightness-frame opportunities left the
display at `0.0625` and its journal at `0.8125` while the menu said
`Moving cursor`. The next real-input callback in the fixture started recovery.
Calling the existing throttled restore in the moving branch with dimming off
made the same probe pass in a temporary copy, with cursor motion still active.

**Implemented and verified locally.** The controller calls the throttled restore
on heartbeat ticks during motion when dimming is off. The regression test rejects
the first restore write, checks the one-second retry interval and verifies that
the journal clears only after the fade completes. The cursor still posts a motion
frame after restoration.

### A2 — The first public DMG read can strand the signed feed on the previous release

**P2, reproduced.** In the baseline, [`publish()`](../scripts/publish.py#L91) makes the GitHub
release public and latest before reading the public DMG URL. One stale response
or temporary HTTP failure stops the job before staging Pages. The bounded retry
in `verify()` runs only after Pages deploys. The
previous appcast points to GitHub's mutable latest download, so it can ask
Sparkle for bytes that no longer match its signature. Sparkle rejects that
archive; the issue affects update availability. Older assets remain intact.
See [GitHub's latest download URL](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
and [Sparkle's update verification](https://sparkle-project.org/documentation/publishing/).

**Evidence:** Two isolated runs used the existing publication fixture and a fake
GitHub client. One returned stale archive bytes and one HTTP 503 on the first
public DMG read. Both would return the expected bytes on the second read. In
each case the current code had already marked the release public and latest,
made only one archive read, and produced no staged `pages/appcast.xml`.

**Implemented and verified locally.** The publisher shares the public read retry
loop with final verification. The check before staging Pages allows up to six
attempts within 30 seconds and requires exact archive bytes. The final check
retains its 180-second acceptance budget. Together with the [pinned Pages action's
10-minute deployment timeout](https://raw.githubusercontent.com/actions/deploy-pages/d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e/action.yml),
these budgets total 13 minutes and 30 seconds inside the 15-minute job limit.
Other job steps share the remaining time. Fake-clock tests cover stale bytes,
HTTP 503, attempt exhaustion, a matching response after the deadline and HTTP 403.
They verify one publication sequence and Pages staging only after a timely match.

This reduces failures due to short-lived CDN problems. GitHub Releases and
Pages still switch separately. A version-specific enclosure using the
[release asset's download URL](https://docs.github.com/en/rest/releases/assets)
could tie a signed feed to one archive. Cached feeds would still need their
corresponding assets, so defer that alternative until there is a decision on
how long previous DMGs should be kept and how to transition the current feed.

### Audit verification

On Apple Silicon macOS 26.7.2 (25G332), Swift 6.4.2 and Python 3.9.6,
`bash scripts/test.sh` passed release metadata validation, all 33 Swift tests
and all 37 Python tests. `bash scripts/build-app.sh` passed with an isolated
output directory. The ad hoc app passed strict signature verification,
`--diagnostics`, and `--smoke-test` for menu geometry and native setup dismissal
in Aqua and dark Aqua. The brightness probe failed on the baseline and passed
with the candidate change in the temporary copy. The Python probes reproduced
the publication failure without calling GitHub or Pages. These probes were
not added to the project test suite.

### Follow-up verification

The new Swift regression test and the Python cases for stale bytes, exhaustion
and a late response failed before the fixes. After the fixes,
`bash scripts/test.sh` passed 34 Swift tests and 41 Python tests.
`bash scripts/build-app.sh` passed with an isolated output directory. The arm64
development app passed strict signature verification, `--diagnostics` and the
AppKit `--smoke-test`. The regression tests simulated display writes and GitHub
publication. Physical display recovery and a live signed update remain
unverified.

## Historical scope and result before 0.2.8

Initially reviewed on 2026-11-08 in audit mode following the `deep-refactor` skill.
The user subsequently authorized implementation of the staged plan. The findings
below retain their baseline evidence; implementation results are recorded separately.
Baseline: branch `main`, commit `68097a28b7494bdc4015097eefb99885642fcc9c`, version
0.2.7 / build 10. The working tree was clean before the audit; the implementation
started with its README change and two new documentation files. No release, push,
installed-app replacement or permission reset was performed.

Awake already has useful boundaries: deterministic motion/brightness logic in
`AwakeCore`, thin platform adapters, native permission windows and a separately
tested release pipeline. A wholesale rewrite is not justified. Prioritize two
runtime error-path fixes, a small controller testing seam and bounded retries in
public verification. See the stage status and implementation results for completion.

The review read all 10 application Swift files, all three core files and both
Swift test files in detail. It also inspected the four Python release modules,
all four Python test modules, test/build/tool-download shell scripts, SwiftPM
manifest/lockfile, release configuration, CI, privacy manifest, README and release
guide. Git history was sampled for permission identity, UI and dimming changes.
The icon generator and artwork were outside behavioral review; dependency internals
were not audited. The pinned dependency license was checked by the actual build.

An independent runtime review used GPT-6 Astra at its maximum available reasoning
setting. Findings were reconciled against the source and available local checks.
This is an engineering audit, not a claim of exhaustive security review.

See [architecture](architecture.md) for the current component map, lifecycle,
persistence, diagnostics and build contracts. Source line references below refer
to the baseline commit, not future revisions.

## Findings

| ID | Priority | Kind and evidence | Recommendation | Effort / regression risk |
| --- | --- | --- | --- | --- |
| R1 | P2 | Reproduced error-path defect: nullable power snapshot is force-unwrapped. | Return unknown supply when snapshot acquisition fails. | Small / low |
| R2 | P2 | Reproduced reporting defect: brightness write failures are discarded. | Carry write outcome into dimming status, preserving recovery. | Small–medium / medium |
| R3 | P2 | Confirmed coverage gap at the runtime coordination boundary. | Add narrow injected dependencies and transition scenario tests. | Medium / medium |
| R4 | P2 | Reproduced publication robustness gap: transient fetch errors bypass retries. | Retry explicitly transient failures within a bounded budget. | Small / low–medium |
| R5 | P3 | Confirmed duplicated CI work. | Run the Python suite once per build job. | Small / low |

### R1 — Power-source acquisition can terminate the runtime

**Evidence:** `Sources/Awake/PowerSourceMonitor.swift:10-17` calls
`IOPSCopyPowerSourcesInfo().takeRetainedValue()` without checking its implicitly
unwrapped optional result. The installed SDK's `IOPowerSources.h`, documentation
for `IOPSCopyPowerSourcesInfo`, explicitly permits NULL on error. The later guard
only handles failure to obtain the source type after a snapshot exists.

**Impact:** A snapshot acquisition error traps before `.unknown` can reach
`PowerSupply.permitsAwake`. This bypasses the intended paused state and normal
cleanup, including immediate brightness restoration. The saved journal remains
the recovery mechanism on a subsequent launch. An isolated compiled probe linked
the existing monitor body against a C stub returning NULL for snapshot acquisition.
It exited with signal 5 and “Unexpectedly found nil while implicitly unwrapping an
Optional value” at the corresponding source line. This confirms the error-path
failure; it does not establish that the real OS returned NULL during normal use.

**Proposal:** Guard acquisition before calling `takeRetainedValue()` and return
`.unknown` on failure. Keep existing AC, battery/UPS and unknown policy unchanged.
Do not cache a previously allowed supply across an acquisition failure. This is a
bug fix, not behavior-preserving refactoring. Confidence is high; failure frequency
is unknown. It can land independently of R3.

**Verification:** Inject a nil acquisition result and assert `.unknown` without a
trap, then verify the controller releases its assertion and stops motion. Retain
tests for AC, battery opt-in, UPS mapping and successful recovery on a later read.

### R2 — Scheduling a fade is reported as successful dimming

**Evidence:** `AwakeController.tick()` at `Sources/Awake/AwakeController.swift:289-296`
chooses the menu status from `IdleDimming.fadeDown(at:)` and `isAnimating`.
`updateBrightnessClock()` at lines 353-365 ignores the Boolean returned by
`advance(to:)`. In `Sources/AwakeCore/IdleDimming.swift:108-132`, a failed write
returns false, removes that display from the active transition and retains its
saved recovery value. The next readable brightness snapshot can schedule another
fade even though no write succeeded.

**Impact:** A readable but unwritable display can keep showing “Dimming display”
while its brightness stays unchanged; partial multi-display failure is also not
represented in the UI. A compiled probe used the actual `IdleDimming` implementation,
a fake backend that always reads 0.8125 and rejects writes, and the controller's
status-selection expression. Four successive simulated ticks each produced
`message=Dimming display actualWriteSucceeded=false brightness=0.8125 pending=1`.
This reproduces the core/result mismatch without starting the actual controller
or changing a real display. Existing tests correctly protect recovery after failed
writes, but do not test the controller's displayed result. This does not establish
data loss: retaining the recovery entry is intentional and must be preserved.

**Proposal:** Separate transition scheduling from observed write outcome. Preserve
enough per-transition success/failure information to show brightness unavailable
or partial failure when appropriate, and update status on completion/failure.
Keep cursor motion independent of optional dimming, retain saved values until
restoration succeeds, and keep retries bounded by existing heartbeat scheduling.
Start with the smallest result/state addition; a general event bus is unnecessary.
This is a reporting bug fix with high confidence. The medium risk is accidentally
changing reversal, retry or journal semantics while adding status.

**Verification:** Fake a display that reads successfully but rejects every write;
verify unchanged brightness and honest status. Cover a mixed-success pair, a later
successful retry, input during fade, failed restoration, reconnect and quit. R3
provides the useful seam for checking the actual controller status.

### R3 — Core tests do not establish controller transition ordering

**Evidence:** `Package.swift` gives `AwakeCoreTests` only an `AwakeCore` dependency.
The 15 Swift tests exercise geometry, delay, power policy and brightness state.
`AwakeController` directly reads UserDefaults, uptime, permissions, session state,
power and event-tap state while also controlling assertions, event posting and
timers. The smoke test deliberately returns before starting this runtime.

**Impact:** Core tests can pass while their orchestration reports a wrong result
(R2) or performs cleanup in an unintended order. Future controller changes have
no deterministic regression test for the combined policy and resource lifecycle.
This is a testability finding, not evidence that every untested transition fails.

**Proposal:** Add narrow injectable reads/effects for time, permission/session,
power, tap/assertion operations and brightness. Keep AppKit and platform adapters
at the edge and preserve the current ordered gate checks. Extract a small runtime
coordinator only if those seams alone remain awkward. Avoid a framework migration,
generic dependency container or rewriting the native UI. Do not consolidate every
early-return branch before its different cleanup obligations are tested.

**Contracts:** Countdown reset on real input, delay/power changes and resume;
synthetic-marker exclusion; no movement/assertion when blocked; immediate cleanup
on suspension/quit; recovery retained through failed writes. Preserve preference
keys, default values and visible controls.

**Verification:** Use scenario tests for permission loss/regain, tap failure,
assertion failure, AC/battery/unknown transitions, session suspend/resume and
reconnect with pending brightness recovery. Assert observable motion, sleep and
brightness effects and status, not private method call order. Introduce seams in
small steps and keep real hardware checks separate. Confidence in the coverage
gap is high; the proposed extraction size should be decided by these tests.

### R4 — Public verification does not retry transient transport errors

**Evidence:** `scripts/publish.py:150-157` retries unequal fetched bytes but lets
fetch exceptions escape. `public_bytes()` at lines 15-23 converts only HTTP 404 to
None; other HTTP failures and connection errors propagate. An isolated run using
the existing test fixture, `attempts=3` and a fake fetch that raises `URLError` on
its first call produced: **1 fetch, 0 retry sleeps, 0 GitHub mutations**. The fake
would have returned the expected feed and archive on subsequent calls. No network
or real publication was involved.

**Impact:** A temporary public endpoint error can fail the final CI verification
even after successful deployment. Older downloads remain preserved, so the
existing fail-closed cleanup behavior is correct. The current guide's bounded
verification description applies to byte mismatch/404, not all transient errors.

**Proposal:** Retry a deliberately limited set of connection/timeout and transient
HTTP failures within an explicit overall deadline. Keep malformed artifacts,
identity errors, wrong bytes after exhaustion and permanent failures fatal.
Preserve exact-byte verification and perform no deletion before successful
convergence and latest-release verification. Do not add blind mutation retries.
Leave `publish()`'s immediate readback behavior as a separate design decision.

**Verification:** Inject transient-error-then-success, persistent transport failure,
byte mismatch, permanent HTTP failure, changed latest release and deadline
exhaustion. Use a fake clock/sleep and assert that failed verification never
deletes an asset. Independent of the runtime changes.

### R5 — Python tests run twice in the same build job

**Evidence:** `.github/workflows/release.yml:34-37` runs Python unittest directly,
then invokes `scripts/test.sh`, which runs that same suite after Swift tests.
The duplication is confirmed, but the suite took only 0.078 seconds locally, so
this is a clarity improvement rather than a meaningful speed claim.

**Proposal:** Keep `scripts/test.sh` as the complete local/CI entry point and remove
the separate CI invocation, or explicitly split Swift/Python entry points if
independent early feedback is desired. Preserve one execution of every suite and
the release-signing preflight. No new regression test is needed for this mechanical
workflow edit; inspect the resulting job and run its retained entry point.

## Staged plan

| Stage | Type | Status | Completion criterion |
| --- | --- | --- | --- |
| 0. Baseline and current architecture | Audit/documentation | Completed | Source mapped, baseline checks recorded, documents linked from README. |
| 1. Guard missing power snapshot (R1) | Defect fix | Implemented and tested | Nil snapshot pauses without a trap; valid supply mappings preserved. |
| 2. Add runtime scenario seam (R3) | Refactoring and lifecycle guard | Implemented and tested | Deterministic gate/cleanup scenarios pass without real input or hardware changes. |
| 3. Expose dimming write outcome (R2) | Defect fix | Implemented and tested | All-failed and partial writes produce truthful status; recovery tests pass. Depends on stage 2 for controller-level evidence. |
| 4. Bound transient verification retries (R4) | Release robustness fix | Implemented and tested | Retry budget, eventual success and no-cleanup-on-failure cases pass. Independent of stages 1–3. |
| 5. Remove duplicate suite invocation (R5) | Workflow simplification | Implemented and inspected | Every required suite still runs exactly once. |

The follow-up request authorized implementation of all stages. No version bump,
dependency upgrade, licensing change or publication is part of this work.

## Implementation results

### Runtime boundary, power and brightness (R1–R3)

`AwakeRuntime` now contains the actual controller and platform adapters. The UI
imports that target through package-scoped controller/state access; `AwakeCore`
retains deterministic geometry, dimming and power policy. An internal
`AwakeEnvironment` protocol supplies time, power, permission/session inputs,
input taps, sleep assertions, clocks and event posting. Its system implementation
retains the native APIs and common-run-loop behavior; tests inject manual effects,
brightness access and a unique UserDefaults suite. No dependency framework was added.

Power snapshot acquisition is guarded before taking the retained value. Tests inject
nil, then a valid snapshot, and check the AC/battery/UPS/unknown/missing-type mappings.
A failed snapshot therefore reaches the existing unknown-power pause policy.

`IdleDimming` now retains per-display failed-write outcomes independently of its
recovery journal. Scheduling a retry no longer clears a failure. Successful writes
or a subsequent read already below the dim threshold clear the failure; final
successful restoration is still required to clear the saved original brightness.
The controller displays complete or partial brightness unavailability and refreshes
status when a fade outcome changes. Cursor operation remains independent of this
optional brightness feature. Fade duration, easing, preference keys and defaults,
input handling and signing identity remain unchanged.

The controller now makes start/stop idempotent and ignores queued refresh, activity,
frame and session callbacks after stop. This is an intentional lifecycle guard:
failed quit restoration keeps the journal for next launch, but stale callbacks
cannot restart a timer. Explicit shutdown still attempts immediate restoration.
Preview-mode refreshes cannot inadvertently start monitoring before normal startup.

Eighteen new runtime tests execute the actual controller and power adapter. They
cover nil snapshots through controller pause/recovery, permission/tap/assertion
failure, battery/unknown supply, suspension, input/delay/Secure Input, pointer
movement and failed event posting, unreadable/all-failed/partial brightness,
startup recovery/reconnect, disabled retry, quit and stale callbacks. The smoke
fixture also exercises the longest new status message in the actual menu.

### Publication verification and CI (R4, R5)

`verify()` now uses both a positive attempt limit (24 by default) and a monotonic
acceptance deadline (180 seconds). Production request timeouts are capped to the
remaining budget, waits are at most five seconds, and successful byte matches are
rejected if the deadline has elapsed. Socket timeouts cannot strictly bound an
entire slowly streamed response, but late responses cannot authorize cleanup.
Only known temporary transport/HTTP failures retry; certificate verification,
permanent HTTP errors and malformed-input exceptions propagate immediately.
GitHub mutation handling and the immediate publication readback remain unchanged.

Seven added Python test methods cover transient failure then success (including
archive fetch failures), persistent failure, permanent errors, budget exhaustion,
late matching responses, stale bytes followed by a changed latest release, and
invalid budgets. Fake clocks and clients make these tests deterministic without
network access or publication. All 37 Python tests passed after this change.

CI now invokes `scripts/test.sh` once, retaining both Swift and Python suites and
the signing preflight. The duplicate standalone Python step was removed; no
meaningful speed improvement is claimed for this small suite.

## Final implementation verification

- `bash scripts/test.sh` passed: **33 Swift tests** (15 core + 18 runtime) and
  **37 Python tests**, plus release metadata validation. This includes 25 new test
  methods across the two languages. All tests use local fixtures/fake effects;
  publication log messages in test output are from fake clients.
- The isolated runtime development test run also passed all 33 Swift tests.
- `bash scripts/build-app.sh` passed with the new runtime target, license checks
  and ad hoc signature verification. The generated development app remains under
  `~/Library/Developer/Awake/Awake.app`; the installed stable app was not replaced.
- Generated binary `--diagnostics` and `--smoke-test` passed. The latter checked
  the longest partial-failure status in the actual menu (350-point width), the
  delay/update submenus, setup/helper states in both appearances and real dismissal.
- The real preview setup window was visually inspected and its nonblank screenshot
  saved at `~/Library/Developer/Awake/Review/refactor-setup.png`. Its native “Not Now”
  dismissal was exercised. The preview process was then stopped.
- `git diff --check` and local documentation-link checks passed.

The same pre-existing linker warnings remain. Hardware power/sleep/brightness,
macOS 13 execution and signed-release permission continuity were not exercised;
their failure paths are covered through injected effects, not claimed as real-device
validation. No signing identity, permissions, live release or installed app changed.

## Baseline checks and limitations

Local environment: arm64 macOS 27.2 (26B123), Apple Swift 6.4.2, Python 3.9.6.
These are observed local tool versions, not a claim about minimum-platform testing.

| Check | Result |
| --- | --- |
| `bash scripts/test.sh` | Passed: release metadata validation, 15 Swift tests and 30 Python tests. |
| `bash scripts/build-app.sh` | Passed: release compilation, exact license installation and ad hoc signature verification. Generated `~/Library/Developer/Awake/Awake.app`. |
| Generated binary `--diagnostics` | Passed. Permission result belongs to this CLI process, not the installed app. |
| Generated binary `--smoke-test` | Passed: three menu geometries, helper states, setup states and actual dismissal in Aqua/dark Aqua, including becoming ready while open. |
| Isolated publication exception probe | Reproduced R4 using existing fixtures and fake fetch/sleep; no external mutation. |
| Isolated power acquisition probe | Reproduced R1 with the monitor body and NULL-returning C stub; SDK contract independently confirms that NULL is allowed. |
| Isolated brightness outcome probe | Reproduced R2 with actual core code, fake failed writes and the controller's status expression; no hardware calls. |

The linker emitted missing Command Line Tools framework/library search-path
warnings. The test link also warned that the installed Testing framework targets
macOS 14 while the package deployment target is macOS 13. Both commands exited
successfully. These are baseline environment limitations; this run does not
establish execution on macOS 13 or its fallback timer.

The initial audit's smoke test presented windows and checked geometry/dismissal,
but that audit did not capture screenshots or drag a bundle into System Settings.
The later implementation checks include the screenshot recorded above. Real cursor
motion, Secure Input timing, brightness hardware, display
disconnects, battery changes, lock/sleep behavior and signed-update permission
continuity were not exercised. No production signing, packaging or deployment
was attempted, and the published feed was not used to infer local behavior.

An illustrative local footprint from `du -sk` was 2,324 KiB allocated for the
generated bundle, including 1,520 KiB for embedded Sparkle; the main executable's
logical size was 363,728 bytes. Allocated disk size is not download size. There is
no before/after comparison and no measured CPU, energy, memory or startup win.
If optimization becomes a goal, profile identical release builds at fixed display
refresh rate in countdown, motion, fade and steady-dim states. Count brightness
reads/writes and sample CPU/energy across repeated runs before changing polling or
frame rate; smooth motion and recovery are part of the contract.

## Decisions and remaining risks

- Keep the pure-core/native-adapter split and Sparkle. No measured cost justifies
  replacing the updater or native interface.
- Keep the macOS 13 timer fallback, persisted recovery journal, stable signing
  certificate and permission-recovery UI. Their age or uncommon execution does
  not make them obsolete. `IdleDimming.dim()` is exercised by tests and public in
  the core; absence from the app's fade path alone is not grounds for removal.
- Keep private DisplayServices failure handling explicit. Hardware/API compatibility
  needs real-device checks when that adapter changes; fake tests cannot establish it.
- The workflow always fetches the previous feed before packaging; the standalone
  package CLI still accepts omitted `--previous`. Helper slices are thinned by the
  build script, while packaging's explicit architecture check inspects the main
  executable. Consolidating these standalone gates is optional hardening if those
  commands become independently supported release entry points, not a demonstrated
  failure of the current CI path.
- UserDefaults persistence is invoked before brightness writes, but this audit
  did not prove crash-durability under power loss. Retention of the journal and
  recovery on ordinary next startup are distinct from such a durability guarantee.

Hardware checks and actual signed release/update validation remain separate from
deterministic local tests; see the implementation verification results above.
