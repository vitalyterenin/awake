import AppKit
import AwakeCore
import Darwin

/// The native system-slider API is private; resolve symbols and check every result.
@MainActor
final class SystemBrightness: DisplayBrightnessAccess {
    private typealias Read = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Write = @convention(c) (UInt32, Float) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let read: Read?
    private let write: Write?
    private var displayIDs: [String: CGDirectDisplayID] = [:]

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        if let handle, let get = dlsym(handle, "DisplayServicesGetBrightness"),
           let set = dlsym(handle, "DisplayServicesSetBrightness") {
            read = unsafeBitCast(get, to: Read.self)
            write = unsafeBitCast(set, to: Write.self)
        } else { read = nil; write = nil }
    }

    private func displays() -> [String: CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [:] }
        var result: [String: CGDirectDisplayID] = [:]
        for id in ids.prefix(Int(count)) where CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0 {
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                result[CFUUIDCreateString(nil, uuid) as String] = id
            }
        }
        return result
    }

    func levels() -> [String: Float] {
        guard let read, write != nil else { return [:] }
        displayIDs = displays()
        var result: [String: Float] = [:]
        for (uuid, id) in displayIDs {
            var level: Float = 0
            if read(id, &level) == 0 && level.isFinite && (0...1).contains(level) { result[uuid] = level }
        }
        return result
    }

    func setLevel(_ value: Float, for display: String) -> Bool {
        guard let write, value.isFinite, (0...1).contains(value), let id = displayIDs[display],
              CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0 else { return false }
        return write(id, value) == 0
    }
}
