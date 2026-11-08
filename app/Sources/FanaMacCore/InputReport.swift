// Decodes the CSL DD's input report 0x01 (read only, nothing is sent).
//
// Layout from the base's 296-byte HID descriptor:
//   byte 0       report ID (0x01)
//   bytes 1-16   4-bit hat, then 124 button bits (108 used)
//   bytes 17-24  X, Z, Rz, Y as little-endian u16
//   bytes 25-26  Rx, Ry (s8)
//   byte 27      Slider (u8)
//   byte 28      Dial (s8)
//   bytes 29-33  5 vendor bytes; the 2nd one identifies the rim
//
// The base doesn't say which peripherals are plugged in: a pedal only shows up
// once its axis leaves the rest position.

import Foundation

enum Rims {
    /// Rim IDs (2nd vendor byte), from public community notes.
    static let names: [UInt8: String] = [
        0x0A: "ClubSport Steering Wheel Formula V2 / V2.5",
        0x0D: "Podium Button Module Endurance",
        0x0E: "CSL Elite Steering Wheel WRC",
        0x0F: "Podium Steering Wheel Bentley GT3",
        0x10: "Podium Steering Wheel BMW M4 GT3",
        0x11: "Podium Steering Wheel DD GT",
        0x12: "CSL Steering Wheel Universal Hub",
        0x13: "ClubSport Steering Wheel BMW V2",
        0x14: "ClubSport Steering Wheel RS",
        0x15: "ClubSport Universal Hub V2",
        0x16: "ClubSport Steering Wheel F1 Esports V2",
        0x17: "Podium Steering Wheel DD GT X",
        0x18: "CSL Elite Steering Wheel McLaren GT3 V2",
    ]
}

enum Axis: String, CaseIterable {
    case X, Z, Rz, Y, Rx, Ry, Slider, Dial
}

enum Pedal: String, CaseIterable {
    case throttle = "Throttle", brake = "Brake", clutch = "Clutch"

    /// Checked on a real CSL DD: throttle on Z, (load-cell) brake on Rz, clutch on Y.
    var axis: Axis {
        switch self {
        case .throttle: return .Z
        case .brake: return .Rz
        case .clutch: return .Y
        }
    }
}

struct InputReport: Equatable {
    var axes: [Axis: Int]
    var hat: Int?            // 0-7, nil when centred
    var buttons: [Int]       // 1-based
    var vendor: [UInt8]

    /// 1st vendor byte: 0x05 with the shifter in sequential mode, 0x04 in H mode
    /// (seen when switching the shifter, and after a restart in H mode).
    var shifterInHMode: Bool { vendor.first == 0x04 }

    /// H-pattern gear through the base, once the shifter is calibrated on the wheel:
    /// byte 3 = buttons 13 (R) and 14-20 (1st-7th). Checked on a real CSL DD + SQ V1.5.
    static let hGearButtons = 13...20
    var hGear: Gear { Gear(bitmap: gearByte) }
    private(set) var gearByte: UInt8 = 0

    var rimID: UInt8? { vendor.count > 1 && vendor[1] != 0 ? vendor[1] : nil }
    var rimName: String? { rimID.map { Rims.names[$0] ?? String(format: "Unknown rim (0x%02X)", $0) } }

    /// 0 at rest, 1 fully pressed. Pedals rest at 65535 and go down when pressed.
    func pedal(_ p: Pedal) -> Double {
        guard let raw = axes[p.axis] else { return 0 }
        return 1 - Double(raw) / 65535
    }

    /// Accepts the report with or without its leading ID byte.
    init?(bytes: [UInt8]) {
        var r = bytes
        if r.count == 33 { r.insert(0x01, at: 0) }
        guard r.count >= 34, r[0] == 0x01 else { return nil }
        func u16(_ i: Int) -> Int { Int(r[i]) | Int(r[i + 1]) << 8 }
        func s8(_ i: Int) -> Int { Int(Int8(bitPattern: r[i])) }
        axes = [.X: u16(17), .Z: u16(19), .Rz: u16(21), .Y: u16(23),
                .Rx: s8(25), .Ry: s8(26), .Slider: Int(r[27]), .Dial: s8(28)]
        var bits = [Bool]()
        for byte in r[1...16] { for b in 0..<8 { bits.append(byte >> b & 1 == 1) } }
        let h = bits[0..<4].enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) }
        hat = h <= 7 ? h : nil
        buttons = (0..<108).filter { bits[4 + $0] }.map { $0 + 1 }
        vendor = Array(r[29..<34])
        gearByte = r[3]
    }
}

/// Remembers which axes have left their first value, to tell what is plugged in.
struct PeripheralTracker {
    private(set) var first: InputReport?
    private(set) var moved: Set<Axis> = []
    private(set) var latest: InputReport?
    private var low: [Axis: Int] = [:]
    private var high: [Axis: Int] = [:]

    /// The handbrake sensor wobbles by up to ±2 steps at rest (seen 3C–40).
    static func noise(_ a: Axis) -> Int { a == handbrakeAxis ? 5 : 2 }

    /// Handbrake on the Slider axis (checked on a real CSL DD).
    static let handbrakeAxis = Axis.Slider
    var handbrakeSeen: Bool { moved.contains(Self.handbrakeAxis) }
    /// 0 at rest, 1 at the furthest pull seen so far (range learned on the fly).
    var handbrake: Double {
        let a = Self.handbrakeAxis
        guard let v = latest?.axes[a], let rest = first?.axes[a], let lo = low[a], let hi = high[a] else { return 0 }
        let span = max(hi - rest, rest - lo)
        if abs(v - rest) <= Self.noise(a) { return 0 }
        return span > 0 ? min(Double(abs(v - rest)) / Double(span), 1) : 0
    }

    mutating func feed(_ r: InputReport) {
        if first == nil { first = r }
        latest = r
        if r.buttons.contains(Self.shiftUp) || r.buttons.contains(Self.shiftDown) { shifterSeen = true }
        for (a, v) in r.axes { low[a] = min(low[a] ?? v, v); high[a] = max(high[a] ?? v, v) }
        for a in Axis.allCases where abs((r.axes[a] ?? 0) - (first?.axes[a] ?? 0)) > Self.noise(a) { moved.insert(a) }
    }

    func seen(_ p: Pedal) -> Bool { moved.contains(p.axis) }

    /// Axes that moved and aren't the wheel or a known pedal (handbrake, shifter…).
    var otherAxes: [Axis] {
        let known = Set([Axis.X, Self.handbrakeAxis] + Pedal.allCases.map(\.axis))
        return Axis.allCases.filter { moved.contains($0) && !known.contains($0) }
    }

    /// Sequential shifter on the base's Shifter 1 port: up = button 29, down = button 30
    /// (checked on a real CSL DD).
    static let shiftUp = 29, shiftDown = 30
    private(set) var shifterSeen = false
    var shiftingUp: Bool { latest?.buttons.contains(Self.shiftUp) ?? false }
    var shiftingDown: Bool { latest?.buttons.contains(Self.shiftDown) ?? false }

    mutating func reset() { self = PeripheralTracker() }
}

/// Report from the ClubSport USB adapter: 5 bytes, no report ID. Byte 0 holds
/// one bit per gear. Checked on a real SQ V1.5 in H mode, shifting 1 to 6 then R:
/// 0x02…0x40 = gears 1 to 6, 0x01 = reverse, 0 = neutral. 0x80 is assumed to be 7th.
struct USBShifterReport: Equatable {
    var gear: Gear

    init?(bytes: [UInt8]) {
        guard bytes.count == 5 else { return nil }
        gear = Gear(bitmap: bytes[0])
    }

    var label: String { gear.label }
}

/// One bit per gear: bit 0 = reverse, bits 1…7 = gears 1 to 7, none = neutral.
/// Same layout from the USB adapter (byte 0) and from the base (byte 3 of report 0x01).
struct Gear: Equatable {
    /// nil = neutral, 0 = reverse, 1…7 = gear.
    var value: Int?

    init(bitmap b: UInt8) {
        if b & 0x01 != 0 { value = 0 }
        else { value = (1...7).first { b & (1 << $0) != 0 } }
    }

    var label: String {
        switch value {
        case nil: return "N"
        case 0?: return "R"
        case let g?: return "\(g)"
        }
    }
}
