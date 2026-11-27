// App-side state: the CSL DD can't report its settings back, so FanaMac keeps
// the last known value of each setup.

import Foundation

public struct AppState: Codable, Equatable, Sendable {
    public var setups: [String: Setup]
    public var active: Int
    public var synced: [String: Bool]

    public init() {
        setups = Dictionary(uniqueKeysWithValues: (1...5).map { ("\($0)", Setup()) })
        active = 1
        synced = Dictionary(uniqueKeysWithValues: (1...5).map { ("\($0)", false) })
    }

    public func setup(_ slot: Int) -> Setup { setups["\(slot)"] ?? Setup() }
    public func isSynced(_ slot: Int) -> Bool { synced["\(slot)"] ?? false }
}

public final class Store: @unchecked Sendable {
    public let root: URL
    var stateFile: URL { root.appendingPathComponent("state.json") }

    public static var defaultRoot: URL {
        if let env = ProcessInfo.processInfo.environment["FANAMAC_HOME"] { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FanaMac")
    }

    public init(root: URL = Store.defaultRoot) { self.root = root }

    public func load() -> AppState {
        var state = AppState()
        guard let data = try? Data(contentsOf: stateFile),
              let saved = try? JSONDecoder().decode(PartialState.self, from: data) else { return state }
        for slot in 1...5 {
            let k = "\(slot)"
            if let s = saved.setups?[k], (try? s.validate()) != nil { state.setups[k] = s }
            if let v = saved.synced?[k] { state.synced[k] = v }
        }
        if let a = saved.active, (1...5).contains(a) { state.active = a }
        return state
    }

    public func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(state).write(to: stateFile, options: .atomic)
    }

    public static func exportSetup(_ setup: Setup, to url: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(setup).write(to: url, options: .atomic)
    }

    /// Every setting must be in the file: decoding alone would turn `{}` into the defaults.
    public static func importSetup(from url: URL) throws -> Setup {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxSetupSize else { throw StoreError.notASetup }
        let data = try Data(contentsOf: url)
        let raw = try JSONDecoder().decode([String: Int].self, from: data)
        guard allParams.allSatisfy({ raw[$0.key.rawValue] != nil }) else { throw StoreError.notASetup }
        let setup = try JSONDecoder().decode(Setup.self, from: data)
        try setup.validate()
        return setup
    }

    public enum StoreError: Error { case notASetup }
    static let maxSetupSize = 64 * 1024

    private struct PartialState: Decodable {
        var setups: [String: Setup]?
        var active: Int?
        var synced: [String: Bool]?
    }
}
