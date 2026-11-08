import AppKit

/// Uses the native file drag operation, just like dragging the app from Finder.
@MainActor
private final class ApplicationDragIcon: NSImageView, NSDraggingSource {
    let applicationURL: URL
    var attempts = 0
    var lastOperation: UInt = 0
    var dragging = false
    private var mouseOrigin: NSPoint?

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = "Drag Awake into the permission list"
        setAccessibilityLabel("Awake application — drag into System Settings")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalTo: widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { mouseOrigin = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { mouseOrigin = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseOrigin,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 4 else { return }
        mouseOrigin = nil
        attempts += 1
        // Supply both modern file URLs and the filename list used by older drop targets.
        let payload = NSPasteboardItem()
        payload.setString(applicationURL.absoluteString, forType: .fileURL)
        payload.setPropertyList([applicationURL.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        let item = NSDraggingItem(pasteboardWriter: payload)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        dragging = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        lastOperation = operation.rawValue
        dragging = false
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// A standard floating window that accompanies the permission setup task.
@MainActor
final class PermissionDragPanel: NSWindowController, NSWindowDelegate {
    private var followTimer: Timer?
    private var presented = false
    private let applicationURL: URL
    private let content = NSView()
    private var dragIcon: ApplicationDragIcon!
    private let missingButton = NSButton(title: "Not Listed?", target: nil, action: nil)
    private let dragContent = NSStackView()
    var diagnostics: [String: Any] {
        ["permissionDragAttempts": dragIcon.attempts, "permissionDragging": dragIcon.dragging, "permissionDragOperation": dragIcon.lastOperation,
         "permissionDragExpanded": !dragContent.isHidden]
    }
    var isVisible: Bool { window?.isVisible == true }
    var isAccompanyingSettings: Bool { followTimer != nil }

    init(applicationURL: URL = Bundle.main.bundleURL) {
        self.applicationURL = applicationURL
        let panel = NSWindow(contentRect: .zero,
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = "Allow Awake"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = content
        let icon = ApplicationDragIcon(applicationURL: applicationURL)
        dragIcon = icon
        let instruction = NSTextField(labelWithString: "Turn on Awake in the list.")
        let dragInstruction = NSTextField(labelWithString: "Drag Awake into the list.")
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(showInFinder))
        reveal.bezelStyle = .rounded
        [icon, dragInstruction, reveal].forEach(dragContent.addArrangedSubview)
        dragContent.orientation = .vertical
        dragContent.alignment = .centerX
        dragContent.isHidden = true
        missingButton.bezelStyle = .rounded
        missingButton.target = self
        missingButton.action = #selector(toggleMissing)
        let stack = NSStackView(views: [instruction, missingButton, dragContent])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalToSystemSpacingAfter: content.leadingAnchor, multiplier: 2),
            content.trailingAnchor.constraint(equalToSystemSpacingAfter: stack.trailingAnchor, multiplier: 2),
            stack.topAnchor.constraint(equalToSystemSpacingBelow: content.topAnchor, multiplier: 2),
            content.bottomAnchor.constraint(equalToSystemSpacingBelow: stack.bottomAnchor, multiplier: 2)
        ])
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func accompanySettings() {
        stop()
        presented = false
        setMissing(false)
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followSettings() }
        }
        followSettings()
    }

    func stop() {
        followTimer?.invalidate()
        followTimer = nil
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { stop() }

    private func followSettings() {
        guard !dragIcon.dragging else { return }
        guard let settings = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences").first else { stop(); return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        window?.level = frontmost == settings.processIdentifier || frontmost == ProcessInfo.processInfo.processIdentifier
            ? .floating : .normal
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]],
              let entry = entries.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == settings.processIdentifier &&
                  ($0[kCGWindowLayer as String] as? Int) == 0
              }), let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else {
            window?.orderOut(nil)
            return
        }
        // Window bounds are public metadata; no screen capture or Accessibility read is needed.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        position(beside: NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height))
        if frontmost == settings.processIdentifier || frontmost == ProcessInfo.processInfo.processIdentifier {
            if !presented {
                presented = true
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else { window?.orderFrontRegardless() }
        }
    }

    private func position(beside settings: NSRect) {
        guard let window else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) }) ?? NSScreen.main
        guard let available = screen?.visibleFrame else { return }
        let gap: CGFloat = 8
        // Overlay the sidebar so the permission list stays visible on smaller screens too.
        let x = min(available.maxX - window.frame.width, settings.minX + gap)
        let y = min(available.maxY - window.frame.height,
                    max(available.minY, settings.maxY - window.frame.height))
        window.setFrameOrigin(NSPoint(x: max(available.minX, x), y: y))
    }

    private func setMissing(_ missing: Bool) {
        dragContent.isHidden = !missing
        missingButton.title = missing ? "Back" : "Not Listed?"
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(content.fittingSize)
    }

    @objc private func toggleMissing() { setMissing(dragContent.isHidden) }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
    }

    func verifyPresentation(appearance: NSAppearance.Name) -> Bool {
        window?.appearance = NSAppearance(named: appearance)
        window?.center()
        window?.orderFrontRegardless()
        content.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        var valid = isVisible && !content.hasAmbiguousLayout && applicationURL.pathExtension == "app"
        for expanded in [false, true, false] {
            if expanded != !dragContent.isHidden { missingButton.performClick(nil) }
            content.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            valid = valid && (dragContent.isHidden != expanded) && !content.hasAmbiguousLayout
            func check(_ view: NSView) {
                guard !view.isHiddenOrHasHiddenAncestor else { return }
                if view is NSControl {
                    let rect = view.convert(view.bounds, to: content)
                    valid = valid && !rect.isEmpty && content.bounds.insetBy(dx: -1, dy: -1).contains(rect)
                }
                view.subviews.forEach(check)
            }
            check(content)
        }
        window?.performClose(nil)
        let result = valid && !isVisible && followTimer == nil
        print("Native permission drag panel \(appearance.rawValue): \(result ? "passed" : "FAILED")")
        return result
    }
}
