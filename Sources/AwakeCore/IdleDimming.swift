import Foundation

@MainActor
public protocol DisplayBrightnessAccess: AnyObject {
    /// Stable display identifiers and normalized system-slider values.
    func levels() -> [String: Float]
    func setLevel(_ value: Float, for display: String) -> Bool
}

/// Captures each display once and journals before changing its real brightness.
@MainActor
public final class IdleDimming {
    public enum Status {
        case dimming, dimmed, unavailable, partiallyUnavailable
    }

    public static let minimumLevel: Float = 1 / 16
    public static let dimDuration: TimeInterval = 5
    public static let restoreDuration: TimeInterval = 0.5
    public private(set) var savedLevels: [String: Float]
    private let backend: any DisplayBrightnessAccess
    private let persist: ([String: Float]) -> Void
    private struct Transition {
        var from: [String: Float]
        var to: [String: Float]
        let start: TimeInterval
        let duration: TimeInterval
        let restoring: Bool
    }
    private var transition: Transition?
    private var dimmingDisplays: Set<String> = []
    private var failedDimmingDisplays: Set<String> = []
    public var status: Status {
        guard !dimmingDisplays.isEmpty else { return .unavailable }
        let failed = failedDimmingDisplays.intersection(dimmingDisplays)
        if !failed.isEmpty {
            return failed == dimmingDisplays ? .unavailable : .partiallyUnavailable
        }
        return transition?.restoring == false ? .dimming : .dimmed
    }
    public var isAnimating: Bool { transition != nil }
    public var transitionName: String {
        guard let transition else { return "none" }
        return transition.restoring ? "restoring" : "dimming"
    }

    public init(backend: any DisplayBrightnessAccess, savedLevels: [String: Float] = [:],
                persist: @escaping ([String: Float]) -> Void = { _ in }) {
        self.backend = backend
        self.savedLevels = savedLevels.filter { Self.valid($0.value) }
        self.persist = persist
    }

    private static func valid(_ value: Float) -> Bool { value.isFinite && (0...1).contains(value) }

    /// Symmetric ease-in-out: cubic-bezier(0.65, 0, 0.35, 1).
    /// Solve the curve's time coordinate before evaluating its brightness coordinate.
    private static func easedProgress(_ progress: Double) -> Float {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<24 {
            let t = (lower + upper) / 2
            let inverse = 1 - t
            let time = 3 * inverse * inverse * t * 0.65 + 3 * inverse * t * t * 0.35 + t * t * t
            if time < progress { lower = t } else { upper = t }
        }
        let t = (lower + upper) / 2
        return Float(3 * (1 - t) * t * t + t * t * t)
    }

    @discardableResult
    public func dim() -> Bool {
        let success = fadeDown(at: 0)
        return advance(to: Self.dimDuration) && success
    }

    /// Repeated idle ticks must not restart an in-progress five-second fade.
    @discardableResult
    public func fadeDown(at now: TimeInterval) -> Bool {
        if let transition, !transition.restoring { return true }
        let levels = backend.levels().filter { Self.valid($0.value) }
        dimmingDisplays = Set(levels.keys)
        guard !levels.isEmpty else { return false }
        var from: [String: Float] = [:]
        var to: [String: Float] = [:]
        for (id, current) in levels {
            guard current > Self.minimumLevel + 0.001 else {
                failedDimmingDisplays.remove(id)
                continue
            }
            if savedLevels[id] == nil {
                savedLevels[id] = current
                persist(savedLevels)
            }
            from[id] = current
            to[id] = Self.minimumLevel
        }
        transition = to.isEmpty ? nil : Transition(from: from, to: to, start: now,
            duration: Self.dimDuration, restoring: false)
        return true
    }

    /// Reverse from the actual current level, including halfway through dimming.
    /// Further input does not keep extending the half-second restoration.
    @discardableResult
    public func fadeUp(at now: TimeInterval) -> Bool {
        if let transition, transition.restoring { return true }
        guard !savedLevels.isEmpty else { transition = nil; return true }
        let available = backend.levels()
        var from: [String: Float] = [:]
        var to: [String: Float] = [:]
        for (id, original) in savedLevels {
            if let current = available[id], Self.valid(current) {
                from[id] = current
                to[id] = original
            }
        }
        transition = to.isEmpty ? nil : Transition(from: from, to: to, start: now,
            duration: Self.restoreDuration, restoring: true)
        return !to.isEmpty
    }

    /// Advance from monotonic time; the frame rate does not change the duration.
    @discardableResult
    public func advance(to now: TimeInterval) -> Bool {
        guard var plan = transition else { return true }
        let u = min(1, max(0, (now - plan.start) / plan.duration))
        let eased = Self.easedProgress(u)
        var success = true
        var journalChanged = false
        for (id, target) in plan.to {
            let start = plan.from[id]!
            let value = u >= 1 ? target : start + (target - start) * eased
            if backend.setLevel(value, for: id) {
                // Scheduling a retry is not success; only an observed write clears failure.
                failedDimmingDisplays.remove(id)
                if u >= 1 && plan.restoring {
                    savedLevels.removeValue(forKey: id)
                    journalChanged = true
                }
            } else {
                success = false
                if !plan.restoring { failedDimmingDisplays.insert(id) }
                plan.to.removeValue(forKey: id)
                plan.from.removeValue(forKey: id)
            }
        }
        transition = u >= 1 || plan.to.isEmpty ? nil : plan
        if journalChanged { persist(savedLevels) }
        return success
    }

    /// Disconnected or temporarily unavailable displays remain pending for retry.
    @discardableResult
    public func restore() -> Bool {
        transition = nil
        guard !savedLevels.isEmpty else { return true }
        let available = backend.levels()
        var changed = false
        for (id, original) in savedLevels where available[id] != nil {
            if backend.setLevel(original, for: id) {
                failedDimmingDisplays.remove(id)
                savedLevels.removeValue(forKey: id)
                changed = true
            }
        }
        if changed { persist(savedLevels) }
        return savedLevels.isEmpty
    }
}
