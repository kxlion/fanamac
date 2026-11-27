// Lists the Fanatec products plugged into the Mac, to say why no base is
// connected (PlayStation mode, a product without a profile). The devices are
// never opened: nothing is read from them and nothing is written.

import Foundation
@preconcurrency import IOKit.hid

final class FanatecWatcher: @unchecked Sendable {
    private let manager: IOHIDManager
    // Touched only on the main thread.
    private var devices: [IOHIDDevice] = []
    /// Product IDs of the Fanatec devices present, on the main thread.
    var onChange: (([Int]) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: FanatecIDs.vendorID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<FanatecWatcher>.fromOpaque(ctx!).takeUnretainedValue()
            if !me.devices.contains(where: { $0 === device }) { me.devices.append(device) }
            me.notify()
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<FanatecWatcher>.fromOpaque(ctx!).takeUnretainedValue()
            me.devices.removeAll { $0 === device }
            me.notify()
        }, ctx)
        // Scheduled but not opened: macOS still says what comes and goes.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    private func notify() {
        onChange?(devices.map { IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int ?? 0 })
    }
}
