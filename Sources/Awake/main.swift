import AppKit
import ApplicationServices
import AwakeCore

#if !arch(arm64)
#error("Awake supports Apple Silicon (arm64) only.")
#endif

@MainActor
private final class MenuProbe: NSObject {
    let menu: NSMenu
    var inspected = false
    var failure: String?
    init(menu: NSMenu) { self.menu = menu }
    @objc func inspect() {
        inspected = true
        let frame = menu.accessibilityFrame()
        if frame.isEmpty || frame.height + 1 < menu.size.height {
            failure = "Menu is clipped: \(frame), required \(menu.size)"
        }
        for row in menu.items where !row.isSeparatorItem && !row.isHidden {
            let rect = row.accessibilityFrame()
            if rect.isEmpty || !frame.insetBy(dx: -1, dy: -1).contains(rect) {
                failure = "Menu row is not fully visible: \(row.title)"
            }
        }
        print("Verified visible menu: \(menu.items.count) rows, frame \(frame)")
        menu.cancelTracking()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let awake = AwakeController()
    private let updates = UpdateController()
    private let runtimeStatus = RuntimeStatus()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusRow: NSMenuItem!
    private var toggle: NSMenuItem!
    private var permissionRow: NSMenuItem!
    private var checkUpdates: NSMenuItem!
    private var automaticChecks: NSMenuItem!
    private var automaticInstalls: NSMenuItem!
    private var delayRow: NSMenuItem!
    private var delayChoices: [NSMenuItem] = []
    private var dimRow: NSMenuItem!
    private var batteryRow: NSMenuItem!
    private var setup: PermissionSetupWindow?
    private let permissionDrag = PermissionDragPanel()
    private var runtimeStarted = false
    private var lastControlState: CursorControlState?
    private var previewControlState: CursorControlState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Awake")
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "Awake", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        statusRow = row("Starting…")
        permissionRow = row("Permissions…", #selector(showSetup))
        menu.addItem(.separator())
        toggle = row("Keep Mac awake", #selector(toggleAwake))
        delayRow = row("Start cursor motion after")
        delayRow.isEnabled = true
        let delayMenu = NSMenu()
        delayMenu.autoenablesItems = false
        delayRow.submenu = delayMenu
        for delay in MotionDelay.allCases {
            let choice = item(delay == .oneMinute ? "1 minute" : "5 minutes", #selector(selectDelay))
            choice.tag = delay.rawValue
            delayMenu.addItem(choice)
            delayChoices.append(choice)
        }
        dimRow = row("Dim display while idle", #selector(toggleDimming))
        batteryRow = row("Allow on battery power", #selector(toggleBattery))
        menu.addItem(.separator())
        let updateItem = row("Updates")
        updateItem.isEnabled = true
        let updateMenu = NSMenu()
        updateMenu.autoenablesItems = false
        updateItem.submenu = updateMenu
        checkUpdates = item("Check for Updates…", #selector(checkForUpdates))
        automaticChecks = item("Check automatically", #selector(toggleAutomaticChecks))
        automaticInstalls = item("Install automatically", #selector(toggleAutomaticInstalls))
        [checkUpdates, automaticChecks, automaticInstalls].forEach { updateMenu.addItem($0!) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        row("About Awake \(version)", #selector(about))
        let quit = row("Quit Awake", #selector(quitApp))
        quit.keyEquivalent = "q"
        awake.didChange = { [weak self] in self?.refreshMenu() }
        if CommandLine.arguments.contains("--preview-setup") { previewControlState = .permissionRequired }
        refreshMenu()
        if CommandLine.arguments.contains("--smoke-test") {
            guard menu.items.last?.title == "Quit Awake", menu.items.count >= 10,
                  statusItem.button?.image != nil else { exit(1) }
            DispatchQueue.main.async { self.verifyVisibleMenus() }
            return
        }
        if CommandLine.arguments.contains("--preview-setup") {
            DispatchQueue.main.async { self.showSetup() }
            return
        }
        if CommandLine.arguments.contains("--preview-menu") {
            DispatchQueue.main.async { self.statusItem.button?.performClick(nil) }
            return
        }
        updates.start()
        awake.start()
        runtimeStarted = true
        lastControlState = awake.cursorControlState
        runtimeStatus.start { [weak self] in
            guard let self else { return [:] }
            return self.awake.diagnostics.merging(self.permissionDrag.diagnostics) { _, new in new }.merging(["setupVisible": self.setup?.isVisible == true,
                "permissionDragVisible": self.permissionDrag.isVisible]) { _, new in new }
        }
        let firstLaunch = !UserDefaults.standard.bool(forKey: "didWelcome")
        if firstLaunch || awake.cursorControlState != .ready {
            UserDefaults.standard.set(true, forKey: "didWelcome")
            showSetup()
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @discardableResult
    private func row(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        menu.addItem(item)
        return item
    }

    private func refreshMenu() {
        toggle.state = awake.enabled ? .on : .off
        dimRow.state = awake.dimWhileIdle ? .on : .off
        batteryRow.state = awake.allowOnBattery ? .on : .off
        delayRow.title = "Start cursor motion after · \(awake.motionDelay.rawValue) min"
        for choice in delayChoices { choice.state = choice.tag == awake.motionDelay.rawValue ? .on : .off }
        let controlState = previewControlState ?? awake.cursorControlState
        let blocked = controlState != .ready
        let problem = controlState == .permissionRequired
            ? "Not working · permission required" : "Not working · input detection blocked"
        statusRow.title = blocked ? problem : awake.message
        statusRow.action = blocked ? #selector(showSetup) : nil
        statusRow.isEnabled = blocked
        statusRow.image = blocked ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) : nil
        permissionRow.title = blocked ? "Finish Setup…" : "Permissions…"
        permissionRow.image = blocked ? NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil) : nil
        statusItem.button?.image = NSImage(systemSymbolName: blocked ? "exclamationmark.triangle.fill" : "cup.and.saucer",
            accessibilityDescription: blocked ? "Awake needs attention." : "Awake")
        statusItem.button?.title = blocked ? " Awake" : ""
        statusItem.button?.appearsDisabled = !awake.enabled && !blocked
        statusItem.button?.toolTip = "Awake — \(blocked ? problem : awake.message)"
        statusItem.button?.setAccessibilityLabel("Awake — \(blocked ? problem : awake.message)")
        setup?.update(controlState)
        if controlState == .ready { permissionDrag.stop() }
        if runtimeStarted, lastControlState != controlState {
            lastControlState = controlState
            if blocked { showSetup() }
        }
        checkUpdates.isEnabled = updates.canCheck
        automaticChecks.isEnabled = updates.isConfigured
        automaticInstalls.isEnabled = updates.isConfigured
        automaticChecks.state = updates.automaticallyChecks ? .on : .off
        automaticInstalls.state = updates.automaticallyInstalls ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func verifyVisibleMenus() {
        guard let button = statusItem.button, let window = button.window else { exit(1) }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        for visible in [menu, delayRow.submenu!, checkUpdates.menu!] {
            let probe = MenuProbe(menu: visible)
            let timer = Timer(timeInterval: 0.25, target: probe,
                              selector: #selector(MenuProbe.inspect), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            visible.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.minY), in: nil)
            timer.invalidate()
            if !probe.inspected || probe.failure != nil {
                print(probe.failure ?? "Menu closed before layout inspection")
                exit(1)
            }
        }
        let setup = setupWindow()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            guard permissionDrag.verifyPresentation(appearance: appearance) else { exit(1) }
            for state in [CursorControlState.permissionRequired, .monitoringUnavailable, .ready] {
                guard setup.verifyPresentation(state, appearance: appearance) else { exit(1) }
            }
            guard setup.verifyPresentation(.permissionRequired, appearance: appearance,
                                           grantWhileOpen: true) else { exit(1) }
        }
        print("Awake menu and setup smoke test passed without monitoring or synthetic movement.")
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { permissionDrag.stop(); if runtimeStarted { awake.stop() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if permissionDrag.isAccompanyingSettings { return false }
        if awake.cursorControlState != .ready { showSetup() }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if runtimeStarted { awake.recheckCursorControl() }
    }
    private func setupWindow() -> PermissionSetupWindow {
        if let setup { return setup }
        let setup = PermissionSetupWindow()
        setup.openSettings = { [weak self] in
            guard let self else { return }
            if self.awake.requestPermission() {
                self.setup?.window?.orderOut(nil)
                self.permissionDrag.accompanySettings()
            }
        }
        setup.checkAgain = { [weak self] in
            guard let self else { return }
            self.awake.recheckCursorControl()
            self.setup?.update(self.previewControlState ?? self.awake.cursorControlState)
        }
        self.setup = setup
        return setup
    }
    @objc private func showSetup() {
        permissionDrag.stop()
        let setup = setupWindow()
        setup.update(previewControlState ?? awake.cursorControlState)
        setup.present()
    }
    @objc private func toggleAwake() {
        awake.setEnabled(!awake.enabled)
        if awake.enabled && awake.cursorControlState != .ready { showSetup() }
    }
    @objc private func toggleDimming() { awake.setDimWhileIdle(!awake.dimWhileIdle) }
    @objc private func toggleBattery() { awake.setAllowOnBattery(!awake.allowOnBattery) }
    @objc private func selectDelay(_ sender: NSMenuItem) {
        guard let delay = MotionDelay(rawValue: sender.tag) else { return }
        awake.setMotionDelay(delay)
    }
    @objc private func checkForUpdates(_ sender: Any?) { updates.check(sender) }
    @objc private func toggleAutomaticChecks() { updates.setAutomaticChecks(!updates.automaticallyChecks); refreshMenu() }
    @objc private func toggleAutomaticInstalls() { updates.setAutomaticInstallation(!updates.automaticallyInstalls); refreshMenu() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string:
            "Prevents idle sleep.\nApple Silicon · No input recording · No telemetry")])
    }
}

if CommandLine.arguments.contains("--status") { exit(RuntimeStatus.query() ? 0 : 1) }

if CommandLine.arguments.contains("--diagnostics") {
    print("Awake · arm64 · macOS 13+ · 1- or 5-minute idle delay (default 5) · 12-point radius · 4-second circle")
    print("Accessibility permission: \(AXIsProcessTrusted() ? "allowed" : "not granted")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
