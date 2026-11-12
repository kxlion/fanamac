import AppKit
import Foundation
import SwiftUI

/// The base profiles in use, and which untested bases the driver opened up.
enum Bases {
    static let catalog = BaseCatalog.load()

    private static func key(_ productID: Int) -> String { String(format: "experimental.%04X", productID) }
    static func isExperimental(_ productID: Int) -> Bool { UserDefaults.standard.bool(forKey: key(productID)) }
    static func setExperimental(_ on: Bool, _ productID: Int) { UserDefaults.standard.set(on, forKey: key(productID)) }

    /// Writes and force feedback: a tested base, or an untested one in experimental mode.
    static func fullAccess(_ productID: Int) -> Bool {
        catalog.profile(productID: productID).map { $0.isTested || isExperimental(productID) } ?? false
    }
}

@MainActor
final class TuningModel: ObservableObject {

    @Published private(set) var state: AppState
    @Published var slot: Int
    @Published private(set) var base: WheelbaseInfo?
    @Published private(set) var sending = false
    /// Bottom bar text. Errors stay until the next message; notes fade after 4 s.
    @Published var message: String? { didSet { messageIsNote = false } }
    @Published private(set) var messageIsNote = false

    private func note(_ text: String) {
        message = text
        messageIsNote = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.message == text { self?.message = nil }
        }
    }

    /// Live pedal/button state, kept apart so only the devices view redraws.
    let live = LiveInput()
    let mouse = MouseEmulation()

    func setMouseEmulation(_ on: Bool) {
        let help = "Allow FanaMac in System Settings > Privacy & Security > Accessibility, then turn Mouse Emulation on again."
        if !mouse.set(on) {
            message = help
        } else if message == help {
            message = nil
        }
    }

    /// Last tuning report from the base, and each setup as last read from it.
    @Published private var snapshot: TuningSnapshot?
    private var snapshotCount = 0
    /// A switch of the Tuning Menu is waiting for the driver's OK.
    @Published var askingMenuSwitch = false
    private var presetAfterMenuSwitch: GamePreset?
    /// The wheel stays on Auto Setup while a Custom Setup is looked at here.
    @Published private var viewingCustomSetup = false
    var snapshotKnown: Bool { snapshot != nil }
    /// The wheel's Tuning Menu is the Standard one: Auto Setup, one Custom Setup.
    var standardMenu: Bool { snapshot?.advancedMode == false }
    var wheelOnAuto: Bool { snapshot?.isAutoSetup == true }
    /// Auto Setup is what's shown: only the game changes its values.
    var showsAutoSetup: Bool { wheelOnAuto && !viewingCustomSetup }

    func show(setup n: Int) {
        slot = n
        viewingCustomSetup = wheelOnAuto
    }
    @Published private(set) var baseSetups: [Int: Setup] = [:]
    /// Setup active on the wheel, from the base's last tuning report.
    @Published private(set) var wheelSlot: Int?

    private let store = Store()
    private let wheelbase = Wheelbase(productIDs: Bases.catalog.profiles.map(\.productID), marks: { Bases.fullAccess($0) })

    /// What FanaMac knows about the connected base.
    var profile: BaseProfile? { base.flatMap { Bases.catalog.profile(productID: $0.productID) } }
    /// The driver turned the experimental mode on for this untested base.
    @Published private(set) var experimental = false
    @Published var askingExperimental = false
    /// Settings can be written and games get force feedback.
    var fullAccess: Bool { profile.map { $0.isTested || experimental } ?? false }
    var hasTuningMenu: Bool { profile?.tuningMenu ?? false }
    func has(_ key: ParamKey) -> Bool { profile?.has(key) ?? true }
    var maxAngle: Int { profile?.maxAngle ?? 2520 }

    /// An untested base stays read-only until this is turned on: then it takes
    /// writes, and forces capped at `BaseProfile.untestedForceCap`.
    func setExperimental(_ on: Bool) {
        guard let p = profile, !p.isTested else { return }
        Bases.setExperimental(on, p.productID)
        experimental = on
        configureForce()
        wheelbase.refreshMarks()
        if on { checkWine(); Task { await readBase() } }
        message = on ? nil : Self.readOnlyText(p)
    }

    private static func readOnlyText(_ p: BaseProfile) -> String {
        "The \(p.name) is untested: read-only. Wheelbase menu > Experimental Mode to write to it."
    }

    /// No force at all goes to a base without full access.
    private func configureForce() {
        guard let p = profile else { return }
        force.configure(highRes: p.highResForce, cap: fullAccess ? p.forceCap : 0)
    }

    private func writable() -> Bool {
        if fullAccess { return true }
        message = profile.map(Self.readOnlyText) ?? "No wheelbase."
        return false
    }

    /// A diagnostic is being recorded.
    @Published private(set) var capturing = false
    static let captureSeconds = 10.0

    /// Records every Fanatec device for a few seconds into a file to send.
    func saveDiagnostic(to url: URL) {
        guard !capturing else { return }
        capturing = true
        message = "Recording for \(Int(Self.captureSeconds)) s: turn the wheel lock to lock, press each pedal fully, press a few buttons."
        DiagnosticCapture.run(seconds: Self.captureSeconds, catalog: Bases.catalog, version: FanaMacVersion.current) { [weak self] d in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.capturing = false
                if d.devices.isEmpty {
                    self.message = "No Fanatec device found. Is the base on, in PC mode (red LED)?"
                    return
                }
                do {
                    try d.write(to: url)
                    self.note("Diagnostic saved. Attach it to an issue on FanaMac's GitHub page.")
                } catch { self.message = "Could not save the diagnostic." }
            }
        }
    }
    private let usbShifter = USBShifter()
    private lazy var force = ForceOutput(wheelbase: wheelbase)
    /// The base is producing a force right now.
    @Published private(set) var forceActive = false
    private let listener = ForceListener()
    /// A game is sending forces through the plug-in right now.
    @Published private(set) var gameConnected = false
    private var lastPacket = Date.distantPast
    /// A bottle was already running when the base connected: it has neither the
    /// force feedback nor the axis filter until it is restarted.
    @Published private(set) var wineTooEarly = false
    private var wineWatch: Task<Void, Never>?

    init() {
        let loaded = store.load()
        state = loaded
        slot = 1  // always open on setup 1
        mouse.input = { [weak self] in self?.live.tracker.latest }
        wheelbase.onChange = { [weak self] info in
            guard let self else { return }
            let wasConnected = self.base != nil
            self.base = info
            if info == nil {
                self.live.forget(); self.baseSetups = [:]; self.snapshot = nil; self.wheelSlot = nil
                self.force.baseGone()
                self.wineWatch?.cancel()
                self.wineTooEarly = false
            }
            else if !wasConnected {
                self.experimental = info.map { Bases.isExperimental($0.productID) } ?? false
                self.configureForce()
                if self.fullAccess { self.checkWine() }
                Task {
                    await self.readBase()
                    if !self.fullAccess, self.message == nil, let p = self.profile { self.message = Self.readOnlyText(p) }
                }
            }
        }
        let live = live
        wheelbase.onInput = { [weak self] bytes in
            Recorder.shared.input(bytes)
            MainActor.assumeIsolated {
                if let snap = TuningSnapshot(report: bytes) { self?.received(snap) } else { live.feed(bytes) }
            }
        }
        usbShifter.onPresence = { present in
            MainActor.assumeIsolated { live.setUSBShifter(present) }
        }
        usbShifter.onInput = { bytes in
            MainActor.assumeIsolated { live.feedUSBShifter(bytes) }
        }
        force.onActive = { [weak self] on in MainActor.assumeIsolated { self?.forceActive = on } }
        force.onError = { [weak self] error in
            MainActor.assumeIsolated {
                self?.message = "Force cut: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        let force = force
        listener.onPacket = { [weak self] p in
            Recorder.shared.packet(p)
            force.set(p.active ? p.command : .none)
            DispatchQueue.main.async { self?.packetArrived() }
        }
        if !listener.start() { message = "Port \(ForcePacket.port) is taken: games can't send forces to FanaMac." }
        let wheelbase = wheelbase
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            force.stopNow()
            wheelbase.unmarkAll()
        }
    }

    /// Warns until every bottle that was already running has stopped.
    private func checkWine() {
        let early = WineProcess.servers()
        wineWatch?.cancel()
        wineTooEarly = !early.isEmpty
        guard !early.isEmpty else { return }
        wineWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled, !early.isDisjoint(with: WineProcess.servers()) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if !Task.isCancelled { self?.wineTooEarly = false }
        }
    }

    private func packetArrived() {
        lastPacket = Date()
        guard !gameConnected else { return }
        gameConnected = true
        Task { @MainActor [weak self] in
            while let self, Date().timeIntervalSince(self.lastPacket) < 1 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.gameConnected = false
        }
    }

    var setup: Setup { showsAutoSetup ? snapshot?.setup ?? state.setup(slot) : state.setup(slot) }
    var isSynced: Bool { state.isSynced(slot) }
    var canSend: Bool { base != nil && !sending && !showsAutoSetup && fullAccess && hasTuningMenu }

    func binding(_ key: ParamKey) -> Binding<Int> {
        Binding(get: { self.setup[key] }, set: { self.update(key, $0) })
    }

    func update(_ key: ParamKey, _ value: Int) {
        var s = setup
        guard s[key] != value else { return }
        s[key] = value
        persist(s, synced: s == baseSetups[slot])
    }

    /// What the base holds for this setting, if this setup was read from the base.
    func baseValue(_ key: ParamKey) -> Int? { showsAutoSetup ? nil : baseSetups[slot]?[key] }
    func isChanged(_ key: ParamKey) -> Bool { baseValue(key).map { $0 != setup[key] } ?? false }
    var changedCount: Int { ParamKey.allCases.filter(isChanged).count }
    var isRead: Bool { baseSetups[slot] != nil }
    func isRead(_ n: Int) -> Bool { baseSetups[n] != nil }
    /// Setup n differs from what the base holds for it.
    func hasChanges(_ n: Int) -> Bool { baseSetups[n].map { $0 != state.setup(n) } ?? false }

    /// Puts one setting back to the base's value.
    func revert(_ key: ParamKey) {
        if let b = baseValue(key) { update(key, b) }
    }

    /// Undoes unsent edits: back to what the base holds for this setup.
    var canRevert: Bool { !isSynced && baseSetups[slot] != nil && !showsAutoSetup }
    func revertToWheelbase() {
        guard let b = baseSetups[slot] else { return }
        persist(b, synced: true)
    }

    /// Fanatec's recommended settings, bundled with the app.
    static let presets: PresetLibrary? = Bundle.main.url(forResource: "fanatec_recommended", withExtension: "json")
        .flatMap { try? PresetLibrary.load($0) }
    /// The connected base in the Fanatec App's names ("CSLDD").
    var presetBase: String { profile?.presetBase ?? "" }
    var gamePresets: [GamePreset] { Self.presets?.games(for: presetBase) ?? [] }
    /// Game whose in-game settings are on screen.
    @Published var shownPreset: GamePreset?

    /// Puts the game's Tuning Menu values in this setup (not sent yet) and shows
    /// its in-game settings. Settings the preset doesn't list keep their value.
    /// Every preset has Advanced settings, so the Standard menu is left first.
    func load(_ preset: GamePreset) {
        if standardMenu {
            presetAfterMenuSwitch = preset
            askingMenuSwitch = true
        } else {
            apply(preset)
        }
    }

    private func apply(_ preset: GamePreset) {
        guard let v = preset.variant(for: presetBase) else { return }
        show(setup: slot)
        let s = v.applied(to: setup)
        persist(s, synced: s == baseSetups[slot])
        shownPreset = preset
    }

    func importSetup(from url: URL) {
        do {
            let imported = try Store.importSetup(from: url)
            show(setup: slot)
            persist(imported, synced: imported == baseSetups[slot])
            note("Imported into setup \(slot). Send it to apply.")
        } catch { message = "That file isn't a valid FanaMac setup." }
    }

    func exportSetup(to url: URL) {
        do {
            try Store.exportSetup(setup, to: url)
            note("Exported setup \(slot).")
        } catch { message = "Could not export the setup." }
    }

    /// Sends the base's reset, then reads every setup back. Unsent edits go too:
    /// the setups are forgotten first, so the base's values replace them.
    func resetAllSetups() async {
        guard writable() else { return }
        do {
            try await wheelbase.write([TuningProtocol.resetAllSetups])
            baseSetups = [:]
            await readBase()
            if message == nil { note("All setups are back to Fanatec's defaults.") }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Takes the wheel's current position as its centre.
    func calibrateCenter() async {
        guard writable() else { return }
        do {
            try await wheelbase.write([WheelCommand.centerCalibrate])
            note("Steering center set.")
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Open while the shifter calibration runs.
    @Published var calibratingShifter = false

    /// No frame cancels a calibration: the base stays in it until it restarts.
    func cancelShifterCalibration() {
        calibratingShifter = false
        message = "Calibration stopped. If the shifter doesn't respond, turn the base off and on."
    }

    /// One calibration frame. On a failure the calibration window closes.
    func sendShifterCalibration(_ frame: [UInt8]) async -> Bool {
        guard writable() else { calibratingShifter = false; return false }
        do {
            try await wheelbase.write([frame])
            return true
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            calibratingShifter = false
            return false
        }
    }

    /// The base sends its tuning report on request, after each write and when
    /// a setting is changed on the wheel. It is the truth: it replaces what we stored.
    private func received(_ snap: TuningSnapshot) {
        let leftAuto = wheelOnAuto && !snap.isAutoSetup
        snapshot = snap
        snapshotCount += 1
        if !snap.isAutoSetup { viewingCustomSetup = false }
        if !snap.advancedMode, slot != 1 { slot = 1 }  // the Standard menu's Custom Setup
        guard let s = snap.slot else { wheelSlot = nil; return }
        let previous = wheelSlot
        if wheelSlot != s { wheelSlot = s }
        // Follow a setup change made on the wheel, unless edits here aren't sent yet.
        if leftAuto || (previous != nil && previous != s), !sending, isSynced { slot = s }
        let fresh = snap.setup
        let previousRead = baseSetups[s]
        guard previousRead != fresh || state.active != s else { return }
        state.active = s
        baseSetups[s] = fresh
        // Edits not sent yet are kept; only settings changed on the wheel since the
        // last read replace them. Without edits, the base's values are taken as is.
        var merged = fresh
        // The first read of a setup in this session wins: edits left unsent from
        // an earlier session are dropped.
        if let previousRead, !state.isSynced(s) {
            merged = state.setup(s)
            for key in ParamKey.allCases where previousRead[key] != fresh[key] { merged[key] = fresh[key] }
        }
        persist(merged, synced: merged == fresh, for: s)
    }


    /// On connect: reads every setup. The base only reports its active setup, so
    /// each one is selected in turn, then the wheel goes back to the one it was on.
    /// Nothing is written to the settings.
    /// An untested base is only asked for its active setup: selecting the
    /// others would already be a write.
    func readBase() async {
        guard hasTuningMenu else { return }
        sending = true
        defer { sending = false }
        do {
            try await wheelbase.write([TuningProtocol.initReport])
            guard let first = try await requestSnapshot() else {
                message = "The wheelbase didn't send its settings."
                return
            }
            guard fullAccess else { message = nil; return }
            let active = first.slot  // nil: Auto Setup
            var missed: [Int] = []
            for s in 1...5 where s != active {
                try await wheelbase.write([try TuningProtocol.selectSlot(s)])
                if try await requestSnapshot(slot: s) == nil { missed.append(s) }
            }
            try await wheelbase.write([try active.map(TuningProtocol.selectSlot) ?? TuningProtocol.selectAutoSetup])
            guard try await requestSnapshot(slot: active) != nil else {
                message = "The wheel may not be back on its setup: check it."
                return
            }
            message = nil
            if !missed.isEmpty { message = "Couldn't read setup \(missed.map(String.init).joined(separator: ", "))." }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Read button: the base doesn't report a setup change made on the wheel,
    /// so this asks for the active setup and shows it. Only reads.
    func read() async {
        guard hasTuningMenu else { return }
        sending = true
        defer { sending = false }
        do {
            if let snap = try await requestSnapshot() {
                if let s = snap.slot { slot = s }
                viewingCustomSetup = false
                message = nil
            } else {
                message = "The wheelbase didn't send its settings."
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Steering range of the setup active on the wheel, Auto Setup included: the last
    /// report is always about it. In Auto (no game running) the X axis spans 1080°:
    /// one full turn read 850° with 2530°, measured on a CSL DD.
    var steeringRange: Int? {
        guard let sen = snapshot?.setup[.SEN] else { return nil }
        return sen == 0 ? 1080 : sen
    }

    /// Asks for a tuning report until one arrives (for the given setup if set).
    private func requestSnapshot(slot wanted: Int? = nil, after count: Int? = nil, timeout: Double = 1.5) async throws -> TuningSnapshot? {
        let start = count ?? snapshotCount
        let deadline = Date().addingTimeInterval(timeout)
        var lastAsk = Date.distantPast
        while Date() < deadline {
            if snapshotCount > start, let snap = snapshot, wanted == nil || snap.slot == wanted { return snap }
            if Date().timeIntervalSince(lastAsk) > 0.3 {
                try await wheelbase.write([TuningProtocol.requestTuning])
                lastAsk = Date()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    var canActivate: Bool { base != nil && !sending && wheelSlot != slot }

    /// Switches the wheel to this setup, like its setup button. Writes no setting.
    func activate() async {
        guard writable() else { return }
        let slot = slot
        sending = true
        defer { sending = false }
        do {
            try await wheelbase.write([TuningProtocol.initReport, try TuningProtocol.selectSlot(slot)])
            message = try await requestSnapshot(slot: slot) != nil
                ? nil : "The wheelbase didn't confirm setup \(slot)."
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Switches the wheel to Auto Setup. Writes no setting.
    func activateAutoSetup() async {
        guard !wheelOnAuto else { viewingCustomSetup = false; return }
        guard writable() else { return }
        sending = true
        defer { sending = false }
        do {
            try await wheelbase.write([TuningProtocol.initReport, TuningProtocol.selectAutoSetup])
            message = try await requestSnapshot() != nil ? nil : "The wheelbase didn't confirm Auto Setup."
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// After the driver's OK: switches the Tuning Menu, reads the setups again,
    /// and loads the game that asked for the switch, if any.
    func switchMenu() async {
        let preset = presetAfterMenuSwitch
        presetAfterMenuSwitch = nil
        let before = snapshot?.advancedMode
        guard writable() else { return }
        do {
            try await wheelbase.write([TuningProtocol.toggleMenuMode])
            await readBase()
            if message == nil, snapshot?.advancedMode == before {
                message = "The wheelbase didn't change its Tuning Menu."
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        if let preset, !standardMenu { apply(preset) }
    }

    func cancelMenuSwitch() { presetAfterMenuSwitch = nil }

    /// Selects the setup, reads it back, writes it with only the changed settings
    /// replaced, then reads it again to check.
    func send() async {
        guard writable(), hasTuningMenu else { return }
        let slot = slot, setup = setup
        sending = true
        defer { sending = false }
        do {
            try await wheelbase.write([TuningProtocol.initReport, try TuningProtocol.selectSlot(slot)])
            guard let current = try await requestSnapshot(slot: slot) else {
                message = "The wheelbase didn't confirm setup \(slot). Nothing was written."
                return
            }
            let count = snapshotCount
            try await wheelbase.write([try current.writeFrame(for: setup, profile: profile)])
            guard let echo = try await requestSnapshot(slot: slot, after: count) else {
                persist(setup, synced: false, for: slot)
                message = "Sent to setup \(slot), but the wheelbase didn't send it back."
                return
            }
            let off = ParamKey.allCases.filter { echo.setup[$0] != setup[$0] }
            // Show what the base really holds now, so nothing stays marked as unsent.
            persist(echo.setup, synced: true, for: slot)
            if off.isEmpty {
                message = nil  // the orange marks going away say it was sent
            } else {
                message = "Sent. The wheelbase didn't take " + off.map { "\(param($0).wheelLabel) (it stays \(formatValue($0, echo.setup[$0])))" }.joined(separator: ", ") + "."
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func persist(_ s: Setup, synced: Bool, for target: Int? = nil) {
        let k = "\(target ?? slot)"
        state.setups[k] = s
        state.synced[k] = synced
        do { try store.save(state) } catch { message = "Could not save settings to disk." }
    }
}

/// Collects every input report and redraws at the screen's pace (60 Hz).
@MainActor
final class LiveInput: ObservableObject {
    @Published private(set) var tracker = PeripheralTracker()
    /// Shifter plugged into the Mac with the ClubSport USB adapter.
    @Published private(set) var usbShifterConnected = false
    @Published private(set) var usbGear: USBShifterReport?
    private var pending = PeripheralTracker()
    private var dirty = false
    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        // Common modes: keeps updating while a slider is being dragged.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func feed(_ bytes: [UInt8]) {
        guard let r = InputReport(bytes: bytes) else { return }
        if r == pending.latest { return }
        pending.feed(r)
        dirty = true
    }

    func setUSBShifter(_ present: Bool) {
        usbShifterConnected = present
        if !present { usbGear = nil }
    }

    func feedUSBShifter(_ bytes: [UInt8]) {
        guard let r = USBShifterReport(bytes: bytes), r != usbGear else { return }
        usbGear = r
    }

    func forget() { pending.reset(); tracker = pending; dirty = false }

    private func flush() {
        guard dirty else { return }
        dirty = false
        tracker = pending
    }
}
