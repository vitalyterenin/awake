import AppKit
@preconcurrency import ApplicationServices
import IOKit.pwr_mgt
import AwakeCore

enum CursorControlState {
    case permissionRequired, monitoringUnavailable, ready
}

@MainActor
final class AwakeController {
    var didChange: (() -> Void)?
    private(set) var enabled: Bool
    private(set) var message = "Starting…"
    private(set) var moving = false
    private(set) var dimWhileIdle: Bool
    private(set) var allowOnBattery: Bool
    private var motion: IdleMotion
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var heartbeat: Timer?
    private let animation = CursorAnimationClock()
    private let power = PowerSourceMonitor()
    private let dimming: IdleDimming
    private var brightnessTimer: Timer?
    private var supply: PowerSupply = .unknown
    private var cursorAccessGranted = false
    private var inputMonitoringFailed = false
    private var lastRestoreAttempt: TimeInterval = -.infinity
    private var motionFrames = 0
    private var assertion: IOPMAssertionID = 0
    private var suspended = false
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var lastPostedPoint: CGPoint?
    private let source = CGEventSource(stateID: .privateState)

    init() {
        UserDefaults.standard.register(defaults: ["keepAwake": true, "motionDelayMinutes": 5,
                                                 "dimWhileIdle": false, "allowOnBattery": false])
        enabled = UserDefaults.standard.bool(forKey: "keepAwake")
        dimWhileIdle = UserDefaults.standard.bool(forKey: "dimWhileIdle")
        allowOnBattery = UserDefaults.standard.bool(forKey: "allowOnBattery")
        let saved = (UserDefaults.standard.dictionary(forKey: "pendingBrightnessRestore") ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.floatValue }
        dimming = IdleDimming(backend: SystemBrightness(), savedLevels: saved) { levels in
            if levels.isEmpty { UserDefaults.standard.removeObject(forKey: "pendingBrightnessRestore") }
            else { UserDefaults.standard.set(levels, forKey: "pendingBrightnessRestore") }
        }
        let delay = MotionDelay(rawValue: UserDefaults.standard.integer(forKey: "motionDelayMinutes")) ?? .fiveMinutes
        motion = IdleMotion(now: ProcessInfo.processInfo.systemUptime, delay: delay)
    }

    var needsPermission: Bool { !AXIsProcessTrusted() }
    var cursorControlState: CursorControlState {
        if needsPermission { return .permissionRequired }
        return inputMonitoringFailed ? .monitoringUnavailable : .ready
    }
    func recheckCursorControl() { tick() }
    var motionDelay: MotionDelay { motion.delay }
    var diagnostics: [String: Any] {
        ["message": message, "enabled": enabled, "moving": moving,
         "cursorAccess": !needsPermission, "delayMinutes": motion.delay.rawValue,
         "inputMonitoringFailed": inputMonitoringFailed,
         "dimWhileIdle": dimWhileIdle, "allowOnBattery": allowOnBattery,
         "onBattery": supply == .battery, "powerSourceKnown": supply != .unknown,
         "preventingIdleSleep": assertion != 0, "savedBrightnessDisplays": dimming.savedLevels.count,
         "motionFrames": motionFrames, "brightnessTransition": dimming.transitionName]
    }

    func setDimWhileIdle(_ value: Bool) {
        dimWhileIdle = value
        UserDefaults.standard.set(value, forKey: "dimWhileIdle")
        if !value { restoreBrightness(force: true) }
        tick()
    }

    func setAllowOnBattery(_ value: Bool) {
        allowOnBattery = value
        UserDefaults.standard.set(value, forKey: "allowOnBattery")
        input(at: ProcessInfo.processInfo.systemUptime)
        tick()
    }

    func setMotionDelay(_ delay: MotionDelay) {
        UserDefaults.standard.set(delay.rawValue, forKey: "motionDelayMinutes")
        motion.setDelay(delay, at: ProcessInfo.processInfo.systemUptime)
        stopMotion()
        tick()
    }

    func start() {
        dimming.restore()
        supply = power.current
        power.didChange = { [weak self] in self?.tick() }
        power.start()
        animation.frame = { [weak self] in self?.animate() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.input(at: ProcessInfo.processInfo.systemUptime) }
        }
        heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        tick()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "keepAwake")
        input(at: ProcessInfo.processInfo.systemUptime)
        tick()
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        stopMotion()
        releaseSleepAssertion()
        removeTap()
        power.stop()
        restoreBrightness(force: true, immediately: true)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func suspend() {
        suspended = true
        input(at: ProcessInfo.processInfo.systemUptime)
        restoreBrightness(force: true, immediately: true)
        releaseSleepAssertion()
        tick()
    }

    private func resume() {
        suspended = false
        input(at: ProcessInfo.processInfo.systemUptime)
        tick()
    }

    private var sessionIsUsable: Bool {
        guard !suspended, let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // The WindowServer lock indicator is optional; missing sessions fail closed.
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    private func input(at now: TimeInterval, marker: Int64 = 0) {
        guard marker != IdleMotion.eventMarker else { return }
        motion.activity(at: now)
        stopMotion()
    }

    private func installTap() -> Bool {
        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return CGEvent.tapIsEnabled(tap: eventTap)
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
            .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // An unchanged active tap uses Accessibility permission and avoids requesting
        // a second Input Monitoring permission. Every event is returned untouched.
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                MainActor.assumeIsolated {
                    let owner = Unmanaged<AwakeController>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.input(at: ProcessInfo.processInfo.systemUptime)
                        if let tap = owner.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else {
                        owner.input(at: ProcessInfo.processInfo.systemUptime,
                                    marker: event.getIntegerValueField(.eventSourceUserData))
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let eventTap else { return false }
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let tapSource else { removeTap(); return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func removeTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        tapSource = nil
        eventTap = nil
    }

    private func holdSleepAssertion() -> Bool {
        if assertion != 0 { return true }
        return IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Awake is enabled from the menu bar" as CFString, &assertion) == kIOReturnSuccess
    }

    private func releaseSleepAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    private func tick() {
        defer { didChange?() }
        // Notifications provide immediate updates; polling also covers an unavailable source.
        let currentSupply = power.current
        if currentSupply != supply {
            supply = currentSupply
            input(at: ProcessInfo.processInfo.systemUptime)
        }
        guard enabled else {
            stopMotion(); removeTap(); releaseSleepAssertion()
            message = "Off · normal sleep behavior"
            return
        }
        guard supply.permitsAwake(allowBattery: allowOnBattery) else {
            input(at: ProcessInfo.processInfo.systemUptime)
            removeTap(); releaseSleepAssertion()
            message = supply == .battery ? "Paused · on battery power" : "Paused · power source unavailable"
            return
        }
        cursorAccessGranted = !needsPermission
        guard cursorAccessGranted else {
            inputMonitoringFailed = false
            stopMotion(); removeTap(); releaseSleepAssertion()
            motion.activity(at: ProcessInfo.processInfo.systemUptime)
            message = "Not working · cursor control permission required"
            return
        }
        guard sessionIsUsable else {
            input(at: ProcessInfo.processInfo.systemUptime)
            releaseSleepAssertion()
            message = "Paused · session inactive"
            return
        }
        guard installTap() else {
            inputMonitoringFailed = true
            input(at: ProcessInfo.processInfo.systemUptime)
            releaseSleepAssertion()
            message = "Not working · input detection unavailable"
            return
        }
        inputMonitoringFailed = false
        guard holdSleepAssertion() else {
            stopMotion()
            message = "Could not prevent sleep · try again"
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Key events can be hidden during Secure Input. Query only their age,
        // never their contents, so typing still stops motion in password fields.
        let keyIdle = min(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown),
                          CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .flagsChanged))
        if keyIdle.isFinite && now - keyIdle > motion.lastActivity + 0.01 {
            input(at: now - keyIdle)
        }
        if motion.isReady(at: now), !moving, !buttonsAreDown,
           let point = CGEvent(source: nil)?.location, let display = display(at: point) {
            motion.begin(at: now, pointer: point, display: display.bounds)
            lastPostedPoint = point
            moving = true
            animation.start(on: display.id)
        }
        if moving {
            if dimWhileIdle {
                let success = dimming.fadeDown(at: now)
                updateBrightnessClock()
                message = success
                    ? (dimming.isAnimating ? "Keeping awake · dimming screen" : "Keeping awake · screen dimmed")
                    : "Cursor moving · brightness unavailable"
            } else { message = "Keeping awake · cursor moving" }
        }
        else {
            restoreBrightness()
            let remaining = max(0, Int(ceil(motion.delay.seconds - (now - motion.lastActivity))))
            message = String(format: "Keeping awake · motion in %d:%02d", remaining / 60, remaining % 60)
        }
    }

    private var buttonsAreDown: Bool {
        (0...31).contains { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) }
    }

    private func display(at point: CGPoint) -> (id: CGDirectDisplayID, bounds: CGRect)? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else { return nil }
        return (display, CGDisplayBounds(display))
    }

    private func animate() {
        guard enabled, !suspended, cursorAccessGranted, supply.permitsAwake(allowBattery: allowOnBattery),
              let eventTap, CGEvent.tapIsEnabled(tap: eventTap),
              let current = CGEvent(source: nil)?.location,
              let lastPostedPoint, hypot(current.x - lastPostedPoint.x, current.y - lastPostedPoint.y) < 1,
              let point = motion.point(at: ProcessInfo.processInfo.systemUptime), let source else {
            input(at: ProcessInfo.processInfo.systemUptime)
            return
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else {
            input(at: ProcessInfo.processInfo.systemUptime)
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: IdleMotion.eventMarker)
        event.post(tap: .cgSessionEventTap)
        motionFrames += 1
        self.lastPostedPoint = point
    }

    private func stopMotion() {
        let wasMoving = moving
        animation.stop()
        moving = false
        lastPostedPoint = nil
        restoreBrightness(force: wasMoving)
    }

    private func restoreBrightness(force: Bool = false, immediately: Bool = false) {
        guard !dimming.savedLevels.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastRestoreAttempt >= 1 else { return }
        lastRestoreAttempt = now
        if immediately { dimming.restore() }
        else { dimming.fadeUp(at: now) }
        updateBrightnessClock()
    }

    private func updateBrightnessClock() {
        if dimming.isAnimating {
            guard brightnessTimer == nil else { return }
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.dimming.advance(to: ProcessInfo.processInfo.systemUptime)
                    self.updateBrightnessClock()
                }
            }
            timer.tolerance = 0.001
            RunLoop.main.add(timer, forMode: .common)
            brightnessTimer = timer
        } else {
            brightnessTimer?.invalidate()
            brightnessTimer = nil
        }
    }
}
