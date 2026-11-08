import Foundation
import IOKit.ps
import AwakeCore

@MainActor
final class PowerSourceMonitor {
    var didChange: (@MainActor () -> Void)?
    private var source: CFRunLoopSource?
    private let copySnapshot: () -> Unmanaged<CFTypeRef>?
    private let sourceType: (CFTypeRef) -> String?

    init(copySnapshot: @escaping () -> Unmanaged<CFTypeRef>? = { IOPSCopyPowerSourcesInfo() },
         sourceType: @escaping (CFTypeRef) -> String? = {
             IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String?
         }) {
        self.copySnapshot = copySnapshot
        self.sourceType = sourceType
    }

    var current: PowerSupply {
        guard let snapshot = copySnapshot() else { return .unknown }
        let info = snapshot.takeRetainedValue()
        guard let type = sourceType(info) else { return .unknown }
        switch type {
        case kIOPSACPowerValue: return .externalPower
        case kIOPSBatteryPowerValue, kIOPMUPSPowerKey: return .battery
        default: return .unknown
        }
    }

    func start() {
        guard source == nil else { return }
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue().didChange?()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
    }
}
