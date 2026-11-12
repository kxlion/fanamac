// A diagnostic is what the owner of a base sends so FanaMac can support it
// without anyone else having that base: the USB identity and HID descriptor of
// every Fanatec device, the base's tuning report, and what moved in its input
// reports while the wheel and pedals were used. No serial number is kept.
//
// `DiagnosticReview` reads one with FanaMac's own decoders and says what
// matches, what doesn't, and which profile the base would get (docs/BASES.md).

import Foundation

public func hexString(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

public func hexBytes(_ text: String) -> [UInt8]? {
    let digits = Array(text.utf8)
    guard digits.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(digits.count / 2)
    for i in stride(from: 0, to: digits.count, by: 2) {
        guard let b = UInt8(String(decoding: digits[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
        out.append(b)
    }
    return out
}

public struct Diagnostic: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public static let maxFileSize = 2 * 1024 * 1024

    public var format = Diagnostic.currentFormat
    /// FanaMac's version, or "cli".
    public var fanamac: String
    public var macOS: String
    /// How long the input reports were watched.
    public var seconds: Double
    public var devices: [Device]

    public init(fanamac: String, macOS: String, seconds: Double, devices: [Device]) {
        self.fanamac = fanamac; self.macOS = macOS; self.seconds = seconds; self.devices = devices
    }

    /// One HID interface of a Fanatec device (a base can have several).
    public struct Device: Codable, Equatable, Sendable {
        /// Four hex digits, as USB tools show it.
        public var productID: String
        public var product: String
        public var usagePage: Int
        public var usage: Int
        public var maxInputReportSize: Int
        public var maxOutputReportSize: Int
        public var maxFeatureReportSize: Int
        /// The device's own version number (firmware).
        public var version: Int
        /// HID report descriptor, in hex.
        public var descriptor: String
        /// The handshake and the tuning read request were sent to this interface.
        public var askedTuning: Bool
        public var reports: [Report]

        public init(productID: Int, product: String, usagePage: Int, usage: Int, maxInputReportSize: Int,
                    maxOutputReportSize: Int, maxFeatureReportSize: Int, version: Int, descriptor: [UInt8],
                    asked askedTuning: Bool, reports: [Report]) {
            self.productID = String(format: "%04X", productID); self.product = product
            self.usagePage = usagePage; self.usage = usage
            self.maxInputReportSize = maxInputReportSize; self.maxOutputReportSize = maxOutputReportSize
            self.maxFeatureReportSize = maxFeatureReportSize; self.version = version
            self.descriptor = hexString(descriptor); self.askedTuning = askedTuning; self.reports = reports
        }

        public var product16: Int? { Int(productID, radix: 16) }
        /// The interface that carries the base's reports: joystick or gamepad.
        public var isJoystick: Bool { usagePage == 0x01 && [0x04, 0x05].contains(usage) }
    }

    /// Every input report seen with one ID and one length, summed up.
    public struct Report: Codable, Equatable, Sendable {
        public var id: Int
        /// Bytes, report ID included.
        public var length: Int
        public var count: Int
        /// The first one, in hex.
        public var first: String
        /// Lowest and highest value seen for each byte, in hex.
        public var low: String
        public var high: String
        /// For the base's own reports (ID FF): up to 8 different ones, whole.
        public var distinct: [String]

        public init(bytes: [UInt8]) {
            id = Int(bytes.first ?? 0); length = bytes.count; count = 0
            first = hexString(bytes); low = first; high = first; distinct = []
            add(bytes)
        }

        public mutating func add(_ bytes: [UInt8]) {
            guard bytes.count == length, var lo = hexBytes(low), var hi = hexBytes(high) else { return }
            count += 1
            for i in 0..<length { lo[i] = min(lo[i], bytes[i]); hi[i] = max(hi[i], bytes[i]) }
            low = hexString(lo); high = hexString(hi)
            if id == 0xFF, distinct.count < 8, !distinct.contains(hexString(bytes)) { distinct.append(hexString(bytes)) }
        }

        /// Indexes of the bytes that changed during the capture.
        public var movedBytes: [Int] {
            guard let lo = hexBytes(low), let hi = hexBytes(high), lo.count == hi.count else { return [] }
            return lo.indices.filter { lo[$0] != hi[$0] }
        }
    }

    public static func load(_ url: URL) throws -> Diagnostic {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxFileSize else { throw DiagnosticError.tooLarge }
        let d = try JSONDecoder().decode(Diagnostic.self, from: Data(contentsOf: url))
        guard d.format == currentFormat else { throw DiagnosticError.unknownFormat(d.format) }
        return d
    }

    public func write(to url: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// File name for the test fixtures: product IDs, then the base's name.
    public var fixtureName: String {
        let base = devices.first { $0.isJoystick } ?? devices.first
        let words = (base?.product ?? "device").lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        return "\(base?.productID.lowercased() ?? "0000")-\(words.isEmpty ? "device" : words).json"
    }
}

public enum DiagnosticError: Error, Equatable, CustomStringConvertible {
    case tooLarge
    case unknownFormat(Int)
    public var description: String {
        switch self {
        case .tooLarge: return "the file is too large to be a diagnostic"
        case let .unknownFormat(f): return "diagnostic format \(f) is not known to this version"
        }
    }
}

/// What FanaMac makes of a diagnostic.
public struct DiagnosticReview: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var title: String
        /// Facts read from the capture.
        public var facts: [String] = []
        /// What doesn't match FanaMac's decoders: to look at before trusting the base.
        public var problems: [String] = []
        /// Profile the base would get, with what in it is still a guess.
        public var profile: BaseProfile?
        public var guesses: [String] = []
    }

    public var items: [Item]
    public var problems: [String] { items.flatMap(\.problems) }

    /// `references` are diagnostics of tested bases: a descriptor identical to
    /// one of theirs means the input reports have the same layout.
    public init(_ d: Diagnostic, catalog: BaseCatalog = BaseCatalog(), references: [Diagnostic] = []) {
        let known = references.flatMap(\.devices).filter { dev in
            dev.isJoystick && dev.product16.flatMap(catalog.profile(productID:))?.isTested == true
        }
        items = d.devices.map { Self.review($0, catalog: catalog, known: known) }
    }

    private static func review(_ dev: Diagnostic.Device, catalog: BaseCatalog, known: [Diagnostic.Device]) -> Item {
        let kind = dev.product16.map(catalog.classify(productID:)) ?? .unknown
        var item = Item(title: "\(dev.product) (0EB7/\(dev.productID)), usage \(hex2(dev.usagePage))/\(hex2(dev.usage))")
        item.facts.append("Reports: input \(dev.maxInputReportSize) bytes, output \(dev.maxOutputReportSize), feature \(dev.maxFeatureReportSize); descriptor \(dev.descriptor.count / 2) bytes; version \(dev.version)")
        switch kind {
        case let .accessory(name):
            item.facts.append("Accessory: \(name). FanaMac never writes to it.")
            return item
        case let .consoleMode(name):
            item.facts.append("\(name) in PlayStation mode.")
            item.problems.append("The base is in PlayStation mode: switch it to PC mode and capture again.")
            return item
        case let .base(p):
            item.facts.append("Profile: \(p.name), \(p.status.rawValue)")
        case .unknown:
            item.facts.append("No profile for this product ID.")
        }
        guard dev.isJoystick else {
            item.facts.append("Not the joystick interface: FanaMac doesn't use it.")
            return item
        }

        if let same = known.first(where: { $0.descriptor == dev.descriptor && !dev.descriptor.isEmpty }) {
            item.facts.append("Descriptor identical to the \(same.product)'s: same input layout.")
        } else if dev.descriptor.isEmpty {
            item.problems.append("No HID descriptor in the capture.")
        } else if !known.isEmpty {
            item.problems.append("Descriptor differs from every tested base: check the input layout (axes, buttons) by hand.")
        }
        if dev.maxOutputReportSize > 0, dev.maxOutputReportSize < TuningProtocol.reportSize {
            item.problems.append("Output reports are \(dev.maxOutputReportSize) bytes: too short for the 64-byte tuning frames.")
        }

        reviewInput(dev, into: &item)
        let tuning = reviewTuning(dev, profile: { if case let .base(p) = kind { return p } else { return nil } }(), into: &item)

        if case let .base(p) = kind {
            if p.tuningMenu, dev.askedTuning, !tuning { item.problems.append("The profile says Tuning Menu over USB, but the base sent no tuning report.") }
            if !p.tuningMenu, tuning { item.problems.append("The base sent a tuning report, but the profile says it has no Tuning Menu over USB.") }
        } else {
            // The 8-bit force frame is read by every base; the 16-bit one only by some.
            item.profile = BaseProfile(productID: dev.product16 ?? 0, name: dev.product, highResForce: false, tuningMenu: tuning, maxAngle: 900)
            item.guesses = ["highResForce: false is the safe choice, the base may take 16-bit forces",
                            "maxAngle: 900 is the smallest of the known bases, ask the owner for the real one"]
            if !dev.askedTuning { item.guesses.append("tuningMenu: the base wasn't asked for its tuning report (capture again with --ask-tuning)") }
        }
        return item
    }

    private static func reviewInput(_ dev: Diagnostic.Device, into item: inout Item) {
        let inputs = dev.reports.filter { $0.id != 0xFF }
        if inputs.isEmpty { item.problems.append("No input report received."); return }
        for r in inputs {
            item.facts.append("Input report \(hex2(r.id)): \(r.length) bytes, \(r.count) received, bytes that moved: \(ranges(r.movedBytes))")
        }
        guard let main = inputs.first(where: { $0.id == 0x01 }) else {
            item.problems.append("No input report 01: FanaMac reads the wheel, pedals and buttons from it.")
            return
        }
        guard let bytes = hexBytes(main.first), InputReport(bytes: bytes) != nil else {
            item.problems.append("Input report 01 is \(main.length) bytes: FanaMac expects at least 34.")
            return
        }
        // Wheel and pedals sit in bytes 17 to 24 on the CSL DD.
        let moved = Set(main.movedBytes)
        if moved.isDisjoint(with: 17...18) { item.facts.append("The steering bytes (17-18) didn't move: was the wheel turned?") }
        let outside = main.movedBytes.filter { $0 > 33 }
        if !outside.isEmpty { item.problems.append("Bytes \(ranges(outside)) moved past the 34 bytes FanaMac decodes.") }
        if let rim = InputReport(bytes: bytes)?.rimName { item.facts.append("Rim: \(rim)") }
    }

    /// Returns whether the base sent a tuning report.
    private static func reviewTuning(_ dev: Diagnostic.Device, profile: BaseProfile?, into item: inout Item) -> Bool {
        let own = dev.reports.filter { $0.id == 0xFF }.flatMap(\.distinct).compactMap(hexBytes)
        let snaps = own.compactMap { TuningSnapshot(report: $0) }
        for other in own where other.count < 2 || other[1] != 0x03 {
            item.facts.append("Other report FF: \(hexString(Array(other.prefix(12))))…")
        }
        guard !snaps.isEmpty else {
            item.facts.append(dev.askedTuning ? "No tuning report received after the request." : "Tuning report not requested.")
            return false
        }
        for snap in snaps {
            let setup = snap.isAutoSetup ? "Auto Setup" : snap.slot.map { "setup \($0)" } ?? "no setup (code \(snap.raw[2] & 0x7F))"
            item.facts.append("Tuning report: \(setup), \(snap.advancedMode ? "Advanced" : "Standard") menu")
            item.facts.append("  " + allParams.map { "\($0.wheelLabel) \(formatValue($0.key, snap.value($0.key)))" }.joined(separator: ", "))
            for p in allParams where profile?.has(p.key) != false {
                let v = snap.value(p.key)
                if !p.range.contains(v) { item.problems.append("\(p.wheelLabel) reads \(v), outside \(p.range.lowerBound)…\(p.range.upperBound): another encoding, or a setting this base doesn't have.") }
            }
            let sen = snap.value(.SEN)
            if let max = profile?.maxAngle, sen > max { item.problems.append("SEN reads \(sen)°, above the profile's \(max)°.") }
            let used = Set(TuningProtocol.registers.values).union([TuningProtocol.brakeForceAlt])
            let extra = (3..<TuningProtocol.reportSize).filter { !used.contains($0) && snap.raw[$0] != 0 }
            if !extra.isEmpty {
                item.facts.append("  Registers FanaMac doesn't use, not zero: " + extra.map { "\(hex2($0))=\(hex2(Int(snap.raw[$0])))" }.joined(separator: " "))
            }
            // Sending the setup back unchanged must not change a byte.
            var expected = [0xFF, 0x03, 0x00] + snap.raw[2..<(TuningProtocol.reportSize - 1)]
            expected[3] &= 0x7F
            if let frame = try? snap.writeFrame(for: snap.setup, profile: profile) {
                let changed = frame.indices.filter { frame[$0] != expected[$0] }
                if !changed.isEmpty { item.problems.append("Sending this setup back unchanged would rewrite register \(changed.map { hex2($0 - 1) }.joined(separator: ", ")).") }
            } else {
                item.problems.append("FanaMac can't build a write frame from this setup.")
            }
        }
        return true
    }

    private static func hex2(_ v: Int) -> String { String(format: "%02X", v) }

    /// [1, 2, 3, 7] → "1-3, 7".
    static func ranges(_ indexes: [Int]) -> String {
        guard var start = indexes.first else { return "none" }
        var parts: [String] = [], last = start
        for i in indexes.dropFirst() + [Int.max] {
            if i == last + 1 { last = i; continue }
            parts.append(start == last ? "\(start)" : "\(start)-\(last)")
            start = i; last = i
        }
        return parts.joined(separator: ", ")
    }

    /// The review as text, for the command-line tool.
    public var lines: [String] {
        var out: [String] = []
        for item in items {
            out.append(item.title)
            out += item.facts.map { "  " + $0 }
            out += item.problems.map { "  ! " + $0 }
            if let p = item.profile {
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                out.append("  Profile to try (save as a .json file in \(BaseCatalog.userFolder.path)):")
                out += (String(data: (try? enc.encode(p)) ?? Data(), encoding: .utf8) ?? "").split(separator: "\n").map { "    " + $0 }
                out += item.guesses.map { "  ? " + $0 }
            }
            out.append("")
        }
        out.append(problems.isEmpty ? "Nothing in this capture contradicts FanaMac's decoders." : "\(problems.count) point(s) to look at, marked with !")
        return out
    }
}
