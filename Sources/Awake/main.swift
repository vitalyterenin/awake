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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Awake")
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "Awake", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        statusRow = row("Starting…")
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
        permissionRow = row("Allow Accessibility…", #selector(allowAccessibility))
        row("The cursor slowly moves in a small circle.")
        row("Move, scroll or type to stop the circle.")
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
        updates.start()
        refreshMenu()
        if CommandLine.arguments.contains("--smoke-test") {
            guard menu.items.last?.title == "Quit Awake", menu.items.count >= 10,
                  statusItem.button?.image != nil else { exit(1) }
            DispatchQueue.main.async { self.verifyVisibleMenus() }
            return
        }
        if CommandLine.arguments.contains("--preview-menu") {
            DispatchQueue.main.async { self.statusItem.button?.performClick(nil) }
            return
        }
        awake.start()
        if !UserDefaults.standard.bool(forKey: "didWelcome") {
            UserDefaults.standard.set(true, forKey: "didWelcome")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Keep your Mac awake."
            alert.informativeText = "Awake lives in your menu bar. After one or five minutes without mouse or keyboard activity, your cursor slowly moves in a small circle. Choose the delay in its menu. Any activity stops the motion.\n\nAllow Accessibility so Awake can move the cursor and detect when you return. Your input is never recorded or sent anywhere."
            alert.addButton(withTitle: "Allow Accessibility…")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { awake.requestPermission() }
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
        delayRow.title = "Start cursor motion after · \(awake.motionDelay.rawValue) min"
        for choice in delayChoices { choice.state = choice.tag == awake.motionDelay.rawValue ? .on : .off }
        statusRow.title = awake.message
        permissionRow.isHidden = !awake.needsPermission
        statusItem.button?.appearsDisabled = !awake.enabled
        statusItem.button?.toolTip = "Awake — \(awake.message)"
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
        print("Awake menu smoke test passed without monitoring or synthetic movement.")
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { awake.stop() }
    @objc private func toggleAwake() { awake.setEnabled(!awake.enabled) }
    @objc private func selectDelay(_ sender: NSMenuItem) {
        guard let delay = MotionDelay(rawValue: sender.tag) else { return }
        awake.setMotionDelay(delay)
    }
    @objc private func allowAccessibility() { awake.requestPermission() }
    @objc private func checkForUpdates(_ sender: Any?) { updates.check(sender) }
    @objc private func toggleAutomaticChecks() { updates.setAutomaticChecks(!updates.automaticallyChecks); refreshMenu() }
    @objc private func toggleAutomaticInstalls() { updates.setAutomaticInstallation(!updates.automaticallyInstalls); refreshMenu() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string:
            "A small circle. An awake Mac.\nApple Silicon · No input recording · No telemetry\n\nAwake prevents idle sleep while enabled. Closing the lid, choosing Sleep, or a low battery can still put your Mac to sleep.")])
    }
}

if CommandLine.arguments.contains("--diagnostics") {
    print("Awake · arm64 · macOS 13+ · 1- or 5-minute idle delay (default 5) · 6-point radius · 24-second circle")
    print("Accessibility permission: \(AXIsProcessTrusted() ? "allowed" : "not granted")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
