// Force feedback output of the CSL DD (output report 0x01, 7 data bytes).
//
// Constant force in slot 0 with effect code 0x08, 16-bit level centred on
// 0x8000, spring in slot 1 with code 0x0B, damper in slot 2 with code 0x0C,
// slot off with bit 0x02, stop-all 0xF3.
// Measured on a real CSL DD: a raw level below 0x8000 turns the wheel
// clockwise; the spring and damper frames below were felt on the wheel.

import Foundation

public enum ForceProtocol {
    public static let reportID: UInt8 = 0x01
    static let constantSlot: UInt8 = 0
    static let constantCmd: UInt8 = 0x08
    static let slotOn: UInt8 = 0x01
    static let slotOff: UInt8 = 0x02
    static let highRes: UInt8 = 0x01
    static let zero = 0x8000
    static let full = 0x7FFF

    /// Constant force. `level` runs from −1 (full anti-clockwise) to +1 (full
    /// clockwise); 0 turns the slot off. Values outside are refused, not clipped.
    /// `highRes: false` is the 8-bit frame of the bases without the 16-bit
    /// format (`01 08 xx`, centred on 0x80): from hid-fanatecff, never sent by FanaMac
    /// to a real base.
    public static func constant(_ level: Double, highRes: Bool = true) throws -> [UInt8] {
        guard level.isFinite, (-1...1).contains(level) else { throw ForceError.outOfRange(level) }
        let raw = zero - Int((level * Double(full)).rounded())
        if !highRes {
            // Rounded to the nearest of the 255 steps, so both directions are as strong.
            let coarse = 0x80 - Int((level * 0x7F).rounded())
            if coarse == 0x80 { return constantOff }
            return frame([(constantSlot << 4) | slotOn, constantCmd, UInt8(coarse)])
        }
        if raw == zero { return constantOff }
        return frame([(constantSlot << 4) | slotOn, constantCmd, UInt8(raw & 0xFF), UInt8(raw >> 8), 0, 0, Self.highRes])
    }

    public static let constantOff = frame([(constantSlot << 4) | slotOn | slotOff, constantCmd])
    public static let stopAll = frame([0xF3])

    static let springSlot: UInt8 = 1
    static let springCmd: UInt8 = 0x0B
    static let damperSlot: UInt8 = 2
    static let damperCmd: UInt8 = 0x0C

    /// Spring played by the base: centre and deadband edges, a stiffness for
    /// each side (0 … 15), one top force (0 … 255). nil when the slot is off.
    public static func spring(_ c: ConditionSlot) throws -> [UInt8]? {
        try c.check()
        let sat = saturation(c.saturation)
        guard sat > 0 else { return nil }
        let k = coeff4(c.posCoeff) << 4 | coeff4(c.negCoeff)
        return frame([(springSlot << 4) | slotOn, springCmd,
                      edge(c.offset - c.deadband), edge(c.offset + c.deadband), k, 0, sat])
    }

    public static let springOff = frame([(springSlot << 4) | slotOn | slotOff, springCmd])

    /// Damper played by the base: a coefficient for each side (0 … 15) and one
    /// top force. The base's damper has no centre or deadband. nil when off.
    public static func damper(_ c: ConditionSlot) throws -> [UInt8]? {
        try c.check()
        let sat = saturation(c.saturation)
        guard sat > 0 else { return nil }
        return frame([(damperSlot << 4) | slotOn, damperCmd, coeff4(c.negCoeff), 0, coeff4(c.posCoeff), 0, sat])
    }

    public static let damperOff = frame([(damperSlot << 4) | slotOn | slotOff, damperCmd, 0, 0, 0, 0, 0xFF])

    /// −1 … +1 → 0 … 15, to the nearest step (6.25 % each), so a weak spring
    /// still gets step 1 instead of 0. The base only knows how strong, not
    /// which sign.
    static func coeff4(_ c: Double) -> UInt8 {
        UInt8(min((abs(c) * 15).rounded(), 15))
    }

    /// 0 … 1 → 0 … 255.
    static func saturation(_ s: Double) -> UInt8 {
        UInt8(Int((s * 0xFFFF).rounded()) >> 8)
    }

    /// Wheel position −1 … +1 → 0 … 255, 0x80 = centre.
    static func edge(_ p: Double) -> UInt8 {
        let pos = Int((max(-1, min(1, p)) * Double(full)).rounded())
        return UInt8((pos + zero) >> 8)
    }

    static func frame(_ data: [UInt8]) -> [UInt8] {
        [reportID] + data + [UInt8](repeating: 0, count: 7 - data.count)
    }
}

public enum ForceError: Error, Equatable {
    case outOfRange(Double)
}

/// What a spring or damper slot of the base is asked to play. Offset and
/// deadband in wheel travel (−1 … +1 is all of it; the deadband is each side of
/// the offset), coefficients −1 … +1 (positive side = clockwise), saturation
/// 0 … 1 (0 = off).
public struct ConditionSlot: Equatable, Sendable {
    public var offset = 0.0, deadband = 0.0, posCoeff = 0.0, negCoeff = 0.0, saturation = 0.0
    public static let off = ConditionSlot()

    public init(offset: Double = 0, deadband: Double = 0, posCoeff: Double = 0, negCoeff: Double = 0, saturation: Double = 0) {
        self.offset = offset; self.deadband = deadband
        self.posCoeff = posCoeff; self.negCoeff = negCoeff; self.saturation = saturation
    }

    /// Values outside their range are refused, not clipped.
    func check() throws {
        for (v, r) in [(offset, -1.0...1), (deadband, 0...1), (posCoeff, -1...1), (negCoeff, -1...1), (saturation, 0...1)] {
            guard v.isFinite, r.contains(v) else { throw ForceError.outOfRange(v) }
        }
    }
}

/// Everything a game asks of the base at one moment.
public struct ForceCommand: Equatable, Sendable {
    /// Constant force, −1 … +1, positive turns clockwise.
    public var level: Double
    public var spring: ConditionSlot
    public var damper: ConditionSlot
    public static let none = ForceCommand(level: 0)

    public init(level: Double, spring: ConditionSlot = .off, damper: ConditionSlot = .off) {
        self.level = level; self.spring = spring; self.damper = damper
    }

    func check() throws {
        _ = try ForceProtocol.constant(level)
        try spring.check()
        try damper.check()
    }
}

/// Decides what goes to the base, tick by tick. No hardware, no clock of its own:
/// the caller passes the time, so the safety rules can be tested.
///
/// The constant force is resent on every tick while it is on; the spring and
/// damper are sent only when they change, since the base plays them itself.
/// Safety stop: everything drops to zero when no command arrived for `timeout`,
/// and `stop()` cuts everything at once.
/// The strength is only limited by `cap`, which is 1 (no limit) for a tested base.
public struct ForceEngine: Sendable {
    public var timeout: TimeInterval
    /// From the base's profile: 16-bit constant force, and the share of the
    /// full force it may be asked for (constant level and the effects' top force).
    public var highRes = true
    public var cap = 1.0
    public private(set) var command = ForceCommand.none
    private var lastCommand: Date?
    // What the base plays now (nil = slot off).
    private var sentConstant: [UInt8]?
    private var sentSpring: [UInt8]?
    private var sentDamper: [UInt8]?

    public init(timeout: TimeInterval = 0.25) { self.timeout = timeout }

    public var level: Double { command.level }

    /// What the base is told to play at `now` (nothing once the commands stop coming).
    public func effective(at now: Date) -> ForceCommand {
        guard let last = lastCommand, now.timeIntervalSince(last) <= timeout else { return .none }
        return command
    }

    /// New command. Returns the frames to send right away (none if nothing changes).
    public mutating func set(_ command: ForceCommand, at now: Date) throws -> [[UInt8]] {
        try command.check()  // refuses a bad command before anything changes
        self.command = command
        lastCommand = now
        return output(at: now, keepAlive: false)
    }

    public mutating func set(_ level: Double, at now: Date) throws -> [[UInt8]] {
        try set(ForceCommand(level: level), at: now)
    }

    /// Called every keep-alive period: resends the constant force while it is on,
    /// and switches off what was on once the commands stop.
    public mutating func tick(at now: Date) -> [[UInt8]] {
        output(at: now, keepAlive: true)
    }

    /// Quit, disconnect, write error: everything off now, whatever was asked before.
    public mutating func stop() -> [[UInt8]] {
        command = .none
        lastCommand = nil
        sentConstant = nil; sentSpring = nil; sentDamper = nil
        return [ForceProtocol.constantOff, ForceProtocol.springOff, ForceProtocol.damperOff, ForceProtocol.stopAll]
    }

    public var isActive: Bool { sentConstant != nil || sentSpring != nil || sentDamper != nil }

    private mutating func output(at now: Date, keepAlive: Bool) -> [[UInt8]] {
        var c = effective(at: now)
        let limit = max(0, min(1, cap))
        c.level *= limit; c.spring.saturation *= limit; c.damper.saturation *= limit
        var out: [[UInt8]] = []
        let constant = (try? ForceProtocol.constant(c.level, highRes: highRes)).flatMap { $0 == ForceProtocol.constantOff ? nil : $0 }
        if let constant {
            if constant != sentConstant || keepAlive { out.append(constant) }
        } else if sentConstant != nil {
            out.append(ForceProtocol.constantOff)
        }
        sentConstant = constant
        let spring = (try? ForceProtocol.spring(c.spring)) ?? nil
        if spring != sentSpring { out.append(spring ?? ForceProtocol.springOff) }
        sentSpring = spring
        let damper = (try? ForceProtocol.damper(c.damper)) ?? nil
        if damper != sentDamper { out.append(damper ?? ForceProtocol.damperOff) }
        sentDamper = damper
        return out
    }
}

/// Packet from FanaMac's force feedback plug-in (FanaMacFF.plugin).
/// Format in ffplugin/src/packet.h: "FMFF", version, flags, reserved, u32 seq,
/// f32 level, then the spring and damper slots, five f32 each.
public struct ForcePacket: Equatable, Sendable {
    public static let port: UInt16 = 9310
    public let sequence: UInt32
    /// What the game asks for; nothing when it let go of the wheel.
    public let command: ForceCommand
    /// false: the game let go of the wheel.
    public let active: Bool

    /// −1 … +1, positive turns the wheel clockwise.
    public var level: Double { command.level }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 56, Array(bytes[0..<4]) == Array("FMFF".utf8), bytes[4] == 1 else { return nil }
        func u32(_ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[i + $1]) << (8 * $1) } }
        func f32(_ i: Int) -> Double { Double(Float(bitPattern: u32(i))) }
        func slot(_ i: Int) -> ConditionSlot {
            ConditionSlot(offset: f32(i), deadband: f32(i + 4), posCoeff: f32(i + 8), negCoeff: f32(i + 12), saturation: f32(i + 16))
        }
        let command = ForceCommand(level: f32(12), spring: slot(16), damper: slot(36))
        guard (try? command.check()) != nil else { return nil }
        sequence = u32(8)
        self.command = command
        active = bytes[5] & 0x01 != 0
    }
}
