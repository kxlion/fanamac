import Foundation

/// Fanatec's recommended settings per game and base, as built into the Fanatec App
/// (see docs/PRESETS.md). Read from Presets/fanatec_recommended.json.
public struct PresetLibrary: Decodable, Sendable {
    public let source: String
    public let games: [GamePreset]

    public static func load(_ url: URL) throws -> PresetLibrary {
        try JSONDecoder().decode(PresetLibrary.self, from: Data(contentsOf: url))
    }

    /// Games with settings for this base type (Fanatec App name, e.g. "CSLDD").
    public func games(for base: String) -> [GamePreset] {
        games.filter { $0.bases[base]?.variants.isEmpty == false }
    }
}

public struct GamePreset: Decodable, Sendable, Identifiable {
    public let game: String
    public let bases: [String: BasePreset]
    public var id: String { game }

    /// The section for this base. A text may hold a second one for other bases
    /// (e.g. "Belt-driven wheel bases"): the first is the base's own.
    public func variant(for base: String) -> PresetVariant? { bases[base]?.variants.first }
}

public struct BasePreset: Decodable, Sendable {
    public let name: String
    public let variants: [PresetVariant]
}

public struct PresetVariant: Decodable, Sendable {
    public let label: String
    /// Tuning Menu values, in FanaMac's units (SEN 0 = Auto, FFS 1 = Peak).
    public let tuning: [String: Int]
    /// Settings Fanatec leaves to the driver: kept as they are.
    public let userPreference: [String]
    /// Lines for settings this base's menu has but FanaMac doesn't (ABS, DRI...).
    public let otherSettings: [String]
    public let inGameTitle: String
    public let inGame: [String]
    public let notes: [String]

    /// The setup with this preset's values; everything it doesn't list stays.
    public func applied(to setup: Setup) -> Setup {
        var s = setup
        for (k, v) in tuning { if let key = ParamKey(rawValue: k) { s[key] = v } }
        return s
    }
}
