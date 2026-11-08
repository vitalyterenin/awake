# Awake architecture

This document describes the refactoring based on `68097a28b7494bdc4015097eefb99885642fcc9c`.
Baseline findings, implementation results and verification limits are recorded in
[the refactoring review](refactoring-review.md). Product usage is in the
[README](../README.md); publication procedures belong in [release operations](releases.md).

## Product boundary

Awake is an Apple Silicon macOS 13+ menu bar application. It prevents idle sleep
while its runtime gates permit operation, then moves the cursor after one or five
minutes of inactivity. Native display dimming and operation on battery are
independent opt-ins. It does not implement login startup, click/type automation,
input recording, telemetry, or a replacement for system sleep and locking policy.

The interface is AppKit. SwiftPM builds the `Awake` executable, the deterministic
`AwakeCore` library and the `AwakeRuntime` controller/platform module. Runtime tests
link the latter without launching the application entry point. Sparkle 2.10.1 is
the only external package, pinned exactly in
`Package.swift` and `Package.resolved`. Python release utilities use the standard
library; packaging also invokes macOS tools and pinned Sparkle command-line tools.

## Components and ownership

| Component | Responsibility |
| --- | --- |
| `Sources/Awake/main.swift` / `AppDelegate` | Menu construction, actions, permission presentation, startup and normal termination, diagnostic modes. |
| `AwakeRuntime/AwakeController` | Ordered runtime policy, countdown, motion/brightness coordination, persisted options and status. |
| `AwakeRuntime/AwakeEnvironment` | Internal injectable system boundary; `SystemAwakeEnvironment` owns taps, assertions, clocks, notifications and native queries. |
| `AwakeCore/IdleMotion` | Caller-clocked idle countdown and bounded circle geometry; no timers or event posting. |
| `AwakeCore/IdleDimming` | Caller-clocked brightness transitions and per-display recovery journal through `DisplayBrightnessAccess`. |
| `AwakeCore/PowerSupply` | Pure policy for AC, battery and unknown supply. |
| `AwakeRuntime/SystemBrightness` | Dynamic DisplayServices symbol lookup; display UUID mapping; validated native brightness reads/writes. |
| `AwakeRuntime/PowerSourceMonitor` | IOKit supply query and run-loop change notification. |
| `AwakeRuntime/CursorAnimationClock` | macOS 14+ screen display link, otherwise a 60 Hz timer. |
| `PermissionSetupWindow`, `PermissionDragPanel` | Native setup/recovery windows and file drag helper that accompanies System Settings. |
| `UpdateController` | Sparkle initialization, update checks and saved automatic-update options. |
| `RuntimeStatus` | Read-only request/reply diagnostics over distributed notifications. |

`AwakeEnvironment` is an internal protocol, not a public plugin API. Its production
adapter owns the run-loop resources; tests supply a manual clock, callbacks, power,
permission and session inputs, simulated taps/assertions and event posting. The
controller accepts injected brightness access and an isolated UserDefaults suite.
Only the controller's existing app-facing surface is package-visible across targets.

Runtime classes and brightness access are main-actor isolated. Event-tap and
power-source callbacks enter through the main run loop; notification callbacks
use the main queue. `IdleMotion` is a value type whose caller supplies monotonic
time. No background task queue or database coordinates runtime state.

## Startup, countdown and motion

1. `--status` and `--diagnostics` exit before constructing the normal app delegate.
   Normal startup creates the menu and controllers. Preview/smoke branches return
   before starting Sparkle, monitoring, runtime recovery or the status responder.
2. `AwakeController.start()` first attempts immediate recovery of saved brightness,
   subscribes to power/session/display notifications, starts a one-second heartbeat
   in common run-loop modes, and calls `tick()`.
3. `tick()` reads power and resets idle time on a supply change. It then checks,
   in order: enabled setting, allowed power source, Accessibility permission,
   usable session, input tap availability and sleep assertion creation.
4. Passing the gates holds `kIOPMAssertionTypePreventUserIdleDisplaySleep`, including
   during the countdown. Failures select a paused/error message and stop motion;
   inapplicable assertions are released. Repeated heartbeat ticks retry setup.
5. The input tap returns every event unchanged. It reads only the synthetic-event
   marker, not key codes or characters. Real events reset the countdown and stop
   motion. A heartbeat also checks HID key-event ages for Secure Input; this
   fallback has heartbeat latency rather than event-tap latency.
6. Once the delay expires, the controller requires no pressed mouse button and a
   display under the current pointer. `IdleMotion.begin()` captures pointer,
   bounds and start time. Motion uses a 12-point radius, four-second period and
   0.75-second smooth entrance into an in-bounds circle.
7. Each animation frame checks cached runtime gates, the live event-tap state and
   whether the pointer is still within one point of the last posted position.
   It posts a tagged `.mouseMoved` event, or resets activity on failure. Own tagged
   events do not restart the countdown. Power reads and screen enumeration occur
   outside the frame path.

Changing delay persists the choice and starts a fresh countdown. Changing enabled
or battery policy resets activity. Session suspend stops movement, attempts an
immediate brightness restore and releases the assertion. Resume resets the
countdown. Session usability combines workspace notifications, console-session
membership and the optional WindowServer lock flag; the heartbeat rechecks it.

Normal termination stops animation and monitoring, removes observers, releases
the assertion and attempts immediate brightness recovery. Cleanup cannot run on
forced termination; persisted recovery is attempted on the next normal startup.
Start and stop are idempotent. Queued callbacks are ignored after stop, including
when a failed quit restoration leaves saved levels for the next launch. Preview
refreshes before startup cannot start runtime monitoring.

## Brightness state and recovery

`DisplayBrightnessAccess.levels()` returns stable display identifiers and normalized
slider values. `setLevel(_:for:)` reports success. `SystemBrightness` resolves the
private DisplayServices functions at runtime; missing symbols, unsupported or
sleeping displays produce unavailable readings/writes. There is no overlay fallback.
`levels()` refreshes the UUID-to-current-display-ID map used by subsequent writes.

`IdleDimming` captures each display's original level once, invokes its persistence
callback before modifying that display, and retains the value until a successful
final restoration write. Invalid saved values are filtered at initialization.
Disconnected displays retain entries for a later restore attempt.

`fadeDown(at:)` targets 1/16 only for displays above that level plus its tolerance;
it does not brighten an already darker display. `fadeUp(at:)` starts from the
current observed level, including when interrupting a fade down. Repeated calls
in the same direction do not restart an active transition. `advance(to:)` applies
the elapsed-time result. Durations are five seconds down and half a second up,
using `cubic-bezier(0.65, 0, 0.35, 1)` with the time coordinate solved first.

The controller enables a separate 60 Hz brightness timer in the environment only
while a transition exists. Failed display writes remove that display from the active transition but
retain its recovery entry. Ordinary restore attempts are throttled to once per
second; forced attempts bypass that throttle. `restore()` cancels animation and
attempts the original levels immediately, for startup, suspension and quit.
`IdleDimming.status` distinguishes dimming, dimmed, unavailable and partial failure.
Failed display writes remain reflected in status across retry scheduling. An actual
successful write, or a later read already at/below the target tolerance, clears that
display's failure. Recovery values have a stricter rule: only a successful final
restore removes them. The controller updates the visible status on transition
outcome changes without refreshing the menu on every brightness frame.

## Persisted state and diagnostics

| UserDefaults key | Default / meaning |
| --- | --- |
| `keepAwake` | `true`; enabled preference, independent of current permission or power. |
| `motionDelayMinutes` | `5`; only `1` and `5` accepted, invalid values fall back to five. |
| `dimWhileIdle` | `false`; native dimming opt-in. |
| `allowOnBattery` | `false`; battery opt-in. Missing snapshots, missing source types and unknown sources pause. |
| `pendingBrightnessRestore` | Display UUID to original normalized brightness; retained across launches until successful recovery. |
| `didWelcome` | Whether the first-launch setup presentation has occurred. Missing permission still presents setup on subsequent launches. |

Sparkle owns its saved update preferences. Bundle defaults enable automatic checks
and installation, with a four-hour check interval and profiling disabled.

`--status` sends a UUID-tagged distributed notification and waits up to two seconds
for JSON from an already running app. It reports that process's permission,
power policy, sleep assertion, motion frame count, recovery count and setup-window
state. It does not start the runtime. The protocol does not select a particular
instance if multiple copies are running. `--diagnostics` reports permission of
the diagnostic process; it is not proof that an installed app has permission.

## Permission interface and validation modes

Missing permission or failed input monitoring leaves a visible warning in the
menu bar. The setup window uses a real `NSWindowController`, native controls,
intrinsic layout and an actual dismissal action. Becoming ready closes an open
blocked-state window. Opening Settings hides setup and starts the floating helper;
the helper offers enable-first instructions, then a drag source for the running
bundle. It follows public Settings window bounds every 0.25 seconds and stops on
close, permission readiness or Settings exit. It reads bounds, not screen pixels.

`--preview-menu` and `--preview-setup` present UI without starting runtime monitoring.
`--smoke-test` opens menus and exercises setup/helper states in light and dark
appearances, checking layout bounds and real dismissal. It is useful integration
coverage, but does not replace screenshot inspection or an actual drag into
Settings when changing the UI. It does not test real permission continuity,
cursor motion or hardware brightness behavior.

## Build, tests and delivery

Run `bash scripts/test.sh`, then `bash scripts/build-app.sh` on an arm64 Mac with
Swift 6+ and Command Line Tools. The test script validates release metadata,
runs Swift Testing core/runtime scenarios and the Python unittest suite. The build script
creates a release executable, embeds/thins Sparkle to arm64, removes unused sandbox
XPC services, generates metadata/icons, installs licenses and signs the bundle.
Default build/cache and output paths are under `~/Library/Developer/Awake`, outside
Documents. See release operations for environment overrides.

Without a release keychain the local bundle is ad hoc signed. Do not replace an
installed stable app with it. Release identity is the pinned public certificate
plus the existing private key, distinct from Sparkle's Ed25519 update key.

| Delivery layer | Contract |
| --- | --- |
| `release.py` | Validate configuration; generate plist; fetch the previous feed; verify and package the app; generate/verify the signed DMG and appcast; record artifact hashes. |
| `signing.py` | Import the pinned identity in CI, restore keychain search lists, sign/verify all selected app/updater components. |
| `licenses.py` | Validate approved MIT terms and dependency notices, then preserve exact copies in app and disk image. |
| `publish.py` | Validate artifact hashes/metadata and tag/commit/feed state; publish exact DMG bytes; stage Pages only after download readback; verify convergence with bounded transient-error retries, then check latest release before deleting older DMGs. |
| `.github/workflows/release.yml` | PR checks without secrets; signed preparation on non-PR runs; publication only for matching tags; serialized release runs. |

The Linux publisher relies on signature verification performed by the macOS
packaging job and on transfer of that job's artifact. Its SHA-256 manifest checks
byte consistency; they are not an independent cryptographic signature trust root.
GitHub Releases hosts the DMG; GitHub Pages hosts the single-entry signed appcast.
For recovery, identity continuity and publication restrictions, use the release guide.

## Resource costs and design tradeoffs

Motion computation is constant work per frame. Brightness interpolation performs
one fixed 24-iteration curve solve per frame and then work linear in the displays
in the transition. Display reads/enumeration occur at transition creation and
idle heartbeat calls, not for every cursor frame. There are no unbounded runtime
queues or user-data caches in these components.

The main actor keeps callback ordering and AppKit access explicit. The pure core
tests geometry and interpolation; injected environment, brightness access and
UserDefaults allow tests of the actual runtime controller with manual time and
callbacks. Keep these boundaries unless a specific regression or measured
bottleneck justifies another change. Sparkle supplies update verification and
installation; removing it would
require replacing those responsibilities. No CPU, energy or startup improvement
has been measured by the current audit.
