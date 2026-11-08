// USB access to the CSL DD through IOKit HID. No driver, no kernel extension.

import Foundation
@preconcurrency import IOKit.hid

struct WheelbaseInfo: Equatable {
    var product: String
    var vendorID: Int
    var productID: Int
}

enum WheelbaseError: LocalizedError {
    case notConnected
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "No CSL DD found. Is the base on, in PC mode (red LED)?"
        case let .openFailed(r): return "Could not open the wheelbase (IOKit 0x\(String(UInt32(bitPattern: r), radix: 16)))."
        case let .writeFailed(r): return "The wheelbase refused the write (IOKit 0x\(String(UInt32(bitPattern: r), radix: 16)))."
        }
    }
}

/// Watches for the base being plugged/unplugged and writes tuning frames.
final class Wheelbase: @unchecked Sendable {
    private let manager: IOHIDManager
    private let marksBase: Bool
    private let lock = NSLock()
    private var devices: [IOHIDDevice] = []
    private let writeQueue = DispatchQueue(label: "fanamac.hid.write")
    var onChange: ((WheelbaseInfo?) -> Void)?
    /// Raw input reports (pedals, buttons, rim), delivered on the main thread.
    var onInput: (([UInt8]) -> Void)?

    /// The command-line tool opens the base without marking it (`marksBase: false`).
    init(marksBase: Bool = true) {
        self.marksBase = marksBase
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: FanatecIDs.vendorID, kIOHIDProductIDKey: FanatecIDs.cslDD]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<Wheelbase>.fromOpaque(ctx!).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<Wheelbase>.fromOpaque(ctx!).takeUnretainedValue().removed(device)
        }, ctx)
        // Read-only: the base streams report 0x01 on its own.
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, result, _, _, reportID, report, length in
            guard result == kIOReturnSuccess, length > 0 else { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            if bytes.first != UInt8(truncatingIfNeeded: reportID), reportID != 0 { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
            Unmanaged<Wheelbase>.fromOpaque(ctx!).takeUnretainedValue().onInput?(bytes)
        }, ctx)
        // Common modes: keeps reading while a click is held in our own window.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func added(_ d: IOHIDDevice) {
        lock.lock(); if !devices.contains(where: { $0 === d }) { devices.append(d) }; lock.unlock()
        if marksBase { NativeForce.mark(d) }
        notify()
    }

    /// Takes FanaMac's force feedback plug-in off the base (when FanaMac quits).
    func unmarkAll() {
        lock.lock(); let all = devices; lock.unlock()
        all.forEach(NativeForce.unmark)
    }

    private func removed(_ d: IOHIDDevice) {
        lock.lock(); devices.removeAll { $0 === d }; lock.unlock()
        notify()
    }

    private func notify() {
        let info = target().map { d in
            WheelbaseInfo(product: prop(d, kIOHIDProductKey) as? String ?? "FANATEC Wheel",
                          vendorID: prop(d, kIOHIDVendorIDKey) as? Int ?? 0,
                          productID: prop(d, kIOHIDProductIDKey) as? Int ?? 0)
        }
        DispatchQueue.main.async { self.onChange?(info) }
    }

    /// The base may expose several HID interfaces; the joystick one (page 0x01,
    /// usage 0x04/0x05) carries the 0x01 and 0xFF reports.
    private func target() -> IOHIDDevice? {
        lock.lock(); defer { lock.unlock() }
        return devices.first { d in
            (prop(d, kIOHIDPrimaryUsagePageKey) as? Int) == 0x01 && [0x04, 0x05].contains(prop(d, kIOHIDPrimaryUsageKey) as? Int ?? -1)
        } ?? devices.first
    }

    private func prop(_ d: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(d, key as CFString) }

    /// Writes one output report now, on the caller's thread, with no pause.
    /// For force frames: they must not wait behind a slow tuning read.
    func writeNow(_ frame: [UInt8]) throws {
        guard let device = target() else { throw WheelbaseError.notConnected }
        let r = frame.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(frame[0]), $0.baseAddress!, frame.count)
        }
        guard r == kIOReturnSuccess else { throw WheelbaseError.writeFailed(r) }
    }

    /// Writes output reports in order (64-byte FF 03 frames, the 0x01 handshake).
    func write(_ frames: [[UInt8]]) async throws {
        guard let device = target() else { throw WheelbaseError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    // The manager already holds the device open. Opening and closing it
                    // here again cut the input reports (pedals, shifter) for a moment.
                    for frame in frames {
                        Recorder.shared.frame(frame)
                        // The report ID is the first byte and stays in the buffer.
                        let r = frame.withUnsafeBufferPointer {
                            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(frame[0]), $0.baseAddress!, frame.count)
                        }
                        guard r == kIOReturnSuccess else { throw WheelbaseError.writeFailed(r) }
                        Thread.sleep(forTimeInterval: frame == TuningProtocol.initReport ? 0.02 : 0.01)
                    }
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}
