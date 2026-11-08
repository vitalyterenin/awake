import AppKit

/// A normal AppKit window with native controls and intrinsic content sizing.
@MainActor
final class PermissionSetupWindow: NSWindowController {
    var openSettings: (() -> Void)?
    var checkAgain: (() -> Void)?
    private var state: CursorControlState?
    private var closesWhenReady = false
    private let heading = NSTextField(labelWithString: "")
    private let explanation = NSTextField(labelWithString: "")
    private let instructions = NSTextField(labelWithString: "")
    private let privacy = NSTextField(labelWithString: "Your mouse and keyboard input is never recorded.")
    private let primary = NSButton(title: "Open System Settings…", target: nil, action: nil)
    private let recheck = NSButton(title: "Check Again", target: nil, action: nil)
    private let later = NSButton(title: "Not Now", target: nil, action: nil)
    private let helpButton = NSButton(title: "Permission Is Already Enabled…", target: nil, action: nil)
    private let recovery = NSTextField(labelWithString:
        "Remove only Awake from the permission list with −.\nThen click + and select the installed Awake.app again.\nReturn here and click Check Again.")
    private let content = NSView()
    var isVisible: Bool { window?.isVisible == true }

    init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Awake Permissions"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        // Use the system spacing unit, not a custom card or fixed window size.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalToSystemSpacingAfter: content.leadingAnchor, multiplier: 2),
            content.trailingAnchor.constraint(equalToSystemSpacingAfter: stack.trailingAnchor, multiplier: 2),
            stack.topAnchor.constraint(equalToSystemSpacingBelow: content.topAnchor, multiplier: 2),
            content.bottomAnchor.constraint(equalToSystemSpacingBelow: stack.bottomAnchor, multiplier: 2)
        ])
        heading.font = .preferredFont(forTextStyle: .headline)
        for label in [heading, explanation, instructions, privacy, recovery] {
            label.maximumNumberOfLines = 0
            label.cell?.usesSingleLineMode = false
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        [heading, explanation, instructions, privacy].forEach(stack.addArrangedSubview)
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let buttons = NSStackView(views: [primary, recheck, later])
        buttons.orientation = .horizontal
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(helpButton)
        stack.addArrangedSubview(recovery)
        recovery.isHidden = true
        for (button, action) in [(primary, #selector(primaryAction)), (recheck, #selector(recheckAction)),
                                 (later, #selector(dismiss)), (helpButton, #selector(toggleHelp))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        primary.keyEquivalent = "\r"
        later.keyEquivalent = "\u{1b}"
        window.defaultButtonCell = primary.cell as? NSButtonCell
        update(.permissionRequired)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: CursorControlState) {
        guard self.state != state else { return }
        self.state = state
        switch state {
        case .permissionRequired:
            heading.stringValue = "Awake needs permission"
            explanation.stringValue = "Awake cannot keep your Mac awake until\ncursor control is allowed."
            instructions.stringValue = "1. Open System Settings → Privacy & Security.\nChoose Accessibility, called Device Control and Data Access\non newer macOS versions.\n\n2. Turn on Awake. If it is missing, click +\nand select the installed Awake.app.\n\nThis window closes automatically when access is ready."
        case .monitoringUnavailable:
            heading.stringValue = "Awake is paused"
            explanation.stringValue = "Cursor control is allowed, but activity detection failed.\nAwake cannot keep your Mac awake until this is fixed."
            instructions.stringValue = "Open the cursor-control permission in System Settings.\nTurn Awake off, then on, and click Check Again."
        case .ready:
            heading.stringValue = "Awake is ready"
            explanation.stringValue = "Cursor control is allowed."
            instructions.stringValue = "Use the coffee cup in your menu bar to manage Awake.\nMove, scroll or type to stop the circle and restore brightness."
        }
        let ready = state == .ready
        primary.title = ready ? "Done" : "Open System Settings…"
        recheck.isHidden = ready
        later.isHidden = ready
        helpButton.isHidden = ready
        recovery.isHidden = true
        fitContent()
        if ready && closesWhenReady { dismiss() }
    }

    private func fitContent() {
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(content.fittingSize)
    }

    func present() {
        closesWhenReady = state != .ready
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func primaryAction() {
        if state == .ready { dismiss() }
        else { openSettings?() }
    }
    @objc private func recheckAction() { checkAgain?() }
    @objc private func dismiss() { closesWhenReady = false; close() }
    @objc private func toggleHelp() { recovery.isHidden.toggle(); fitContent() }

    /// Checks rendered content, real button dismissal and closure after permission grant.
    func verifyPresentation(_ state: CursorControlState, appearance: NSAppearance.Name,
                            grantWhileOpen: Bool = false) -> Bool {
        update(state)
        window?.appearance = NSAppearance(named: appearance)
        present()
        content.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        var valid = isVisible && !content.hasAmbiguousLayout
        func check(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if view is NSTextField || view is NSButton {
                let rect = view.convert(view.bounds, to: content)
                if rect.isEmpty || !content.bounds.insetBy(dx: -1, dy: -1).contains(rect) { valid = false }
            }
            view.subviews.forEach(check)
        }
        check(content)
        if grantWhileOpen { update(.ready) }
        else { (state == .ready ? primary : later).performClick(nil) }
        valid = valid && !isVisible && NSApp.modalWindow == nil
        print("Native window presentation/dismissal \(state), \(appearance.rawValue), grant=\(grantWhileOpen): \(valid ? "passed" : "FAILED")")
        return valid
    }
}
