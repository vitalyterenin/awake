import Testing
@testable import AwakeCore

@MainActor
private final class FakeBrightness: DisplayBrightnessAccess {
    var displays: [String: Float] = ["internal": 0.8125, "external": 0.5]
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

@Test @MainActor func brightnessRestoresTheOriginalValueAfterRepeatedIdleTicks() {
    let backend = FakeBrightness()
    var journal: [String: Float] = [:]
    let dim = IdleDimming(backend: backend) { journal = $0 }
    #expect(dim.dim())
    #expect(backend.displays["internal"] == 0.0625)
    #expect(journal["internal"] == 0.8125)
    backend.displays["internal"] = 0.4 // Ambient adjustment during idle.
    #expect(dim.dim())
    #expect(dim.savedLevels["internal"] == 0.8125)
    #expect(dim.restore())
    #expect(backend.displays == ["internal": 0.8125, "external": 0.5])
    #expect(journal.isEmpty)
}

@Test @MainActor func disconnectedDisplayKeepsItsRecoveryValue() {
    let backend = FakeBrightness()
    let dim = IdleDimming(backend: backend)
    #expect(dim.dim())
    backend.displays.removeValue(forKey: "external")
    #expect(!dim.restore())
    #expect(dim.savedLevels == ["external": 0.5])
    backend.displays["external"] = 0.0625
    #expect(dim.restore())
    #expect(backend.displays["external"] == 0.5)
}

@Test @MainActor func recoveryOnRestartAndFailureRetention() {
    let backend = FakeBrightness()
    backend.displays = ["internal": 0.0625]
    backend.failing = ["internal"]
    let dim = IdleDimming(backend: backend, savedLevels: ["internal": 0.8125, "invalid": .nan])
    #expect(!dim.restore())
    #expect(dim.savedLevels == ["internal": 0.8125])
    backend.failing = []
    #expect(dim.restore())
    #expect(backend.displays["internal"] == 0.8125)
}

@Test @MainActor func dimmingNeverRaisesAnAlreadyDarkDisplay() {
    let backend = FakeBrightness()
    backend.displays = ["internal": 0.01]
    let dim = IdleDimming(backend: backend)
    #expect(dim.dim())
    #expect(backend.displays["internal"] == 0.01)
    #expect(backend.writes.isEmpty)
    #expect(dim.savedLevels.isEmpty)
}

@Test func batteryOptInAndUnknownPowerSource() {
    #expect(PowerSupply.externalPower.permitsAwake(allowBattery: false))
    #expect(!PowerSupply.battery.permitsAwake(allowBattery: false))
    #expect(PowerSupply.battery.permitsAwake(allowBattery: true))
    #expect(!PowerSupply.unknown.permitsAwake(allowBattery: true))
}

@Test @MainActor func fiveSecondDimmingAndHalfSecondRestoration() {
    let backend = FakeBrightness()
    backend.displays = ["internal": 0.8125]
    let dim = IdleDimming(backend: backend)
    #expect(dim.fadeDown(at: 10))
    #expect(backend.displays["internal"] == 0.8125)
    #expect(dim.advance(to: 12.5))
    #expect(abs(backend.displays["internal"]! - 0.4375) < 0.0001)
    #expect(dim.fadeDown(at: 12.5)) // Heartbeat must not restart the fade.
    #expect(dim.advance(to: 15))
    #expect(backend.displays["internal"] == 0.0625)
    #expect(!dim.isAnimating)
    #expect(dim.savedLevels["internal"] == 0.8125)
    #expect(dim.fadeUp(at: 20))
    #expect(dim.advance(to: 20.25))
    #expect(abs(backend.displays["internal"]! - 0.4375) < 0.0001)
    #expect(!dim.savedLevels.isEmpty)
    #expect(dim.fadeUp(at: 20.4))
    #expect(dim.advance(to: 20.5))
    #expect(backend.displays["internal"] == 0.8125)
    #expect(dim.savedLevels.isEmpty)
    #expect(!dim.isAnimating)
}

@Test @MainActor func inputDuringDimmingReversesWithoutJumpOrExtendedRestoration() {
    let backend = FakeBrightness()
    backend.displays = ["internal": 0.8125]
    let dim = IdleDimming(backend: backend)
    #expect(dim.fadeDown(at: 0))
    #expect(dim.advance(to: 2))
    let interrupted = backend.displays["internal"]!
    #expect(interrupted > 0.0625 && interrupted < 0.8125)
    #expect(dim.fadeUp(at: 2))
    #expect(dim.advance(to: 2))
    #expect(backend.displays["internal"] == interrupted)
    for time in [2.1, 2.2, 2.4] {
        #expect(dim.fadeUp(at: time))
        #expect(dim.advance(to: time))
    }
    #expect(dim.advance(to: 2.5))
    #expect(backend.displays["internal"] == 0.8125)
    #expect(dim.savedLevels.isEmpty)
}

@Test @MainActor func bezierTimingUsesTimeCoordinateInBothDirections() {
    let backend = FakeBrightness()
    backend.displays = ["internal": 0.8125]
    let dim = IdleDimming(backend: backend)
    // Independent curve fixtures: t=1/4 gives (x,y)=(0.3390625,0.15625),
    // t=3/4 gives (0.6609375,0.84375). Linear time and smoothstep differ here.
    #expect(dim.fadeDown(at: 0))
    #expect(dim.advance(to: 5 * 0.3390625))
    #expect(abs(backend.displays["internal"]! - 0.6953125) < 0.0001)
    #expect(dim.advance(to: 5 * 0.6609375))
    #expect(abs(backend.displays["internal"]! - 0.1796875) < 0.0001)
    #expect(dim.advance(to: 5))
    #expect(dim.fadeUp(at: 10))
    #expect(dim.advance(to: 10 + 0.5 * 0.3390625))
    #expect(abs(backend.displays["internal"]! - 0.1796875) < 0.0001)
    #expect(dim.advance(to: 10 + 0.5 * 0.6609375))
    #expect(abs(backend.displays["internal"]! - 0.6953125) < 0.0001)
    #expect(dim.advance(to: 10.5))
    #expect(backend.displays["internal"] == 0.8125)
    #expect(dim.savedLevels.isEmpty)
}

@Test @MainActor func immediateCleanupCancelsAnUnfinishedFade() {
    let backend = FakeBrightness()
    backend.displays = ["internal": 0.8125]
    let dim = IdleDimming(backend: backend)
    #expect(dim.fadeDown(at: 0))
    #expect(dim.advance(to: 1))
    #expect(dim.restore())
    #expect(dim.advance(to: 100))
    #expect(backend.displays["internal"] == 0.8125)
    #expect(!dim.isAnimating)
}

@Test @MainActor func failedFadeRestorationKeepsRecoveryUntilRetrySucceeds() {
    let backend = FakeBrightness()
    backend.displays = ["internal": 0.8125]
    var journal: [String: Float] = [:]
    let dim = IdleDimming(backend: backend) { journal = $0 }
    #expect(dim.dim())
    #expect(dim.fadeUp(at: 10))
    #expect(dim.advance(to: 10.25))
    backend.failing = ["internal"]
    #expect(!dim.advance(to: 10.5))
    #expect(journal["internal"] == 0.8125)
    #expect(!dim.isAnimating)
    backend.failing = []
    #expect(dim.fadeUp(at: 11))
    #expect(dim.advance(to: 11.5))
    #expect(backend.displays["internal"] == 0.8125)
    #expect(journal.isEmpty)
}
