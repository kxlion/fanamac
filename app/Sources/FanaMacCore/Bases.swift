// What FanaMac knows about each Fanatec wheelbase, as data: adding a base is
// adding a profile, not changing code.
//
// Only the CSL DD was tested on real hardware. The other profiles come from the
// Linux driver hid-fanatecff (device IDs, 16-bit force, Tuning Menu over USB,
// maximum angle) and stay `untested` until someone who owns the base confirms
// them with a diagnostic (see docs/BASES.md).

import Foundation

public struct BaseProfile: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Checked on the real base: everything is on.
        case tested
        /// Never run on the real base: read-only until the driver turns the
        /// experimental mode on, and the force stays capped.
        case untested
    }

    public var productID: Int
    public var name: String
    /// The base's name in Fanatec's recommended settings ("CSLDD"), if it has any.
    public var presetBase: String?
    public var status: Status
    /// Constant force on 16 bits (`01 08 lo hi 00 00 01`) instead of 8 (`01 08 xx`).
    public var highResForce: Bool
    /// The base has the `FF 03` Tuning Menu over USB.
    public var tuningMenu: Bool
    /// Largest steering angle the base accepts, in degrees.
    public var maxAngle: Int
    /// Settings the base's Tuning Menu has. nil: all the ones FanaMac knows.
    public var params: [ParamKey]?

    public init(productID: Int, name: String, presetBase: String? = nil, status: Status = .untested,
                highResForce: Bool, tuningMenu: Bool, maxAngle: Int, params: [ParamKey]? = nil) {
        self.productID = productID; self.name = name; self.presetBase = presetBase; self.status = status
        self.highResForce = highResForce; self.tuningMenu = tuningMenu; self.maxAngle = maxAngle; self.params = params
    }

    public var isTested: Bool { status == .tested }
    public func has(_ key: ParamKey) -> Bool { params?.contains(key) ?? true }
    public var productHex: String { String(format: "%04X", productID) }

    /// Share of the full force an untested base may be asked for.
    public static let untestedForceCap = 0.25
    public var forceCap: Double { isTested ? 1 : Self.untestedForceCap }

    // In files the product ID is written the way USB tools show it: "0020".
    private enum CodingKeys: String, CodingKey {
        case productID, name, presetBase, status, highResForce, tuningMenu, maxAngle, params
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try c.decode(String.self, forKey: .productID)
        guard hex.count <= 4, let id = Int(hex, radix: 16) else {
            throw DecodingError.dataCorruptedError(forKey: .productID, in: c, debugDescription: "product ID is 1 to 4 hex digits")
        }
        productID = id
        name = try c.decode(String.self, forKey: .name)
        presetBase = try c.decodeIfPresent(String.self, forKey: .presetBase)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .untested
        highResForce = try c.decode(Bool.self, forKey: .highResForce)
        tuningMenu = try c.decode(Bool.self, forKey: .tuningMenu)
        maxAngle = try c.decode(Int.self, forKey: .maxAngle)
        guard (90...2520).contains(maxAngle) else {
            throw DecodingError.dataCorruptedError(forKey: .maxAngle, in: c, debugDescription: "maxAngle is 90 to 2520")
        }
        params = try c.decodeIfPresent([ParamKey].self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(productHex, forKey: .productID)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(presetBase, forKey: .presetBase)
        try c.encode(status, forKey: .status)
        try c.encode(highResForce, forKey: .highResForce)
        try c.encode(tuningMenu, forKey: .tuningMenu)
        try c.encode(maxAngle, forKey: .maxAngle)
        try c.encodeIfPresent(params, forKey: .params)
    }
}

/// What a Fanatec USB device is to FanaMac.
public enum FanatecDevice: Equatable, Sendable {
    case base(BaseProfile)
    /// Pedals, shifter adapter: never written to.
    case accessory(String)
    /// A base in PlayStation mode: it has to be switched to PC mode.
    case consoleMode(String)
    /// A Fanatec product FanaMac has no profile for.
    case unknown
}

public struct BaseCatalog: Sendable {
    public private(set) var profiles: [BaseProfile]

    /// Built-in profiles. IDs, `highResForce`, `tuningMenu` and `maxAngle` of the
    /// untested ones are those of hid-fanatecff.
    public static let builtIn: [BaseProfile] = [
        // The 8 Nm CSL DD too; the GT DD Pro in PC mode is reported to share this ID.
        BaseProfile(productID: 0x0020, name: "CSL DD", presetBase: "CSLDD", status: .tested,
                    highResForce: true, tuningMenu: true, maxAngle: 2520),
        BaseProfile(productID: 0x0006, name: "Podium DD1", presetBase: "PDD1",
                    highResForce: true, tuningMenu: true, maxAngle: 2520),
        BaseProfile(productID: 0x0007, name: "Podium DD2", presetBase: "PDD2",
                    highResForce: true, tuningMenu: true, maxAngle: 2520),
        BaseProfile(productID: 0x0E03, name: "CSL Elite", presetBase: "CSLE_1_1",
                    highResForce: true, tuningMenu: true, maxAngle: 1080),
        BaseProfile(productID: 0x0005, name: "CSL Elite PS4", presetBase: "CSLEPS4",
                    highResForce: true, tuningMenu: true, maxAngle: 1080),
        // Also what a CSL DD shows in compatibility mode (yellow LED).
        BaseProfile(productID: 0x0004, name: "ClubSport V2.5", presetBase: "CSWV25",
                    highResForce: false, tuningMenu: false, maxAngle: 900),
        BaseProfile(productID: 0x0001, name: "ClubSport V2", presetBase: "CSWV2",
                    highResForce: false, tuningMenu: false, maxAngle: 900),
        // Known from Fanatec's Windows driver only: the cautious 8-bit frame.
        BaseProfile(productID: 0x038E, name: "ClubSport V1",
                    highResForce: false, tuningMenu: false, maxAngle: 900),
        BaseProfile(productID: 0x0011, name: "CSR Elite",
                    highResForce: false, tuningMenu: false, maxAngle: 900),
        BaseProfile(productID: 0x0197, name: "Porsche 911",
                    highResForce: false, tuningMenu: false, maxAngle: 900),
    ]

    /// Names are those of Fanatec's Windows driver.
    public static let accessories: [Int: String] = [
        0x1A92: "ClubSport Shifter USB adapter",
        0x1A93: "ClubSport Handbrake USB adapter",
        0x1A95: "ClubSport Pedals USB adapter",
        0x1839: "ClubSport Pedals",
        0x183B: "ClubSport Pedals V3",
        0x6204: "CSL Elite Pedals",
        0x6205: "CSL Pedals LC",
        0x6206: "CSL Elite Pedals V2",
        0x6207: "Fanatec pedals",
    ]

    /// What a base shows in PlayStation mode, per Fanatec's Windows SDK. FanaMac
    /// only talks to a base in PC mode. The names are deduced, not confirmed.
    public static let consoleModes: [Int: String] = [
        0x0E04: "CSL Elite PS4",
        0x0E05: "Podium DD",
        0x0E06: "Podium DD",
        0x0E07: "GT DD Pro",
        0x0E08: "Fanatec base",
        0x0E09: "Fanatec base",
    ]

    /// `extra` profiles are added to the built-in ones. They can't replace a
    /// tested profile, and they can't declare themselves tested.
    public init(extra: [BaseProfile] = []) {
        profiles = Self.builtIn
        for var p in extra {
            p.status = .untested
            if let i = profiles.firstIndex(where: { $0.productID == p.productID }) {
                if !profiles[i].isTested { profiles[i] = p }
            } else if Self.accessories[p.productID] == nil, Self.consoleModes[p.productID] == nil {
                profiles.append(p)
            }
        }
    }

    public func profile(productID: Int) -> BaseProfile? { profiles.first { $0.productID == productID } }

    public func classify(productID: Int) -> FanatecDevice {
        if let p = profile(productID: productID) { return .base(p) }
        if let a = Self.accessories[productID] { return .accessory(a) }
        if let c = Self.consoleModes[productID] { return .consoleMode(c) }
        return .unknown
    }

    /// Folder where a profile file can be dropped to try a base without a new build.
    public static var userFolder: URL { Store.defaultRoot.appendingPathComponent("Bases") }

    /// Built-in profiles plus every readable `*.json` profile of `folder`.
    public static func load(folder: URL = BaseCatalog.userFolder) -> BaseCatalog {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let extra = files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url -> BaseProfile? in
            guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024 else { return nil }
            return try? JSONDecoder().decode(BaseProfile.self, from: data)
        }
        return BaseCatalog(extra: extra)
    }
}
