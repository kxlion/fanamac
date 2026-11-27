// FanaMac — Fanatec CSL DD tuning protocol.
// Pure byte building, no hardware access. Protocol facts (report IDs, register
// addresses, SEN encoding, scaling, setup numbering, the FF 03 02 read request)
// were checked on a real CSL DD.

import Foundation

public enum FanatecIDs {
    public static let vendorID = 0x0EB7
    public static let cslDD = 0x0020
    /// ClubSport Shifter SQ V1.5 plugged into the Mac with its ClubSport USB adapter.
    public static let usbShifter = 0x1A92
}

public enum ParamKey: String, CaseIterable, Codable, Sendable {
    case SEN, FF, FFS, NDP, NFR, NIN, INT, FEI, FOR, SPR, DPR, SHO, BLI, BRF, FUL
}

public struct Param: Sendable {
    public let key: ParamKey
    public let wheelLabel: String     // what the wheel screen shows
    public let name: String
    public let help: String
    public let range: ClosedRange<Int>
    public let step: Int
    public let defaultValue: Int
    public let unit: String
    public let standard: Bool         // shown in the wheel's Standard menu
}

/// Official Fanatec defaults ("Tuning Menu parameters").
public let allParams: [Param] = [
    Param(key: .FF, wheelLabel: "FFB", name: "Force feedback", help: "Overall motor strength.", range: 0...100, step: 1, defaultValue: 100, unit: "%", standard: true),
    Param(key: .SEN, wheelLabel: "SEN", name: "Steering angle", help: "Lock-to-lock rotation. Auto lets the game decide.", range: 0...2520, step: 10, defaultValue: 0, unit: "°", standard: true),
    Param(key: .NDP, wheelLabel: "NDP", name: "Natural damper", help: "Resistance that calms oscillations.", range: 0...100, step: 1, defaultValue: 50, unit: "%", standard: true),
    Param(key: .BRF, wheelLabel: "BRF", name: "Brake force", help: "Pressure needed for 100% brake on load-cell pedals.", range: 0...100, step: 5, defaultValue: 50, unit: "%", standard: true),
    Param(key: .FFS, wheelLabel: "FFS", name: "FFB scaling", help: "Linear avoids clipping, Peak gives maximum torque.", range: 0...1, step: 1, defaultValue: 1, unit: "", standard: false),
    Param(key: .NFR, wheelLabel: "NFR", name: "Natural friction", help: "Mechanical friction of the steering.", range: 0...100, step: 1, defaultValue: 0, unit: "%", standard: false),
    Param(key: .NIN, wheelLabel: "NIN", name: "Natural inertia", help: "Extra steering weight.", range: 0...100, step: 1, defaultValue: 0, unit: "%", standard: false),
    Param(key: .INT, wheelLabel: "INT", name: "Interpolation filter", help: "Smooths low-rate game FFB. 0 is off.", range: 0...20, step: 1, defaultValue: 11, unit: "", standard: false),
    Param(key: .FEI, wheelLabel: "FEI", name: "Force effect intensity", help: "Sharpness of kerbs and road details.", range: 0...100, step: 5, defaultValue: 100, unit: "%", standard: false),
    Param(key: .FOR, wheelLabel: "FOR", name: "Game force effect", help: "Multiplier for the game's constant force.", range: 0...120, step: 10, defaultValue: 100, unit: "%", standard: false),
    Param(key: .SPR, wheelLabel: "SPR", name: "Game spring effect", help: "Multiplier for the game's centering spring.", range: 0...120, step: 10, defaultValue: 100, unit: "%", standard: false),
    Param(key: .DPR, wheelLabel: "DPR", name: "Game damper effect", help: "Multiplier for the game's damper.", range: 0...120, step: 10, defaultValue: 100, unit: "%", standard: false),
    Param(key: .SHO, wheelLabel: "SHO", name: "Wheel vibration", help: "Rumble motors in the wheel rim.", range: 0...100, step: 10, defaultValue: 100, unit: "%", standard: false),
    Param(key: .BLI, wheelLabel: "BLI", name: "Brake level indicator", help: "Vibration above this brake level. 0 is off.", range: 0...100, step: 5, defaultValue: 0, unit: "%", standard: false),
    Param(key: .FUL, wheelLabel: "FUL", name: "FullForce", help: "High-frequency road and engine detail. 0 is off.", range: 0...100, step: 1, defaultValue: 100, unit: "%", standard: false),
]

public func param(_ key: ParamKey) -> Param { allParams.first { $0.key == key }! }

public enum TuningError: Error, Equatable, CustomStringConvertible {
    case outOfRange(ParamKey, Int)
    case badSlot(Int)
    public var description: String {
        switch self {
        case let .outOfRange(k, v): return "\(param(k).wheelLabel) = \(v) is out of range"
        case let .badSlot(s): return "Setup \(s) is invalid (1 to 5)"
        }
    }
}

/// One of the wheelbase's 5 setups. JSON uses the register names.
public struct Setup: Equatable, Codable, Sendable {
    public private(set) var values: [ParamKey: Int]

    public init() { values = Dictionary(uniqueKeysWithValues: allParams.map { ($0.key, $0.defaultValue) }) }

    public subscript(_ key: ParamKey) -> Int {
        get { values[key] ?? param(key).defaultValue }
        set { values[key] = newValue }
    }

    /// `maxAngle` is the largest steering angle of the base the setup is for.
    public func validate(maxAngle: Int = 2520) throws {
        for p in allParams {
            let v = self[p.key]
            if !p.range.contains(v) || (p.key == .SEN && v > 0 && (v < 90 || v > maxAngle)) { throw TuningError.outOfRange(p.key, v) }
        }
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let raw = try decoder.singleValueContainer().decode([String: Int].self)
        for (k, v) in raw { if let key = ParamKey(rawValue: k) { values[key] = v } }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
    }
}

public enum TuningProtocol {
    public static let reportSize = 64
    public static let reportIDDirectDrive: UInt8 = 0xFF
    public static let cmdTuning: UInt8 = 0x03
    /// "Auto" is the base's maximum angle, 2530°, which hands the angle to the game.
    public static let senAutoCode: UInt8 = 0x7E
    /// BLI reads 101 when it is off.
    public static let bliOffCode: UInt8 = 101
    /// Handshake sent on open (report 0x01).
    public static let initReport: [UInt8] = [0x01, 0xF5, 0, 0, 0, 0, 0, 0]

    /// Register address. In the base's tuning report a register sits at its address;
    /// in a write frame it sits at address + 1 (byte 2 is the write sub-command).
    public static let registers: [String: Int] = [
        "SLOT": 0x02, "SEN": 0x03, "FF": 0x04, "SHO": 0x05, "BLI": 0x06, "FFS": 0x07,
        "FOR": 0x0A, "SPR": 0x0B, "DPR": 0x0C, "NDP": 0x0D, "NFR": 0x0E, "BRF": 0x10,
        "FEI": 0x11, "INT": 0x14, "NIN": 0x15, "FUL": 0x16,
    ]
    /// Brake force: the wheel only changes 0x10, so that is what's read. 0x0F is written too.
    public static let brakeForceAlt = 0x0F

    static let tensScaled: Set<ParamKey> = [.FOR, .SPR, .DPR, .SHO]

    /// Setup N is sent as N + 1 (1 means "auto" to the base).
    public static func slotCode(_ slot: Int) throws -> UInt8 {
        guard (1...5).contains(slot) else { throw TuningError.badSlot(slot) }
        return UInt8(slot + 1)
    }

    /// Degrees / 10 − 127, modulo 256; Auto is 2530°.
    public static func encodeSEN(_ degrees: Int) throws -> UInt8 {
        if degrees == 0 { return senAutoCode }
        guard (90...2520).contains(degrees) else { throw TuningError.outOfRange(.SEN, degrees) }
        return UInt8(truncatingIfNeeded: degrees / 10 - 127)
    }

    public static func decodeSEN(_ raw: UInt8) -> Int {
        if raw == senAutoCode { return 0 }
        let r = Int(raw)
        if r < 0x8A { return 1080 + 10 * (0x100 + r - 0xED) }
        if r >= 0xED { return 1080 + 10 * (r - 0xED) }
        return 90 + 10 * (r - 0x8A)
    }

    public static func encode(_ key: ParamKey, _ value: Int) throws -> UInt8 {
        if key == .SEN { return try encodeSEN(value) }
        if key == .BLI && value == 0 { return bliOffCode }
        if tensScaled.contains(key) { return UInt8(value / 10) }
        return UInt8(truncatingIfNeeded: value)
    }

    public static func decode(_ key: ParamKey, _ raw: UInt8) -> Int {
        if key == .SEN { return decodeSEN(raw) }
        if key == .BLI && raw >= bliOffCode { return 0 }
        if tensScaled.contains(key) { return Int(raw) * 10 }
        return Int(raw)
    }

    public static func selectSlot(_ slot: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: reportSize)
        buf[0] = reportIDDirectDrive; buf[1] = cmdTuning; buf[2] = 0x01; buf[3] = try slotCode(slot)
        return buf
    }

    /// Selects Auto Setup ("A_S" on the wheel).
    public static let selectAutoSetup: [UInt8] = [0xFF, 0x03, 0x01, 0x01] + [UInt8](repeating: 0, count: 60)

    /// Switches the wheel's Tuning Menu between Standard and Advanced.
    public static let toggleMenuMode: [UInt8] = [0xFF, 0x03, 0x06] + [UInt8](repeating: 0, count: 61)

    /// Asks the base to send its tuning report for the active setup.
    public static let requestTuning: [UInt8] = [0xFF, 0x03, 0x02] + [UInt8](repeating: 0, count: 61)

    /// Puts every setup on the base back to Fanatec's defaults.
    public static let resetAllSetups: [UInt8] = [0xFF, 0x03, 0x04] + [UInt8](repeating: 0, count: 61)
}

/// One-off commands on report 0x01. Sources and status: docs/PROTOCOL.md.
public enum WheelCommand {
    private static func frame(_ data: [UInt8]) -> [UInt8] {
        [0x01] + data + [UInt8](repeating: 0, count: 7 - data.count)
    }

    public static let centerCalibrate = frame([0xF9, 0x05])
    public static let shifterCalibrationStart = frame([0xF8, 0x09, 0x01, 0x19, 0x01])
    public static let shifterCalibrationNext = frame([0xF8, 0x09, 0x01, 0x19, 0x02])
    /// Order shown by the wheel on the CSL DD: neutral first, then reverse.
    public static let shifterPositions = ["N", "R", "1", "2", "3", "4", "5", "6", "7"]
}

/// The base's own tuning report (FF 03 …, 64 bytes): the active setup as the base
/// holds it. It arrives when asked (FF 03 02), when a setting changes on the wheel,
/// and after every write. Writes are built from it, so registers FanaMac doesn't
/// know about keep the base's values.
public struct TuningSnapshot: Equatable, Sendable {
    public let raw: [UInt8]

    public init?(report: [UInt8]) {
        guard report.count >= TuningProtocol.reportSize, report[0] == 0xFF, report[1] == 0x03 else { return nil }
        raw = Array(report.prefix(TuningProtocol.reportSize))
    }

    /// 1…5, or nil when the base reports no setup.
    public var slot: Int? {
        let s = Int(raw[2] & 0x0F) - 1
        return (1...5).contains(s) ? s : nil
    }

    /// The wheel's advanced Tuning Menu is on (bit 0x80 of the setup byte clear).
    public var advancedMode: Bool { raw[2] & 0x80 == 0 }

    /// The wheel is on Auto Setup ("A_S"): the game sets the values.
    public var isAutoSetup: Bool { raw[2] & 0x7F == 1 }

    public func value(_ key: ParamKey) -> Int {
        TuningProtocol.decode(key, raw[TuningProtocol.registers[key.rawValue]!])
    }

    /// The settings as FanaMac shows them (clamped to the app's ranges).
    public var setup: Setup {
        var s = Setup()
        for key in ParamKey.allCases {
            let r = param(key).range, v = value(key)
            s[key] = key == .SEN && v > 0 && v < 90 ? 90 : min(max(v, r.lowerBound), r.upperBound)
        }
        return s
    }

    /// Write frame: the base's snapshot with only the changed settings replaced.
    /// With a base's profile, a setting its Tuning Menu doesn't have is never
    /// written, and the steering angle stays within what the base accepts.
    public func writeFrame(for setup: Setup, profile: BaseProfile? = nil) throws -> [UInt8] {
        try setup.validate()
        if let profile, profile.has(.SEN), setup[.SEN] != value(.SEN), setup[.SEN] > profile.maxAngle {
            throw TuningError.outOfRange(.SEN, setup[.SEN])
        }
        var buf = [0xFF, 0x03, 0x00] + raw[2..<(TuningProtocol.reportSize - 1)]
        buf[3] &= 0x7F  // the Standard menu flag only exists in reports
        for key in ParamKey.allCases where setup[key] != value(key) && profile?.has(key) != false {
            let byte = try TuningProtocol.encode(key, setup[key])
            buf[TuningProtocol.registers[key.rawValue]! + 1] = byte
            if key == .BRF { buf[TuningProtocol.brakeForceAlt + 1] = byte }
        }
        return Array(buf)
    }
}

public func formatValue(_ key: ParamKey, _ v: Int) -> String {
    switch key {
    case .SEN where v == 0: return "Auto"
    case .FFS: return v == 0 ? "Linear" : "Peak"
    case .INT, .BLI, .FUL: if v == 0 { return "Off" }
    default: break
    }
    return "\(v)\(param(key).unit)"
}
