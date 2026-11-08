import AppKit
@preconcurrency import ApplicationServices
import IOKit.pwr_mgt
import AwakeCore

@MainActor
final class AwakeController {
    var didChange: (() -> Void)?
    private(set) var enabled: Bool
    private(set) var message = "Starting…"
    private(set) var moving = false
    private var motion: IdleMotion
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var heartbeat: Timer?
    private var animation: Timer?
    private var assertion: IOPMAssertionID = 0
    private var suspended = false
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var lastPostedPoint: CGPoint?
    private let source = CGEventSource(stateID: .privateState)

    init() {
        UserDefaults.standard.register(defaults: ["keepAwake": true, "motionDelayMinutes": 5])
        enabled = UserDefaults.standard.bool(forKey: "keepAwake")
        let delay = MotionDelay(rawValue: UserDefaults.standard.integer(forKey: "motionDelayMinutes")) ?? .fiveMinutes
        motion = IdleMotion(now: ProcessInfo.processInfo.systemUptime, delay: delay)
    }

    var needsPermission: Bool { !AXIsProcessTrusted() }
    var motionDelay: MotionDelay { motion.delay }

    func setMotionDelay(_ delay: MotionDelay) {
        UserDefaults.standard.set(delay.rawValue, forKey: "motionDelayMinutes")
        motion.setDelay(delay, at: ProcessInfo.processInfo.systemUptime)
        stopMotion()
        tick()
    }

    func start() {
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
        if value && needsPermission { requestPermission() }
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
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func suspend() {
        suspended = true
        input(at: ProcessInfo.processInfo.systemUptime)
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
        guard enabled else {
            stopMotion(); removeTap(); releaseSleepAssertion()
            message = "Off · normal sleep behavior"
            return
        }
        guard !needsPermission else {
            stopMotion(); removeTap(); releaseSleepAssertion()
            motion.activity(at: ProcessInfo.processInfo.systemUptime)
            message = "Accessibility permission required"
            return
        }
        guard sessionIsUsable else {
            input(at: ProcessInfo.processInfo.systemUptime)
            releaseSleepAssertion()
            message = "Paused · session inactive"
            return
        }
        guard installTap() else {
            input(at: ProcessInfo.processInfo.systemUptime)
            releaseSleepAssertion()
            message = "Input access unavailable · reopen Awake"
            return
        }
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
           let point = CGEvent(source: nil)?.location, let display = displayBounds(at: point) {
            motion.begin(at: now, pointer: point, display: display)
            lastPostedPoint = point
            moving = true
            animation = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.animate() }
            }
            RunLoop.main.add(animation!, forMode: .common)
        }
        if moving { message = "Keeping awake · cursor moving" }
        else {
            let remaining = max(0, Int(ceil(motion.delay.seconds - (now - motion.lastActivity))))
            message = String(format: "Keeping awake · motion in %d:%02d", remaining / 60, remaining % 60)
        }
    }

    private var buttonsAreDown: Bool {
        (0...31).contains { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) }
    }

    private func displayBounds(at point: CGPoint) -> CGRect? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else { return nil }
        return CGDisplayBounds(display)
    }

    private func animate() {
        guard enabled, sessionIsUsable, !needsPermission, !buttonsAreDown,
              let eventTap, CGEvent.tapIsEnabled(tap: eventTap),
              let current = CGEvent(source: nil)?.location,
              let lastPostedPoint, hypot(current.x - lastPostedPoint.x, current.y - lastPostedPoint.y) < 1,
              let point = motion.point(at: ProcessInfo.processInfo.systemUptime),
              let display = displayBounds(at: current), let source else {
            input(at: ProcessInfo.processInfo.systemUptime)
            return
        }
        let clamped = CGPoint(x: min(max(point.x, display.minX), display.maxX - 1),
                              y: min(max(point.y, display.minY), display.maxY - 1))
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: clamped, mouseButton: .left) else {
            input(at: ProcessInfo.processInfo.systemUptime)
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: IdleMotion.eventMarker)
        event.post(tap: .cgSessionEventTap)
        self.lastPostedPoint = clamped
    }

    private func stopMotion() {
        animation?.invalidate()
        animation = nil
        moving = false
        lastPostedPoint = nil
    }
}
