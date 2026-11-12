// Captures a diagnostic (FanaMacCore/Diagnostic.swift): every Fanatec HID
// device, its descriptor, and its input reports for a few seconds.
//
// Nothing is written to a device, with one exception: a base whose profile has
// the Tuning Menu gets the handshake and the tuning read request, the two
// frames FanaMac sends every time it connects. A product without a profile is
// only listened to, unless `askUnknown` is set.

import Foundation
@preconcurrency import IOKit.hid

final class DiagnosticCapture: @unchecked Sendable {
    private let manager: IOHIDManager
    private let catalog: BaseCatalog
    private let askUnknown: Bool
    // Touched only on the main thread.
    private var devices: [IOHIDDevice] = []
    private var asked: Set<Int> = []
    private var reports: [Int: [Diagnostic.Report]] = [:]

    private init(catalog: BaseCatalog, askUnknown: Bool) {
        self.catalog = catalog
        self.askUnknown = askUnknown
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: FanatecIDs.vendorID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<DiagnosticCapture>.fromOpaque(ctx!).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, result, sender, _, reportID, report, length in
            guard result == kIOReturnSuccess, length > 0, let sender else { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            if bytes.first != UInt8(truncatingIfNeeded: reportID), reportID != 0 { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
            Unmanaged<DiagnosticCapture>.fromOpaque(ctx!).takeUnretainedValue().received(bytes, from: sender)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Call on the main thread, with its run loop running. `completion` comes
    /// back on the main thread after `seconds`.
    static func run(seconds: Double, catalog: BaseCatalog, version: String, askUnknown: Bool = false,
                    completion: @escaping @Sendable (Diagnostic) -> Void) {
        let capture = DiagnosticCapture(catalog: catalog, askUnknown: askUnknown)
        // The devices need a moment to show up before they can be asked anything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { capture.askTuning() }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let result = capture.finish(seconds: seconds, version: version)
            completion(result)
        }
    }

    private func added(_ d: IOHIDDevice) {
        if !devices.contains(where: { $0 === d }) { devices.append(d) }
    }

    private func index(of sender: UnsafeMutableRawPointer) -> Int? {
        devices.firstIndex { Unmanaged.passUnretained($0).toOpaque() == sender }
    }

    private func received(_ bytes: [UInt8], from sender: UnsafeMutableRawPointer) {
        guard let i = index(of: sender) else { return }
        var list = reports[i] ?? []
        if let j = list.firstIndex(where: { $0.id == Int(bytes[0]) && $0.length == bytes.count }) {
            list[j].add(bytes)
        } else if list.count < 32 {
            list.append(Diagnostic.Report(bytes: bytes))
        }
        reports[i] = list
    }

    private func int(_ d: IOHIDDevice, _ key: String) -> Int { IOHIDDeviceGetProperty(d, key as CFString) as? Int ?? 0 }

    private func isJoystick(_ d: IOHIDDevice) -> Bool {
        int(d, kIOHIDPrimaryUsagePageKey) == 0x01 && [0x04, 0x05].contains(int(d, kIOHIDPrimaryUsageKey))
    }

    private func askTuning() {
        for (i, d) in devices.enumerated() where isJoystick(d) {
            switch catalog.classify(productID: int(d, kIOHIDProductIDKey)) {
            case let .base(p): guard p.tuningMenu else { continue }
            case .accessory, .consoleMode: continue
            case .unknown: guard askUnknown else { continue }
            }
            asked.insert(i)
            for frame in [TuningProtocol.initReport, TuningProtocol.requestTuning] {
                _ = frame.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(frame[0]), $0.baseAddress!, frame.count)
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    private func finish(seconds: Double, version: String) -> Diagnostic {
        let list = devices.enumerated().map { i, d in
            Diagnostic.Device(
                productID: int(d, kIOHIDProductIDKey),
                product: IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "",
                usagePage: int(d, kIOHIDPrimaryUsagePageKey), usage: int(d, kIOHIDPrimaryUsageKey),
                maxInputReportSize: int(d, kIOHIDMaxInputReportSizeKey),
                maxOutputReportSize: int(d, kIOHIDMaxOutputReportSizeKey),
                maxFeatureReportSize: int(d, kIOHIDMaxFeatureReportSizeKey),
                version: int(d, kIOHIDVersionNumberKey),
                descriptor: (IOHIDDeviceGetProperty(d, kIOHIDReportDescriptorKey as CFString) as? Data).map(Array.init) ?? [],
                asked: asked.contains(i),
                reports: (reports[i] ?? []).sorted { ($0.id, $0.length) < ($1.id, $1.length) })
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Diagnostic(fanamac: version, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", seconds: seconds,
                          devices: list.sorted { ($0.productID, $0.usagePage, $0.usage) < ($1.productID, $1.usagePage, $1.usage) })
    }
}
