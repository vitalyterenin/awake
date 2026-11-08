import AppKit
@preconcurrency import ApplicationServices
import IOKit.pwr_mgt
import AwakeCore

/// Runtime effects stay at this boundary so controller scenarios need no system access.
@MainActor
protocol AwakeEnvironment: AnyObject {
    var now: TimeInterval { get }
    var supply: PowerSupply { get }
    var cursorAccess: Bool { get }
    var sessionIsUsable: Bool { get }
    var keyIdle: TimeInterval { get }
    var buttonsAreDown: Bool { get }
    var pointer: CGPoint? { get }
    var tapIsEnabled: Bool { get }
    var preventingIdleSleep: Bool { get }
    func start(refresh: @escaping @MainActor () -> Void, activity: @escaping @MainActor (Int64) -> Void,
               suspension: @escaping @MainActor (Bool) -> Void)
    func stop()
    func installTap() -> Bool
    func removeTap()
    func holdSleepAssertion() -> Bool
    func releaseSleepAssertion()
    func display(at point: CGPoint) -> (id: CGDirectDisplayID, bounds: CGRect)?
    func startMotion(on display: CGDirectDisplayID, frame: @escaping @MainActor () -> Void)
    func stopMotion()
    func postMovement(to point: CGPoint, marker: Int64) -> Bool
    func setBrightnessFrame(_ frame: (@MainActor () -> Void)?)
    func openPermissionSettings() -> Bool
}

@MainActor
final class SystemAwakeEnvironment: AwakeEnvironment {
    private let power = PowerSourceMonitor()
    private let animation = CursorAnimationClock()
    private let source = CGEventSource(stateID: .privateState)
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var assertion: IOPMAssertionID = 0
    private var heartbeat: Timer?
    private var brightnessTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var activity: (@MainActor (Int64) -> Void)?

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var supply: PowerSupply { power.current }
    var cursorAccess: Bool { AXIsProcessTrusted() }
    var preventingIdleSleep: Bool { assertion != 0 }
    var tapIsEnabled: Bool { eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var pointer: CGPoint? { CGEvent(source: nil)?.location }
    var sessionIsUsable: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // The WindowServer lock indicator is optional; missing sessions fail closed.
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }
    var keyIdle: TimeInterval {
        // Secure Input can hide key events. Read only their age, never their contents.
        min(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .flagsChanged))
    }
    var buttonsAreDown: Bool {
        (0...31).contains { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) }
    }

    func start(refresh: @escaping @MainActor () -> Void, activity: @escaping @MainActor (Int64) -> Void,
               suspension: @escaping @MainActor (Bool) -> Void) {
        self.activity = activity
        power.didChange = refresh
        power.start()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { suspension(true) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { suspension(false) }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { activity(0) }
        }
        heartbeat = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
    }

    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        setBrightnessFrame(nil)
        stopMotion()
        removeTap()
        releaseSleepAssertion()
        power.stop()
        power.didChange = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        activity = nil
    }

    func installTap() -> Bool {
        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return CGEvent.tapIsEnabled(tap: eventTap)
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
            .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // An unchanged active tap uses Accessibility permission without requesting
        // a second Input Monitoring permission. Every event is returned untouched.
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                MainActor.assumeIsolated {
                    let owner = Unmanaged<SystemAwakeEnvironment>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.activity?(0)
                        if let tap = owner.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else {
                        owner.activity?(event.getIntegerValueField(.eventSourceUserData))
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

    func removeTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        tapSource = nil
        eventTap = nil
    }

    func holdSleepAssertion() -> Bool {
        if assertion != 0 { return true }
        return IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Awake is enabled from the menu bar" as CFString, &assertion) == kIOReturnSuccess
    }

    func releaseSleepAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    func display(at point: CGPoint) -> (id: CGDirectDisplayID, bounds: CGRect)? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else { return nil }
        return (display, CGDisplayBounds(display))
    }

    func startMotion(on display: CGDirectDisplayID, frame: @escaping @MainActor () -> Void) {
        animation.frame = frame
        animation.start(on: display)
    }

    func stopMotion() { animation.stop(); animation.frame = nil }

    func postMovement(to point: CGPoint, marker: Int64) -> Bool {
        guard let source, let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                             mouseCursorPosition: point, mouseButton: .left) else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cgSessionEventTap)
        return true
    }

    func setBrightnessFrame(_ frame: (@MainActor () -> Void)?) {
        guard let frame else {
            brightnessTimer?.invalidate()
            brightnessTimer = nil
            return
        }
        guard brightnessTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { frame() }
        }
        timer.tolerance = 0.001
        RunLoop.main.add(timer, forMode: .common)
        brightnessTimer = timer
    }

    func openPermissionSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return false }
        return NSWorkspace.shared.open(url)
    }
}
