import Foundation
import IOKit.ps
import Testing
import AwakeCore
@testable import AwakeRuntime

@Test @MainActor func missingPowerSnapshotPausesAndCanRecover() {
    var available = false
    var typeReads = 0
    let monitor = PowerSourceMonitor(copySnapshot: {
        available ? Unmanaged.passRetained("snapshot" as CFTypeRef) : nil
    }, sourceType: { _ in
        typeReads += 1
        return kIOPSACPowerValue
    })
    #expect(monitor.current == .unknown)
    #expect(typeReads == 0)
    available = true
    #expect(monitor.current == .externalPower)
    #expect(typeReads == 1)
}

@Test @MainActor func knownPowerTypesAndUnavailableTypeKeepTheirPolicy() {
    var sourceType: String?
    let monitor = PowerSourceMonitor(copySnapshot: { Unmanaged.passRetained("snapshot" as CFTypeRef) },
                                     sourceType: { _ in sourceType })
    for (type, expected) in [(kIOPSACPowerValue, PowerSupply.externalPower),
                             (kIOPSBatteryPowerValue, .battery), (kIOPMUPSPowerKey, .battery),
                             ("unrecognized", .unknown)] {
        sourceType = type
        #expect(monitor.current == expected)
    }
    sourceType = nil
    #expect(monitor.current == .unknown)
}
