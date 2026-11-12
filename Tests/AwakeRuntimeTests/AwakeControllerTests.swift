import Foundation
import CoreGraphics
import Testing
import IOKit.ps
import AwakeCore
@testable import AwakeRuntime

@MainActor
private final class FakeEnvironment: AwakeEnvironment {
    var now: TimeInterval = 100
    var supply: PowerSupply = .externalPower
    var cursorAccess = true
    var sessionIsUsable = true
    var keyIdle = TimeInterval.infinity
    var buttonsAreDown = false
    var pointer: CGPoint? = CGPoint(x: 400, y: 300)
    var tapIsEnabled = false
    var preventingIdleSleep = false
    var tapAvailable = true
    var assertionAvailable = true
    var movementAvailable = true
    var refresh: (@MainActor () -> Void)?
    var activity: (@MainActor (Int64) -> Void)?
    var suspension: (@MainActor (Bool) -> Void)?
    var motionFrame: (@MainActor () -> Void)?
    var brightnessFrame: (@MainActor () -> Void)?
    var posted: [(CGPoint, Int64)] = []
    var starts = 0
    var stops = 0

    func start(refresh: @escaping @MainActor () -> Void, activity: @escaping @MainActor (Int64) -> Void,
               suspension: @escaping @MainActor (Bool) -> Void) {
        starts += 1
        self.refresh = refresh
        self.activity = activity
        self.suspension = suspension
    }
    func stop() {
        stops += 1
        refresh = nil; activity = nil; suspension = nil
        motionFrame = nil; brightnessFrame = nil
        tapIsEnabled = false; preventingIdleSleep = false
    }
    func installTap() -> Bool { tapIsEnabled = tapAvailable; return tapAvailable }
    func removeTap() { tapIsEnabled = false }
    func holdSleepAssertion() -> Bool {
        if preventingIdleSleep { return true }
        preventingIdleSleep = assertionAvailable
        return preventingIdleSleep
    }
    func releaseSleepAssertion() { preventingIdleSleep = false }
    func display(at point: CGPoint) -> (id: CGDirectDisplayID, bounds: CGRect)? {
        (1, CGRect(x: 0, y: 0, width: 1440, height: 900))
    }
    func startMotion(on display: CGDirectDisplayID, frame: @escaping @MainActor () -> Void) { motionFrame = frame }
    func stopMotion() { motionFrame = nil }
    func postMovement(to point: CGPoint, marker: Int64) -> Bool {
        guard movementAvailable else { return false }
        pointer = point
        posted.append((point, marker))
        return true
    }
    func setBrightnessFrame(_ frame: (@MainActor () -> Void)?) { brightnessFrame = frame }
    func openPermissionSettings() -> Bool { false }
    func tick(at time: TimeInterval) { now = time; refresh?() }
    func brightness(at time: TimeInterval) { now = time; brightnessFrame?() }
}

@MainActor
private final class FakeBrightness: DisplayBrightnessAccess {
    var displays: [String: Float] = ["internal": 0.8125]
    var failing: Set<String> = []
    var writes: [(String, Float)] = []
    func levels() -> [String: Float] { displays }
    func setLevel(_ value: Float, for display: String) -> Bool {
        guard !failing.contains(display), displays[display] != nil else { return false }
        displays[display] = value
        writes.append((display, value))
        return true
    }
}

@MainActor
private final class Runtime {
    let environment = FakeEnvironment()
    let brightness = FakeBrightness()
    let suite = "com.vitalyterenin.awake.runtime-tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let controller: AwakeController

    init(dimming: Bool = false, saved: [String: Float] = [:], cursorMotion: Bool? = nil) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(1, forKey: "motionDelayMinutes")
        defaults.set(dimming, forKey: "dimWhileIdle")
        if let cursorMotion { defaults.set(cursorMotion, forKey: "moveCursorWhileIdle") }
        if !saved.isEmpty { defaults.set(saved, forKey: "pendingBrightnessRestore") }
        controller = AwakeController(environment: environment, brightness: brightness, defaults: defaults)
    }
    var journal: [String: Float] {
        (defaults.dictionary(forKey: "pendingBrightnessRestore") ?? [:]).compactMapValues { ($0 as? NSNumber)?.floatValue }
    }
    func close() { controller.didChange = nil; controller.stop(); defaults.removePersistentDomain(forName: suite) }
    func startMoving() { controller.start(); environment.tick(at: 160) }
    func finishDimming() { startMoving(); environment.brightness(at: 165) }
}

@Test @MainActor func permissionLossStopsMotionRestoresAndStartsFreshOnReturn() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.finishDimming()
    #expect(runtime.controller.moving)
    #expect(env.preventingIdleSleep)
    #expect(runtime.brightness.displays["internal"] == IdleDimming.minimumLevel)
    env.cursorAccess = false
    env.tick(at: 170)
    #expect(runtime.controller.cursorControlState == .permissionRequired)
    #expect(!runtime.controller.moving && !env.preventingIdleSleep && !env.tapIsEnabled)
    env.brightness(at: 170.5)
    #expect(runtime.brightness.displays["internal"] == 0.8125)
    #expect(runtime.journal.isEmpty)
    env.cursorAccess = true
    env.tick(at: 171)
    #expect(runtime.controller.cursorControlState == .ready)
    #expect(env.preventingIdleSleep && !runtime.controller.moving)
    env.tick(at: 229.9)
    #expect(!runtime.controller.moving)
    env.tick(at: 230)
    #expect(runtime.controller.moving)
}

@Test @MainActor func blockedStartupAndTapLossNeverKeepSleepOrMotionActive() {
    let runtime = Runtime()
    defer { runtime.close() }
    let env = runtime.environment
    env.cursorAccess = false
    runtime.controller.start()
    #expect(runtime.controller.message == "Permission required")
    #expect(!env.tapIsEnabled && !env.preventingIdleSleep)
    env.cursorAccess = true
    env.tapAvailable = false
    env.tick(at: 120)
    #expect(runtime.controller.cursorControlState == .monitoringUnavailable)
    #expect(!env.preventingIdleSleep && !runtime.controller.moving)
    env.tapAvailable = true
    env.tick(at: 121)
    #expect(runtime.controller.cursorControlState == .ready)
    env.tick(at: 180)
    #expect(runtime.controller.moving)
    env.tapAvailable = false
    env.tapIsEnabled = false
    env.motionFrame?()
    #expect(!runtime.controller.moving)
    env.tick(at: 181)
    #expect(!env.preventingIdleSleep)
    #expect(runtime.controller.message == "Input detection unavailable")
}

@Test @MainActor func assertionFailureBlocksMovementAndRecoversWithoutLosingPreferences() {
    let runtime = Runtime()
    defer { runtime.close() }
    let env = runtime.environment
    env.assertionAvailable = false
    runtime.startMoving()
    #expect(runtime.controller.message == "Unable to prevent sleep")
    #expect(!env.preventingIdleSleep && !runtime.controller.moving)
    env.assertionAvailable = true
    env.tick(at: 161)
    #expect(env.preventingIdleSleep && runtime.controller.moving)
    #expect(runtime.defaults.bool(forKey: "keepAwake"))
    #expect(runtime.defaults.integer(forKey: "motionDelayMinutes") == 1)
}

@Test @MainActor func stationaryModeKeepsSleepAssertionWithoutPointerOrMotionAndPersists() {
    let runtime = Runtime()
    defer { runtime.close() }
    let env = runtime.environment
    #expect(runtime.controller.moveCursorWhileIdle)
    runtime.controller.start()
    runtime.controller.setMoveCursorWhileIdle(false)
    env.pointer = nil
    for time in [101.0, 160.0, 800.0] {
        env.tick(at: time)
        #expect(env.preventingIdleSleep && !runtime.controller.moving)
        #expect(env.motionFrame == nil && env.posted.isEmpty)
        #expect(runtime.controller.message == "Keeping Mac awake")
    }
    let restored = AwakeController(environment: FakeEnvironment(), brightness: FakeBrightness(), defaults: runtime.defaults)
    #expect(!restored.moveCursorWhileIdle)
    runtime.controller.setEnabled(false)
    #expect(!env.preventingIdleSleep)
}

@Test @MainActor func switchingModesRestoresBrightnessAndPreservesDimmingWithoutMotion() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.startMoving()
    env.brightness(at: 162)
    runtime.controller.setMoveCursorWhileIdle(false)
    #expect(!runtime.controller.moving && env.motionFrame == nil && env.preventingIdleSleep)
    #expect(runtime.controller.message == "Dimming in 1:00")
    env.brightness(at: 162.5)
    #expect(runtime.journal.isEmpty && runtime.brightness.displays["internal"] == 0.8125)
    env.tick(at: 222)
    env.brightness(at: 227)
    #expect(runtime.controller.message == "Display dimmed")
    #expect(!runtime.controller.moving && env.motionFrame == nil && env.posted.isEmpty)
    #expect(env.preventingIdleSleep && runtime.journal == ["internal": 0.8125])
    env.activity?(0)
    env.brightness(at: 227.5)
    #expect(runtime.journal.isEmpty && runtime.brightness.displays["internal"] == 0.8125)
    runtime.controller.setMoveCursorWhileIdle(true)
    #expect(!runtime.controller.moving && env.preventingIdleSleep)
    env.tick(at: 287.5)
    #expect(runtime.controller.moving && env.motionFrame != nil)
    env.now = 289.5
    env.motionFrame?()
    #expect(abs(env.pointer!.x - 424) < 0.000001)
}

@Test @MainActor func stationaryDimmingFailureAndSuspensionPreserveRecovery() {
    let runtime = Runtime(dimming: true, cursorMotion: false)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.brightness.failing = ["internal"]
    runtime.controller.start()
    env.tick(at: 160)
    env.brightness(at: 161)
    #expect(runtime.controller.message == "Keeping awake · brightness unavailable")
    #expect(!runtime.controller.moving && env.preventingIdleSleep)
    #expect(runtime.journal == ["internal": 0.8125])
    runtime.brightness.failing = []
    env.suspension?(true)
    #expect(runtime.journal.isEmpty && !env.preventingIdleSleep)
    env.suspension?(false)
    #expect(env.preventingIdleSleep && runtime.controller.message == "Dimming in 1:00")
}

@Test @MainActor func batteryAndUnknownPowerPauseWithBrightnessRecoveryAndFreshCountdowns() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.finishDimming()
    env.supply = .battery
    env.tick(at: 170)
    #expect(runtime.controller.message == "Paused · on battery")
    #expect(!env.preventingIdleSleep && !runtime.controller.moving)
    env.brightness(at: 170.5)
    #expect(runtime.journal.isEmpty)
    runtime.controller.setAllowOnBattery(true)
    #expect(env.preventingIdleSleep && !runtime.controller.moving)
    #expect(runtime.defaults.bool(forKey: "allowOnBattery"))
    env.tick(at: 230.5)
    #expect(runtime.controller.moving)
    env.supply = .unknown
    env.tick(at: 231)
    #expect(runtime.controller.message == "Paused · power unavailable")
    #expect(!env.preventingIdleSleep && !runtime.controller.moving)
    env.supply = .externalPower
    env.tick(at: 240)
    #expect(runtime.controller.message == "Motion in 1:00")
    #expect(env.preventingIdleSleep)
    env.tick(at: 299.9)
    #expect(!runtime.controller.moving)
    env.tick(at: 300)
    #expect(runtime.controller.moving)
}

@Test @MainActor func suspensionRestoresImmediatelyAndInactiveSessionStillBlocksResume() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.startMoving()
    env.brightness(at: 162)
    #expect(runtime.brightness.displays["internal"]! < 0.8125)
    env.suspension?(true)
    #expect(!runtime.controller.moving && !env.preventingIdleSleep)
    #expect(runtime.brightness.displays["internal"] == 0.8125)
    #expect(runtime.journal.isEmpty && env.brightnessFrame == nil)
    env.sessionIsUsable = false
    env.now = 170
    env.suspension?(false)
    #expect(runtime.controller.message == "Paused · session inactive")
    #expect(!env.preventingIdleSleep)
    env.sessionIsUsable = true
    env.tick(at: 171)
    #expect(env.preventingIdleSleep && !runtime.controller.moving)
    env.tick(at: 229.9)
    #expect(!runtime.controller.moving)
    env.tick(at: 230)
    #expect(runtime.controller.moving)
}

@Test @MainActor func startupRecoveryRetainsDisconnectedAndFailedDisplaysUntilSuccessfulRetry() {
    let runtime = Runtime(saved: ["internal": 0.8125, "external": 0.5])
    defer { runtime.close() }
    let env = runtime.environment
    runtime.brightness.displays["internal"] = IdleDimming.minimumLevel
    runtime.controller.start()
    #expect(runtime.brightness.displays["internal"] == 0.8125)
    #expect(runtime.journal == ["external": 0.5])
    runtime.brightness.displays["external"] = IdleDimming.minimumLevel
    runtime.brightness.failing = ["external"]
    env.tick(at: 101)
    env.brightness(at: 101.5)
    #expect(runtime.journal == ["external": 0.5])
    #expect(env.brightnessFrame == nil)
    runtime.brightness.failing = []
    env.tick(at: 102)
    env.brightness(at: 102.5)
    #expect(runtime.brightness.displays["external"] == 0.5)
    #expect(runtime.journal.isEmpty)
}

@Test @MainActor func quitDuringFadeRestoresImmediatelyAndCancelsEveryCallback() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.startMoving()
    runtime.controller.start()
    #expect(env.starts == 1)
    env.brightness(at: 162)
    let staleRefresh = env.refresh
    runtime.controller.stop()
    #expect(runtime.brightness.displays["internal"] == 0.8125)
    #expect(runtime.journal.isEmpty)
    #expect(!runtime.controller.moving && !env.preventingIdleSleep && !env.tapIsEnabled)
    #expect(env.refresh == nil && env.activity == nil && env.suspension == nil)
    #expect(env.motionFrame == nil && env.brightnessFrame == nil)
    runtime.controller.stop()
    staleRefresh?()
    #expect(env.stops == 1)
    #expect(!env.preventingIdleSleep && !runtime.controller.moving)
}

@Test @MainActor func unsuccessfulQuitRestorationKeepsTheJournal() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    runtime.finishDimming()
    runtime.brightness.failing = ["internal"]
    runtime.controller.stop()
    #expect(runtime.journal == ["internal": 0.8125])
    #expect(runtime.environment.brightnessFrame == nil)
    #expect(!runtime.environment.preventingIdleSleep)
}

@Test @MainActor func activityDelayChangesAndSecureInputResetTheCountdown() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.startMoving()
    env.now = 160.1
    env.motionFrame?()
    #expect(env.posted.count == 1 && env.posted[0].1 == IdleMotion.eventMarker)
    env.activity?(IdleMotion.eventMarker)
    #expect(runtime.controller.moving)
    env.brightness(at: 162)
    env.activity?(0)
    #expect(!runtime.controller.moving)
    env.brightness(at: 162.5)
    #expect(runtime.brightness.displays["internal"] == 0.8125)
    env.tick(at: 200)
    runtime.controller.setMotionDelay(.fiveMinutes)
    #expect(runtime.defaults.integer(forKey: "motionDelayMinutes") == 5)
    env.tick(at: 499)
    #expect(!runtime.controller.moving)
    env.buttonsAreDown = true
    env.tick(at: 500)
    #expect(!runtime.controller.moving)
    env.buttonsAreDown = false
    env.tick(at: 501)
    #expect(runtime.controller.moving)
    env.keyIdle = 0.25
    env.tick(at: 502)
    #expect(!runtime.controller.moving)
    #expect(runtime.controller.message == "Motion in 5:00")
}

@Test @MainActor func failedDimmingStaysUnavailableThroughRetryAndRecoversOnSuccessfulWrites() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.brightness.failing = ["internal"]
    runtime.startMoving()
    var observed: [String] = []
    runtime.controller.didChange = { observed.append(runtime.controller.message) }
    env.brightness(at: 160.1)
    let unavailable = "Cursor moving · brightness unavailable"
    #expect(runtime.controller.message == unavailable)
    #expect(runtime.brightness.displays["internal"] == 0.8125)
    #expect(runtime.journal == ["internal": 0.8125])
    #expect(runtime.controller.moving && env.preventingIdleSleep)
    for time in [161.0, 162.0, 163.0] {
        env.tick(at: time)
        #expect(runtime.controller.message == unavailable)
        env.brightness(at: time + 0.1)
        #expect(runtime.controller.message == unavailable)
    }
    #expect(observed.allSatisfy { $0 == unavailable })
    runtime.brightness.failing = []
    env.tick(at: 164)
    #expect(runtime.controller.message == unavailable)
    env.brightness(at: 164.1)
    #expect(runtime.controller.message == "Dimming display")
    env.brightness(at: 169)
    #expect(runtime.controller.message == "Display dimmed")
    #expect(env.brightnessFrame == nil)
    #expect(runtime.journal == ["internal": 0.8125])
}

@Test @MainActor func partialDimmingFailureIsVisibleUntilTheFailedDisplayRecovers() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.brightness.displays["external"] = 0.5
    runtime.brightness.failing = ["external"]
    runtime.startMoving()
    env.brightness(at: 165)
    #expect(runtime.controller.message == "Cursor moving · some displays unavailable")
    #expect(runtime.brightness.displays["internal"] == IdleDimming.minimumLevel)
    #expect(runtime.brightness.displays["external"] == 0.5)
    #expect(runtime.journal.count == 2)
    env.tick(at: 166)
    #expect(runtime.controller.message == "Cursor moving · some displays unavailable")
    runtime.brightness.failing = []
    env.brightness(at: 171)
    #expect(runtime.controller.message == "Display dimmed")
    runtime.controller.setDimWhileIdle(false)
    env.brightness(at: 171.5)
    #expect(runtime.brightness.displays == ["internal": 0.8125, "external": 0.5])
    #expect(runtime.journal.isEmpty)
    #expect(runtime.controller.moving && runtime.controller.message == "Moving cursor")
}

@Test @MainActor func disabledRuntimeRetriesFailedRestorationWithoutHoldingSleep() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.finishDimming()
    runtime.brightness.failing = ["internal"]
    runtime.controller.setEnabled(false)
    env.brightness(at: 165.5)
    #expect(runtime.controller.message == "Off")
    #expect(!runtime.controller.moving && !env.preventingIdleSleep && !env.tapIsEnabled)
    #expect(runtime.journal == ["internal": 0.8125])
    runtime.brightness.failing = []
    env.tick(at: 166)
    env.brightness(at: 166.5)
    #expect(runtime.journal.isEmpty)
    #expect(runtime.brightness.displays["internal"] == 0.8125)
    runtime.controller.setEnabled(true)
    #expect(runtime.controller.message == "Motion in 1:00")
    #expect(env.preventingIdleSleep && !runtime.controller.moving)
}

@Test @MainActor func turningOffDimmingRetriesRestorationWhileCursorKeepsMoving() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.finishDimming()
    #expect(runtime.brightness.displays["internal"] == IdleDimming.minimumLevel)

    runtime.brightness.failing = ["internal"]
    runtime.controller.setDimWhileIdle(false)
    env.brightness(at: 165.5)
    #expect(runtime.brightness.displays["internal"] == IdleDimming.minimumLevel)
    #expect(runtime.journal == ["internal": 0.8125])

    runtime.brightness.failing = []
    env.tick(at: 165.75)
    #expect(env.brightnessFrame == nil)
    env.tick(at: 166)
    env.brightness(at: 166.25)
    #expect((runtime.brightness.displays["internal"] ?? 0) > IdleDimming.minimumLevel)
    #expect(runtime.journal == ["internal": 0.8125])
    env.brightness(at: 166.5)
    #expect(runtime.brightness.displays["internal"] == 0.8125)
    #expect(runtime.journal.isEmpty)

    env.motionFrame?()
    #expect(runtime.controller.moving && runtime.controller.message == "Moving cursor")
    #expect(env.posted.count == 1)
}

@Test @MainActor func missingSnapshotStopsTheControllerAndLaterReadRestartsCountdown() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    var snapshotAvailable = true
    let monitor = PowerSourceMonitor(copySnapshot: {
        snapshotAvailable ? Unmanaged.passRetained("snapshot" as CFTypeRef) : nil
    }, sourceType: { _ in kIOPSACPowerValue })
    runtime.finishDimming()
    snapshotAvailable = false
    env.supply = monitor.current
    env.tick(at: 170)
    #expect(runtime.controller.message == "Paused · power unavailable")
    #expect(!runtime.controller.moving && !env.preventingIdleSleep)
    env.brightness(at: 170.5)
    #expect(runtime.journal.isEmpty)
    snapshotAvailable = true
    env.supply = monitor.current
    env.tick(at: 171)
    #expect(runtime.controller.message == "Motion in 1:00")
    #expect(env.preventingIdleSleep && !runtime.controller.moving)
}

@Test @MainActor func unreadableBrightnessLeavesCursorWorkingWithoutInventingRecoveryValues() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    runtime.brightness.displays = [:]
    runtime.startMoving()
    #expect(runtime.controller.message == "Cursor moving · brightness unavailable")
    #expect(runtime.controller.moving && runtime.environment.preventingIdleSleep)
    #expect(runtime.journal.isEmpty && runtime.environment.brightnessFrame == nil)
    runtime.brightness.displays["internal"] = 0.8125
    runtime.environment.tick(at: 161)
    runtime.environment.brightness(at: 166)
    #expect(runtime.controller.message == "Display dimmed")
    #expect(runtime.journal == ["internal": 0.8125])
}

@Test @MainActor func pointerDisplacementAndFailedPostingStopMovementWithoutPostingOverUserInput() {
    let runtime = Runtime()
    defer { runtime.close() }
    let env = runtime.environment
    runtime.startMoving()
    env.pointer = CGPoint(x: 500, y: 300)
    env.motionFrame?()
    #expect(!runtime.controller.moving && env.posted.isEmpty)
    env.tick(at: 220)
    #expect(runtime.controller.moving)
    env.movementAvailable = false
    env.motionFrame?()
    #expect(!runtime.controller.moving && env.posted.isEmpty)
    env.tick(at: 279.9)
    #expect(!runtime.controller.moving)
}

@Test @MainActor func staleCallbacksCannotRestartCleanupAfterFailedQuitRestoration() {
    let runtime = Runtime(dimming: true)
    defer { runtime.close() }
    let env = runtime.environment
    runtime.startMoving()
    env.brightness(at: 162)
    let refresh = env.refresh
    let activity = env.activity
    let suspension = env.suspension
    let motionFrame = env.motionFrame
    let brightnessFrame = env.brightnessFrame
    runtime.brightness.failing = ["internal"]
    runtime.controller.stop()
    #expect(runtime.journal == ["internal": 0.8125])
    let writes = runtime.brightness.writes.count
    let posted = env.posted.count
    env.now = 500
    refresh?(); activity?(0); suspension?(true); suspension?(false)
    motionFrame?(); brightnessFrame?()
    #expect(runtime.brightness.writes.count == writes && env.posted.count == posted)
    #expect(runtime.journal == ["internal": 0.8125])
    #expect(!runtime.controller.moving && !env.preventingIdleSleep)
    #expect(env.motionFrame == nil && env.brightnessFrame == nil)
}
