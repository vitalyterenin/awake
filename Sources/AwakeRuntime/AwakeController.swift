import Foundation
import CoreGraphics
import AwakeCore

package enum CursorControlState {
    case permissionRequired, monitoringUnavailable, ready
}

@MainActor
package final class AwakeController {
    package var didChange: (() -> Void)?
    package private(set) var enabled: Bool
    package private(set) var message = "Starting…"
    package private(set) var moving = false
    package private(set) var moveCursorWhileIdle: Bool
    private var idleActive = false
    package private(set) var dimWhileIdle: Bool
    package private(set) var allowOnBattery: Bool
    private let environment: any AwakeEnvironment
    private let defaults: UserDefaults
    private var motion: IdleMotion
    private let dimming: IdleDimming
    private var supply: PowerSupply = .unknown
    private var cursorAccessGranted = false
    private var inputMonitoringFailed = false
    private var lastRestoreAttempt: TimeInterval = -.infinity
    private var motionFrames = 0
    private var suspended = false
    private var lastPostedPoint: CGPoint?
    private var started = false

    package convenience init() {
        self.init(environment: SystemAwakeEnvironment(), brightness: SystemBrightness(), defaults: .standard)
    }

    init(environment: any AwakeEnvironment, brightness: any DisplayBrightnessAccess, defaults: UserDefaults) {
        self.environment = environment
        self.defaults = defaults
        defaults.register(defaults: ["keepAwake": true, "motionDelayMinutes": 5,
                                     "dimWhileIdle": false, "allowOnBattery": false,
                                     "moveCursorWhileIdle": true])
        enabled = defaults.bool(forKey: "keepAwake")
        moveCursorWhileIdle = defaults.bool(forKey: "moveCursorWhileIdle")
        dimWhileIdle = defaults.bool(forKey: "dimWhileIdle")
        allowOnBattery = defaults.bool(forKey: "allowOnBattery")
        let saved = (defaults.dictionary(forKey: "pendingBrightnessRestore") ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.floatValue }
        dimming = IdleDimming(backend: brightness, savedLevels: saved) { levels in
            if levels.isEmpty { defaults.removeObject(forKey: "pendingBrightnessRestore") }
            else { defaults.set(levels, forKey: "pendingBrightnessRestore") }
        }
        let delay = MotionDelay(rawValue: defaults.integer(forKey: "motionDelayMinutes")) ?? .fiveMinutes
        motion = IdleMotion(now: environment.now, delay: delay)
    }

    package var needsPermission: Bool { !environment.cursorAccess }
    package var cursorControlState: CursorControlState {
        if needsPermission { return .permissionRequired }
        return inputMonitoringFailed ? .monitoringUnavailable : .ready
    }
    package func recheckCursorControl() { tick() }
    package var motionDelay: MotionDelay { motion.delay }
    package var diagnostics: [String: Any] {
        ["message": message, "enabled": enabled, "moving": moving,
         "moveCursorWhileIdle": moveCursorWhileIdle, "idleActive": idleActive,
         "cursorAccess": !needsPermission, "delayMinutes": motion.delay.rawValue,
         "inputMonitoringFailed": inputMonitoringFailed,
         "dimWhileIdle": dimWhileIdle, "allowOnBattery": allowOnBattery,
         "onBattery": supply == .battery, "powerSourceKnown": supply != .unknown,
         "preventingIdleSleep": environment.preventingIdleSleep, "savedBrightnessDisplays": dimming.savedLevels.count,
         "motionFrames": motionFrames, "brightnessTransition": dimming.transitionName]
    }

    package func setDimWhileIdle(_ value: Bool) {
        dimWhileIdle = value
        defaults.set(value, forKey: "dimWhileIdle")
        if started && !value { restoreBrightness(force: true) }
        tick()
    }

    package func setAllowOnBattery(_ value: Bool) {
        allowOnBattery = value
        defaults.set(value, forKey: "allowOnBattery")
        input(at: environment.now)
        tick()
    }

    package func setMotionDelay(_ delay: MotionDelay) {
        defaults.set(delay.rawValue, forKey: "motionDelayMinutes")
        motion.setDelay(delay, at: environment.now)
        if started { stopMotion() }
        tick()
    }

    package func setMoveCursorWhileIdle(_ value: Bool) {
        moveCursorWhileIdle = value
        defaults.set(value, forKey: "moveCursorWhileIdle")
        input(at: environment.now)
        tick()
    }

    package func start() {
        guard !started else { return }
        started = true
        dimming.restore()
        supply = environment.supply
        environment.start(refresh: { [weak self] in self?.tick() }, activity: { [weak self] marker in
            guard let self else { return }
            self.input(at: self.environment.now, marker: marker)
        }, suspension: { [weak self] suspended in
            if suspended { self?.suspend() } else { self?.resume() }
        })
        tick()
    }

    package func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "keepAwake")
        input(at: environment.now)
        tick()
    }

    @discardableResult
    package func requestPermission() -> Bool { environment.openPermissionSettings() }

    package func stop() {
        guard started else { return }
        started = false
        stopMotion()
        environment.releaseSleepAssertion()
        environment.removeTap()
        restoreBrightness(force: true, immediately: true)
        environment.stop()
    }

    private func suspend() {
        guard started else { return }
        suspended = true
        input(at: environment.now)
        restoreBrightness(force: true, immediately: true)
        environment.releaseSleepAssertion()
        tick()
    }

    private func resume() {
        guard started else { return }
        suspended = false
        input(at: environment.now)
        tick()
    }

    private func input(at now: TimeInterval, marker: Int64 = 0) {
        guard started, marker != IdleMotion.eventMarker else { return }
        motion.activity(at: now)
        stopMotion()
    }

    private func tick() {
        guard started else { return }
        defer { didChange?() }
        // Notifications provide immediate updates; polling also covers an unavailable source.
        let currentSupply = environment.supply
        if currentSupply != supply {
            supply = currentSupply
            input(at: environment.now)
        }
        guard enabled else {
            stopMotion(); environment.removeTap(); environment.releaseSleepAssertion()
            message = "Off"
            return
        }
        guard supply.permitsAwake(allowBattery: allowOnBattery) else {
            input(at: environment.now)
            environment.removeTap(); environment.releaseSleepAssertion()
            message = supply == .battery ? "Paused · on battery" : "Paused · power unavailable"
            return
        }
        cursorAccessGranted = !needsPermission
        guard cursorAccessGranted else {
            inputMonitoringFailed = false
            stopMotion(); environment.removeTap(); environment.releaseSleepAssertion()
            motion.activity(at: environment.now)
            message = "Permission required"
            return
        }
        guard !suspended, environment.sessionIsUsable else {
            input(at: environment.now)
            environment.releaseSleepAssertion()
            message = "Paused · session inactive"
            return
        }
        guard environment.installTap() else {
            inputMonitoringFailed = true
            input(at: environment.now)
            environment.releaseSleepAssertion()
            message = "Input detection unavailable"
            return
        }
        inputMonitoringFailed = false
        guard environment.holdSleepAssertion() else {
            stopMotion()
            message = "Unable to prevent sleep"
            return
        }
        let now = environment.now
        let keyIdle = environment.keyIdle
        if keyIdle.isFinite && now - keyIdle > motion.lastActivity + 0.01 {
            input(at: now - keyIdle)
        }
        if motion.isReady(at: now), !idleActive, !environment.buttonsAreDown {
            if !moveCursorWhileIdle {
                idleActive = true
            } else if let point = environment.pointer, let display = environment.display(at: point) {
                motion.begin(at: now, pointer: point, display: display.bounds)
                lastPostedPoint = point
                moving = true
                idleActive = true
                environment.startMotion(on: display.id) { [weak self] in self?.animate() }
            }
        }
        if idleActive {
            if dimWhileIdle {
                dimming.fadeDown(at: now)
                updateBrightnessClock()
                updateDimmingMessage()
            } else {
                restoreBrightness()
                message = moving ? "Moving cursor" : "Keeping Mac awake"
            }
        } else {
            restoreBrightness()
            let remaining = max(0, Int(ceil(motion.delay.seconds - (now - motion.lastActivity))))
            if moveCursorWhileIdle {
                message = String(format: "Motion in %d:%02d", remaining / 60, remaining % 60)
            } else if dimWhileIdle {
                message = String(format: "Dimming in %d:%02d", remaining / 60, remaining % 60)
            } else {
                message = "Keeping Mac awake"
            }
        }
    }

    private func animate() {
        guard started else { return }
        guard enabled, !suspended, cursorAccessGranted, supply.permitsAwake(allowBattery: allowOnBattery),
              environment.tapIsEnabled, let current = environment.pointer,
              let lastPostedPoint, hypot(current.x - lastPostedPoint.x, current.y - lastPostedPoint.y) < 1,
              let point = motion.point(at: environment.now),
              environment.postMovement(to: point, marker: IdleMotion.eventMarker) else {
            input(at: environment.now)
            return
        }
        motionFrames += 1
        self.lastPostedPoint = point
    }

    private func stopMotion() {
        let wasIdle = idleActive
        environment.stopMotion()
        moving = false
        idleActive = false
        lastPostedPoint = nil
        restoreBrightness(force: wasIdle)
    }

    private func restoreBrightness(force: Bool = false, immediately: Bool = false) {
        guard !dimming.savedLevels.isEmpty else { return }
        let now = environment.now
        guard force || now - lastRestoreAttempt >= 1 else { return }
        lastRestoreAttempt = now
        if immediately { dimming.restore() }
        else { dimming.fadeUp(at: now) }
        updateBrightnessClock()
    }

    private func updateDimmingMessage() {
        switch dimming.status {
        case .dimming: message = "Dimming display"
        case .dimmed: message = "Display dimmed"
        case .unavailable: message = moving ? "Cursor moving · brightness unavailable" : "Keeping awake · brightness unavailable"
        case .partiallyUnavailable: message = moving ? "Cursor moving · some displays unavailable" : "Keeping awake · some displays unavailable"
        }
    }

    private func updateBrightnessClock() {
        guard dimming.isAnimating else { environment.setBrightnessFrame(nil); return }
        environment.setBrightnessFrame { [weak self] in
            guard let self, self.started else { return }
            self.dimming.advance(to: self.environment.now)
            self.updateBrightnessClock()
            if self.idleActive && self.dimWhileIdle {
                let previous = self.message
                self.updateDimmingMessage()
                if self.message != previous { self.didChange?() }
            }
        }
    }
}
