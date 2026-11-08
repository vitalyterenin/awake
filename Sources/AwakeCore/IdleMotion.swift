import Foundation
import CoreGraphics

public enum MotionDelay: Int, CaseIterable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}

/// Uses monotonic time supplied by the caller. Own mouse events never reset idle.
public struct IdleMotion {
    public static let radius: CGFloat = 12
    public static let period: TimeInterval = 4
    public static let entranceDuration: TimeInterval = 0.75
    public static let eventMarker: Int64 = 0x4157414B45

    public private(set) var lastActivity: TimeInterval
    public private(set) var startedAt: TimeInterval?
    public private(set) var delay: MotionDelay
    private var center = CGPoint.zero
    private var startingAngle: Double = 0
    private var radius: CGFloat = Self.radius
    private var bounds = CGRect.zero
    private var origin = CGPoint.zero

    public init(now: TimeInterval, delay: MotionDelay = .fiveMinutes) {
        lastActivity = now
        self.delay = delay
    }

    public mutating func setDelay(_ delay: MotionDelay, at now: TimeInterval) {
        self.delay = delay
        activity(at: now)
    }

    public mutating func activity(at now: TimeInterval, marker: Int64 = 0) {
        guard marker != Self.eventMarker else { return }
        lastActivity = now
        startedAt = nil
    }

    public func isReady(at now: TimeInterval) -> Bool {
        now - lastActivity >= delay.seconds
    }

    /// Ease from the exact pointer location into a complete circle inside the display.
    /// Blending two in-bounds points avoids flat/clipped arcs at screen edges.
    public mutating func begin(at now: TimeInterval, pointer: CGPoint, display: CGRect) {
        bounds = CGRect(x: display.minX, y: display.minY, width: display.width - 1, height: display.height - 1)
        radius = max(0, min(Self.radius, min(bounds.width, bounds.height) / 4))
        let xSign: CGFloat = pointer.x + 2 * radius <= bounds.maxX ? 1 : -1
        let proposed = CGPoint(x: pointer.x + xSign * radius, y: pointer.y)
        center = CGPoint(
            x: min(max(proposed.x, bounds.minX + radius), bounds.maxX - radius),
            y: min(max(proposed.y, bounds.minY + radius), bounds.maxY - radius)
        )
        origin = pointer
        startingAngle = atan2(pointer.y - center.y, pointer.x - center.x)
        startedAt = now
    }

    public func point(at now: TimeInterval) -> CGPoint? {
        guard let startedAt else { return nil }
        let elapsed = max(0, now - startedAt)
        let angle = startingAngle + elapsed * 2 * .pi / Self.period
        let circle = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        let u = min(1, elapsed / Self.entranceDuration)
        let blend = u * u * u * (u * (6 * u - 15) + 10)
        return CGPoint(x: origin.x + (circle.x - origin.x) * blend,
                       y: origin.y + (circle.y - origin.y) * blend)
    }
}
