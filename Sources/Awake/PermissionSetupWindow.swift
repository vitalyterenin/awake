import AppKit

/// Uses the system alert layout and controls; polling never steals focus.
@MainActor
final class PermissionSetupWindow: NSWindowController, NSAlertDelegate {
    var openSettings: (() -> Void)?
    var checkAgain: (() -> Void)?
    private var state: CursorControlState?
    private var alert: NSAlert?
    private var help: NSAlert?

    init() {
        super.init(window: nil)
        update(.permissionRequired)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: CursorControlState) {
        guard self.state != state else { return }
        self.state = state
        let previous = window
        let wasVisible = previous?.isVisible == true
        let wasKey = previous?.isKeyWindow == true
        let alert = NSAlert()
        alert.alertStyle = state == .ready ? .informational : .warning
        alert.delegate = self
        alert.showsHelp = state != .ready
        switch state {
        case .permissionRequired:
            alert.messageText = "Awake needs permission"
            alert.informativeText = "Awake cannot keep your Mac awake until cursor control is allowed.\n\n1. Open System Settings → Privacy & Security → Accessibility (called Device Control and Data Access on newer macOS versions).\n\n2. Turn on Awake. If it is missing, click + and select the installed Awake.app.\n\nAwake checks automatically. Your mouse and keyboard input is never recorded."
        case .monitoringUnavailable:
            alert.messageText = "Awake is paused"
            alert.informativeText = "Cursor control is allowed, but Awake could not start detecting activity. It cannot keep your Mac awake until this is fixed.\n\nOpen the cursor-control permission in System Settings and turn Awake off, then on. Return here and click Check Again.\n\nIf it is still blocked, click the help button below."
        case .ready:
            alert.messageText = "Awake is ready"
            alert.informativeText = "Cursor control is allowed.\n\nUse the coffee cup in your menu bar to turn Awake on or off, choose a 1- or 5-minute idle delay, and manage display dimming and battery use.\n\nMove, scroll or type to stop the circle and restore brightness."
        }
        let primary = alert.addButton(withTitle: state == .ready ? "Done" : "Open System Settings…")
        primary.target = self
        primary.action = #selector(primaryAction)
        if state != .ready {
            let recheck = alert.addButton(withTitle: "Check Again")
            recheck.target = self
            recheck.action = #selector(recheckAction)
            let later = alert.addButton(withTitle: "Not Now")
            later.target = self
            later.action = #selector(dismiss)
            later.keyEquivalent = "\u{1b}"
        }
        alert.layout()
        alert.window.title = "Awake Setup"
        alert.window.isReleasedWhenClosed = false
        self.alert = alert
        window = alert.window
        if let previous, wasVisible {
            if let sheet = previous.attachedSheet { previous.endSheet(sheet) }
            // Keep the new system-sized dialog on the same screen without activating it.
            let center = NSPoint(x: previous.frame.midX, y: previous.frame.midY)
            window?.setFrameOrigin(NSPoint(x: center.x - alert.window.frame.width / 2,
                                           y: center.y - alert.window.frame.height / 2))
            previous.orderOut(nil)
            if wasKey { window?.makeKeyAndOrderFront(nil) }
            else { window?.orderFront(nil) }
        } else {
            window?.center()
        }
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        guard let window, window.attachedSheet == nil else { return true }
        let help = NSAlert()
        help.messageText = "Permission is enabled, but Awake is still blocked"
        help.informativeText = "After an update, macOS can keep a permission linked to the previous copy of Awake.\n\nIn the permission list, select Awake and click −. Then click + and add the installed Awake.app again. Return here and click Check Again."
        help.addButton(withTitle: "OK")
        self.help = help
        help.beginSheetModal(for: window) { [weak self] _ in self?.help = nil }
        return true
    }

    /// Checks the actual system-laid-out dialog in the current appearance.
    func verifyLayout() -> Bool {
        guard let window, let root = window.contentView, let alert else { return false }
        alert.layout()
        root.layoutSubtreeIfNeeded()
        var valid = window.isVisible
        func check(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if view is NSTextField || view is NSButton {
                let rect = view.convert(view.bounds, to: root)
                if rect.isEmpty || !root.bounds.insetBy(dx: -1, dy: -1).contains(rect) { valid = false }
                if let field = view as? NSTextField, let cell = field.cell {
                    let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10_000))
                    if needed.height > field.bounds.height + 2 { valid = false }
                }
            }
            view.subviews.forEach(check)
        }
        check(root)
        if let screen = window.screen, window.frame.height > screen.visibleFrame.height { valid = false }
        print("System setup dialog \(String(describing: state)): \(window.frame.size), \(valid ? "passed" : "FAILED")")
        return valid
    }

    @objc private func primaryAction() {
        if state == .ready { dismiss() }
        else { openSettings?() }
    }
    @objc private func recheckAction() { checkAgain?() }
    @objc private func dismiss() { window?.orderOut(nil) }
}
