import Foundation
import IOKit.ps
import AwakeCore

@MainActor
final class PowerSourceMonitor {
    var didChange: (() -> Void)?
    private var source: CFRunLoopSource?

    var current: PowerSupply {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return .unknown }
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
