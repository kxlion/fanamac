import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: TuningModel

    var body: some View {
        Form {
            Section { StatusHeader() }

            if model.base != nil { DevicesSection(live: model.live, range: model.steeringRange) }

            Section {
                HStack {
                    Text("Tuning Menu")
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach([true, false], id: \.self) { standard in
                            ChoiceChip(text: standard ? "Standard" : "Advanced",
                                       selected: model.snapshotKnown && model.standardMenu == standard,
                                       width: nil) {
                                if model.standardMenu != standard { model.askingMenuSwitch = true }
                            }
                        }
                    }
                    .disabled(model.base == nil || model.sending || !model.snapshotKnown)
                }
                HStack(spacing: 12) {
                    Text("Setup")
                    SetupSelector()
                    Spacer()
                    if model.snapshotKnown, !model.showsAutoSetup, model.wheelSlot != model.slot {
                        Button("Activate") { Task { await model.activate() } }
                            .disabled(!model.canActivate)
                            .help("Switch the wheel to setup \(model.slot)")
                    }
                    Button { Task { await model.read() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.sending || model.base == nil)
                    .help("Read the setup active on the wheel (⌘R)")
                    .accessibilityLabel("Read")
                }
            }

            Section("Standard") {
                ForEach(allParams.filter { $0.standard && model.has($0.key) }, id: \.key.rawValue) { ParamRow(param: $0) }
            }
            .disabled(model.showsAutoSetup)

            if !model.standardMenu {
                Section("Advanced") {
                    ForEach(allParams.filter { !$0.standard && model.has($0.key) }, id: \.key.rawValue) { ParamRow(param: $0) }
                }
                .disabled(model.showsAutoSetup)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 640)
        .safeAreaInset(edge: .bottom) { bottomBar }
        // The version next to the name, to tell an installed copy from a fresh build.
        .navigationTitle("FanaMac \(FanaMacVersion.current)")
        .toolbar {
            ToolbarItem { gamesMenu }.withoutGlass()
            ToolbarItem { profilesMenu }.withoutGlass()
            ToolbarItem { WheelbaseMenu(model: model, live: model.live, mouse: model.mouse) }.withoutGlass()
        }
        .alert(model.standardMenu ? "Switch to Advanced?" : "Switch to Standard?", isPresented: $model.askingMenuSwitch) {
            Button("Switch", role: model.standardMenu ? nil : .destructive) { Task { await model.switchMenu() } }
            Button("Cancel", role: .cancel) { model.cancelMenuSwitch() }
        } message: {
            Text(model.standardMenu
                ? "The wheel's Tuning Menu will show every setting. Your setups keep their values."
                : "This can reset your setups to their default values and puts the wheel on Auto Setup.")
        }
        .alert("Turn on Experimental Mode?", isPresented: $model.askingExperimental) {
            Button("Turn On", role: .destructive) { model.setExperimental(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("FanaMac was never run on a \(model.profile?.name ?? "base like this"). It will write settings to it and let games send forces, capped at \(Int(BaseProfile.untestedForceCap * 100)) %. A wrong command can move the wheel hard or change what the base has stored. Keep your hands clear of the wheel the first time, and be ready to switch the base off.")
        }
        .sheet(item: $model.shownPreset) { PresetSheet(preset: $0, base: model.presetBase, slot: model.slot) }
        .sheet(isPresented: $model.calibratingShifter) { ShifterCalibrationSheet() }
        // Don't start with the cursor in the first value field.
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let msg = model.message {
                    Label(msg, systemImage: model.messageIsNote ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .font(.callout).lineLimit(2)
                        .foregroundStyle(model.messageIsNote ? Color.secondary : .orange)
                }
                Spacer()
                Button("Revert") { model.revertToWheelbase() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canRevert)
                    .help("Undo the changes not sent yet (Esc)")
                Button {
                    Task { await model.send() }
                } label: {
                    if model.sending { ProgressView().controlSize(.small) } else { Text("Send") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend)
                .help("Write setup \(model.slot) to the wheelbase (⌘↩)")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(.bar)
    }

    private var gamesMenu: some View {
        Menu {
            Section("Fanatec recommended, into setup \(model.slot)") {
                ForEach(model.gamePresets) { g in Button(g.game) { model.load(g) } }
            }
        } label: { Label("Games", systemImage: "flag.checkered") }
        .menuStyle(.borderlessButton)
        .disabled(model.gamePresets.isEmpty || model.sending)
        .help("Fanatec's recommended settings for a game")
    }

    private var profilesMenu: some View {
        Menu {
            Button("Export Setup") { exportSetup() }
            Button("Import Setup") { importSetup() }
        } label: { Label("Profiles", systemImage: "square.stack") }
        .menuStyle(.borderlessButton)
    }

    private func importSetup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { model.importSetup(from: url) }
    }

    private func exportSetup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Setup \(model.slot).json"
        if panel.runModal() == .OK, let url = panel.url { model.exportSetup(to: url) }
    }
}

/// The base only reports changes: the calibrations stay grey until it has said
/// what is plugged in. A separate view, so input only redraws this menu.
private extension ToolbarContent {
    /// macOS 26 draws a glass disc behind toolbar items, hard to read in light mode.
    @ToolbarContentBuilder func withoutGlass() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

private struct WheelbaseMenu: View {
    @ObservedObject var model: TuningModel
    @ObservedObject var live: LiveInput
    @ObservedObject var mouse: MouseEmulation

    var body: some View {
        let input = live.tracker.latest
        Menu {
            Button("Calibrate Center") { Task { await model.calibrateCenter() } }
                .disabled(input?.rimID == nil || !model.fullAccess)
            Button("Calibrate Shifter") { model.calibratingShifter = true }
                .disabled(input?.shifterInHMode != true || !model.fullAccess)
            Divider()
            Toggle("Mouse Emulation", isOn: Binding(get: { mouse.isOn }, set: { model.setMouseEmulation($0) }))
            Picker("Mouse Speed", selection: $mouse.speed) {
                Text("Slow").tag(400.0)
                Text("Medium").tag(800.0)
                Text("Fast").tag(1600.0)
            }
            Divider()
            if let p = model.profile, !p.isTested {
                Toggle("Experimental Mode", isOn: Binding(get: { model.experimental }, set: { on in
                    if on { model.askingExperimental = true } else { model.setExperimental(false) }
                }))
            }
            Button("Reset All Setups", role: .destructive) { Task { await model.resetAllSetups() } }
                .disabled(!model.fullAccess)
        } label: { Label("Wheelbase", systemImage: "steeringwheel") }
        .menuStyle(.borderlessButton)
        .disabled(model.base == nil || model.sending)
        .help("Calibration and reset, on the wheelbase itself")
    }
}

/// Fanatec's order: start, then Next once per position.
struct ShifterCalibrationSheet: View {
    @EnvironmentObject var model: TuningModel
    @State private var step = 0

    private var positions: [String] { WheelCommand.shifterPositions }
    private var finished: Bool { step >= positions.count }

    var body: some View {
        VStack(spacing: 16) {
            Text("Shifter Calibration").font(.headline)
            Text(finished ? "✓" : positions[step])
                .font(.system(size: 72, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(finished ? "Done." : "Put the lever in this position, then press Next.")
                .foregroundStyle(.secondary)
            HStack {
                if !finished {
                    Button("Cancel") { model.cancelShifterCalibration() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                Button(finished ? "Close" : "Next") { advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(minWidth: 340)
        .interactiveDismissDisabled()
        .task { _ = await model.sendShifterCalibration(WheelCommand.shifterCalibrationStart) }
    }

    private func advance() {
        guard !finished else { model.calibratingShifter = false; return }
        Task {
            if await model.sendShifterCalibration(WheelCommand.shifterCalibrationNext) { step += 1 }
        }
    }
}

/// A game's in-game settings, shown after its Tuning Menu values are loaded.
struct PresetSheet: View {
    let preset: GamePreset
    let base: String
    let slot: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let v = preset.variant(for: base)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.game).font(.title2.weight(.semibold))
                        if let v { Text(v.label).foregroundStyle(.secondary) }
                        Text("Tuning Menu values loaded into setup \(slot), not sent yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let v {
                        list(v.inGameTitle.isEmpty ? "In-Game Settings" : "In-Game Settings (\(v.inGameTitle))", v.inGame)
                        list("Also on the wheel", v.otherSettings)
                        list("Notes", v.notes)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                Text("Fanatec App 1.6.1.3").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 480, height: 540)
    }

    @ViewBuilder private func list(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct StatusHeader: View {
    @EnvironmentObject var model: TuningModel

    var body: some View {
        HStack(spacing: 14) {
            if let image = NSImage(named: "wheelbase") {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 72, height: 72)
            } else {
                Image(systemName: "steeringwheel")
                    .font(.system(size: 34)).foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.profile.map { "Fanatec \($0.name)" } ?? "Fanatec wheelbase").font(.headline)
                if model.base == nil {
                    Text("Turn the base on in PC mode (red LED). Not detected? Help > Save Diagnostic.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let p = model.profile, !p.isTested {
                    Text(model.experimental
                         ? "Untested base, experimental mode: force capped at \(Int(BaseProfile.untestedForceCap * 100)) %"
                         : "Untested base: read-only")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            // A game is sending forces through the plug-in; red while the wheel is pushed.
            if model.gameConnected || model.forceActive {
                HStack(spacing: 6) {
                    Circle().fill(model.forceActive ? Color.red : .green).frame(width: 8, height: 8)
                    Text(model.gameConnected ? "Game" : "Force").font(.callout)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            }
            HStack(spacing: 6) {
                Circle().fill(model.base == nil ? Color.secondary : model.wineTooEarly ? .orange : .green)
                    .frame(width: 8, height: 8)
                Text(model.base == nil ? "Not connected" : "Connected").font(.callout)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
            .help(model.wineTooEarly ? "CrossOver was already running: restart it for force feedback, brake and handbrake." : "")
        }
        .padding(.vertical, 4)
    }
}

struct DevicesSection: View {
    @ObservedObject var live: LiveInput
    /// Lock-to-lock degrees of the active setup, to turn the X axis into an angle.
    var range: Int?

    var body: some View {
        let t = live.tracker
        let r = t.latest
        Section {
                LabeledContent("Wheel") {
                    Text(r?.rimName ?? (r == nil ? "Turn the wheel to detect" : "No wheel detected"))
                        .foregroundStyle(r?.rimName == nil ? .secondary : .primary)
                }
                LabeledContent("Angle") {
                    if let x = r?.axes[.X], let range {
                        // X is centred on 32768 and spans the whole lock-to-lock range.
                        let deg = (Double(x) - 32768) / 32768 * Double(range) / 2
                        Text({ let d = Int(deg.rounded()); return d > 0 ? "+\(d)°" : "\(d)°" }())
                            .font(.body.monospacedDigit())
                            .transaction { $0.animation = nil }
                    } else {
                        Text(r == nil ? "Turn the wheel to detect" : "Press Read to get the range")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Pedal.allCases, id: \.self) { p in
                    LabeledContent(p.rawValue) {
                        if t.seen(p) {
                            HStack(spacing: 8) {
                                PedalBar(value: r?.pedal(p) ?? 0).frame(width: 160, height: 6)
                                Text("\(Int(((r?.pedal(p) ?? 0) * 100).rounded()))%")
                                    .font(.body.monospacedDigit()).frame(width: 40, alignment: .trailing)
                            }
                        } else {
                            Text("Press it once to detect").foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Handbrake") {
                    if t.handbrakeSeen {
                        HStack(spacing: 8) {
                            PedalBar(value: t.handbrake).frame(width: 160, height: 6)
                            Text("\(Int((t.handbrake * 100).rounded()))%")
                                .font(.body.monospacedDigit()).frame(width: 40, alignment: .trailing)
                        }
                    } else {
                        Text("Pull it once to detect").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Shifter") {
                    if live.usbShifterConnected {
                        GearView(source: "USB adapter", label: live.usbGear?.label ?? "N")
                    } else if let r, r.shifterInHMode {
                        GearView(source: "H pattern", label: r.hGear.label)
                    } else if t.shifterSeen {
                        HStack(spacing: 6) {
                            Text("Sequential").foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.circle.fill")
                                .foregroundStyle(t.shiftingUp ? Color.accentColor : Color.secondary.opacity(0.3))
                            Image(systemName: "chevron.down.circle.fill")
                                .foregroundStyle(t.shiftingDown ? Color.accentColor : Color.secondary.opacity(0.3))
                        }
                    } else {
                        Text("Shift once to detect").foregroundStyle(.secondary)
                    }
                }
                if !t.otherAxes.isEmpty {
                    LabeledContent("Other inputs") {
                        Text(t.otherAxes.map { "\($0.rawValue) \(r?.axes[$0] ?? 0)" }.joined(separator: " · "))
                            .font(.body.monospacedDigit())
                    }
                }
                LabeledContent("Buttons") {
                    let text = buttonsText(r)
                    Text(text ?? (r == nil ? "–" : "None pressed")).font(.body.monospacedDigit())
                        .foregroundStyle(text == nil ? .secondary : .primary)
                }
        } header: {
            HStack {
                Text("Connected Devices")
                Spacer()
                Button("Forget", systemImage: "arrow.counterclockwise") { live.forget() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Clear the detected pedals, handbrake and shifter, then detect them again")
            }
        }
    }

    /// Wheel buttons and D-pad only; the shifter's buttons are shown on its own row.
    /// nil when nothing is pressed.
    private func buttonsText(_ r: InputReport?) -> String? {
        guard let r else { return nil }
        let shifter: Set<Int> = r.shifterInHMode
            ? Set(InputReport.hGearButtons)
            : [PeripheralTracker.shiftUp, PeripheralTracker.shiftDown]
        var parts = r.buttons.filter { !shifter.contains($0) }.map(String.init)
        if let h = r.hat { parts.insert("D-pad \(["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"][h])", at: 0) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

}

struct GearView: View {
    let source: String
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            Text(source).foregroundStyle(.secondary)
            Text(label)
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(minWidth: 16, alignment: .trailing)
        }
    }
}

/// A plain bar, drawn without animation so it follows the pedal exactly.
struct PedalBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// Drawn from the model alone, so it can't show something the base didn't do.
private struct ChoiceChip: View {
    let text: String
    let selected: Bool
    var active = false
    var width: CGFloat? = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.body.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, width == nil ? 10 : 0)
                .frame(width: width, height: 26)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(active ? Color.green : .clear, lineWidth: 2.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Auto Setup, then the Custom Setup (Standard menu) or the 5 setups (Advanced).
/// Blue = shown here, green ring = active on the wheel,
/// orange dot = changes not sent yet, dashed = not read from the base.
struct SetupSelector: View {
    @EnvironmentObject var model: TuningModel

    var body: some View {
        HStack(spacing: 6) {
            ChoiceChip(text: "A", selected: model.showsAutoSetup, active: model.wheelOnAuto) {
                Task { await model.activateAutoSetup() }
            }
            .accessibilityLabel("Auto Setup")
            .help("Auto Setup: only the game changes its values")
            .disabled(model.sending || model.base == nil)

            if model.standardMenu {
                ChoiceChip(text: "C", selected: !model.showsAutoSetup, active: !model.wheelOnAuto) {
                    Task { await model.activate() }
                }
                .accessibilityLabel("Custom Setup")
                .help("Custom Setup")
                .disabled(model.sending || model.base == nil)
            } else {
                customSetups
            }
        }
    }

    private var customSetups: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { n in
                let selected = n == model.slot && !model.showsAutoSetup
                let active = n == model.wheelSlot
                Button { model.show(setup: n) } label: {
                    Text("\(n)")
                        .font(.body.monospacedDigit().weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : .primary)
                        .frame(width: 34, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(selected ? Color.accentColor : Color.secondary.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(active ? Color.green : .clear, lineWidth: 2.5))
                        .overlay(alignment: .topTrailing) {
                            if model.hasChanges(n) {
                                Circle().fill(.orange).frame(width: 8, height: 8).offset(x: 3, y: -3)
                            }
                        }
                        .opacity(model.isRead(n) ? 1 : 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                .accessibilityLabel("Setup \(n)")
                .accessibilityValue([active ? "active on the wheel" : nil,
                                     model.hasChanges(n) ? "changes not sent" : nil,
                                     model.isRead(n) ? nil : "not read"].compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(["Setup \(n) (⌘\(n))", active ? "Active on the wheel" : nil,
                       model.hasChanges(n) ? "Changes not sent" : nil,
                       model.isRead(n) ? nil : "Not read from the wheelbase"]
                    .compactMap { $0 }.joined(separator: " · "))
            }
        }
    }
}

/// One line per setting: name and wheel code, control, value.
struct ParamRow: View {
    @EnvironmentObject var model: TuningModel
    let param: Param

    var body: some View {
        let value = model.binding(param.key)
        let changed = model.isChanged(param.key)
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(param.name).lineLimit(1)
                Text(param.wheelLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                if param.key == .SEN {
                    // Auto sits in the name column so this slider lines up with the others.
                    Spacer(minLength: 4)
                    Toggle("Auto", isOn: Binding(get: { value.wrappedValue == 0 },
                                                 set: { value.wrappedValue = $0 ? 0 : 900 }))
                        .toggleStyle(.checkbox)
                }
            }
            .frame(width: 200, alignment: .leading)

            control(value)

            if changed, let b = model.baseValue(param.key) {
                Button { model.revert(param.key) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Put back the wheelbase's value: \(formatValue(param.key, b))")
                    .accessibilityLabel("Revert to \(formatValue(param.key, b))")
            }
            valueView(value, changed: changed)
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            if changed { Capsule().fill(.orange).frame(width: 3) }
        }
        .help("\(param.help) Default: \(formatValue(param.key, param.defaultValue)).")
        .accessibilityElement(children: .contain)
        .accessibilityValue(changed ? "changed" : "")
    }

    @ViewBuilder
    private func control(_ value: Binding<Int>) -> some View {
        switch param.key {
        case .FFS:
            Spacer()
            Picker("", selection: value) { Text("Linear").tag(0); Text("Peak").tag(1) }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        case .SEN:
            if value.wrappedValue != 0 {
                Slider(value: doubleBinding(value), in: 90...Double(model.maxAngle))
            } else {
                Spacer()
            }
        default:
            // No step on the slider (it would draw tick marks); the binding rounds to the step.
            Slider(value: doubleBinding(value),
                   in: Double(param.range.lowerBound)...Double(param.range.upperBound))
        }
    }

    /// The value, typed in directly; the unit sits after it.
    @ViewBuilder
    private func valueView(_ value: Binding<Int>, changed: Bool) -> some View {
        if param.key == .FFS || (param.key == .SEN && value.wrappedValue == 0) {
            EmptyView()
        } else if value.wrappedValue == 0, [.INT, .BLI, .FUL].contains(param.key) {
            Text("Off").foregroundStyle(changed ? Color.orange : .secondary)
                .frame(width: 60, alignment: .trailing)
        } else {
            HStack(spacing: 2) {
                TextField("", value: typed(value), format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .font(.body.monospacedDigit().weight(changed ? .semibold : .regular))
                    .foregroundStyle(changed ? Color.orange : .primary)
                    .frame(width: 44)
                Text(param.unit).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            }
        }
    }

    /// Typed values snap to the step and stay in range.
    private func typed(_ v: Binding<Int>) -> Binding<Int> {
        let lo = param.key == .SEN ? 90 : param.range.lowerBound
        return Binding(get: { v.wrappedValue }, set: {
            let snapped = Int((Double($0) / Double(param.step)).rounded()) * param.step
            v.wrappedValue = min(max(snapped, lo), param.range.upperBound)
        })
    }

    private func doubleBinding(_ v: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = Int(($0 / Double(param.step)).rounded()) * param.step })
    }
}
