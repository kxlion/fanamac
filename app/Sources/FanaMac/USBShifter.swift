// Read-only watcher for a Fanatec shifter plugged into the Mac with the
// ClubSport USB adapter. Nothing is ever written to it.

import Foundation
@preconcurrency import IOKit.hid

final class USBShifter: @unchecked Sendable {
    private let manager: IOHIDManager
    private var count = 0
    /// Called on the main thread when the adapter is plugged in or removed.
    var onPresence: ((Bool) -> Void)?
    /// Raw 5-byte reports, on the main thread.
    var onInput: (([UInt8]) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: FanatecIDs.vendorID, kIOHIDProductIDKey: FanatecIDs.usbShifter]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, _ in
            let me = Unmanaged<USBShifter>.fromOpaque(ctx!).takeUnretainedValue()
            me.count += 1; me.onPresence?(true)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            let me = Unmanaged<USBShifter>.fromOpaque(ctx!).takeUnretainedValue()
            me.count = max(0, me.count - 1); me.onPresence?(me.count > 0)
        }, ctx)
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, result, _, _, _, report, length in
            guard result == kIOReturnSuccess, length > 0 else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<USBShifter>.fromOpaque(ctx!).takeUnretainedValue().onInput?(bytes)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
