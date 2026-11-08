import AppKit
import QuartzCore

@MainActor
final class CursorAnimationClock: NSObject {
    var frame: (() -> Void)?
    private var displayLink: AnyObject?
    private var fallback: Timer?

    func start(on display: CGDirectDisplayID) {
        stop()
        if #available(macOS 14, *), let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) {
            let link = screen.displayLink(target: self, selector: #selector(displayFrame))
            let maximum = Float(screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum),
                maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(timeInterval: 1 / 60, target: self, selector: #selector(displayFrame),
                              userInfo: nil, repeats: true)
            timer.tolerance = 0.001
            RunLoop.main.add(timer, forMode: .common)
            fallback = timer
        }
    }

    @objc private func displayFrame() { frame?() }

    func stop() {
        if #available(macOS 14, *), let link = displayLink as? CADisplayLink { link.invalidate() }
        displayLink = nil
        fallback?.invalidate()
        fallback = nil
    }
}
