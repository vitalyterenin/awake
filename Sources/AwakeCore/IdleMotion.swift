import Foundation
import CoreGraphics

/// Uses monotonic time supplied by the caller. Own mouse events never reset idle.
public struct IdleMotion {
    public static let delay: TimeInterval = 300
    public static let radius: CGFloat = 6
    public static let period: TimeInterval = 24
    public static let eventMarker: Int64 = 0x4157414B45

    public private(set) var lastActivity: TimeInterval
    public private(set) var startedAt: TimeInterval?
    private var center = CGPoint.zero
    private var startingAngle: Double = 0
    private var radius: CGFloat = Self.radius
    private var bounds = CGRect.zero

    public init(now: TimeInterval) { lastActivity = now }

    public mutating func activity(at now: TimeInterval, marker: Int64 = 0) {
        guard marker != Self.eventMarker else { return }
        lastActivity = now
        startedAt = nil
    }

    public func isReady(at now: TimeInterval) -> Bool {
        now - lastActivity >= Self.delay
    }

    /// Start exactly at the cursor; clamp the small orbit to the current display.
    /// At extreme corners the path is clipped, without a starting jump.
    public mutating func begin(at now: TimeInterval, pointer: CGPoint, display: CGRect) {
        bounds = CGRect(x: display.minX, y: display.minY, width: display.width - 1, height: display.height - 1)
        radius = max(0, min(Self.radius, min(bounds.width, bounds.height) / 4))
        let xSign: CGFloat = pointer.x + 2 * radius <= bounds.maxX ? 1 : -1
        let proposed = CGPoint(x: pointer.x + xSign * radius, y: pointer.y)
        center = CGPoint(
            x: min(max(proposed.x, bounds.minX + radius), bounds.maxX - radius),
            y: min(max(proposed.y, bounds.minY + radius), bounds.maxY - radius)
        )
        // Preserve the exact initial position, including the outermost screen pixel.
        radius = hypot(pointer.x - center.x, pointer.y - center.y)
        startingAngle = atan2(pointer.y - center.y, pointer.x - center.x)
        startedAt = now
    }

    public func point(at now: TimeInterval) -> CGPoint? {
        guard let startedAt else { return nil }
        let angle = startingAngle + max(0, now - startedAt) * 2 * .pi / Self.period
        return CGPoint(x: min(max(center.x + radius * cos(angle), bounds.minX), bounds.maxX),
                       y: min(max(center.y + radius * sin(angle), bounds.minY), bounds.maxY))
    }
}
