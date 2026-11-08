// Hardware-free tests. Expected values were measured on a real CSL DD:
// SEN = (raw + 127) × 10 modulo 2560, Auto = 2530° (0x7E), setup N = N + 1.

import Foundation

var failures = 0
var count = 0
func check(_ cond: @autoclosure () throws -> Bool, _ msg: String, line: Int = #line) {
    count += 1
    do { if try !cond() { failures += 1; print("FAIL line \(line): \(msg)") } }
    catch { failures += 1; print("FAIL line \(line): \(msg) threw \(error)") }
}
func throwsError(_ f: () throws -> Void) -> Bool { do { try f(); return false } catch { return true } }
func reg(_ buf: [UInt8], _ name: String) -> Int { Int(buf[TuningProtocol.registers[name]! + 1]) }

// SEN encoding
for (deg, raw) in [(900, 0xDB), (540, 0xB7), (360, 165), (1080, 0xED), (2520, 0x7D), (90, 0x8A), (0, 0x7E)] {
    check(try Int(TuningProtocol.encodeSEN(deg)) == raw, "SEN \(deg) -> \(raw)")
    check(TuningProtocol.decodeSEN(UInt8(raw)) == deg, "SEN \(raw) -> \(deg)")
}
for bad in [45, 89, 2530, -10] { check(throwsError { _ = try TuningProtocol.encodeSEN(bad) }, "SEN \(bad) rejected") }

// Tuning report read from a real CSL DD (setup 1, advanced menu) after FF 03 02.
let hwRead: [UInt8] = [0xFF, 0x03, 0x02, 0x7E, 0x5A, 0x0A, 0x65, 0x01, 0x00, 0x00, 0x0A, 0x0A, 0x0A, 0x31,
                       0x00, 0x32, 0x32, 0x64, 0x03, 0x01, 0x0B, 0x00, 0x00, 0x01, 0x01] + [UInt8](repeating: 0, count: 39)
let snap = TuningSnapshot(report: hwRead)!
check(snap.slot == 1 && snap.advancedMode, "setup 1, advanced")
let read = snap.setup
check(read[.SEN] == 0 && read[.FF] == 90 && read[.SHO] == 100 && read[.BLI] == 0 && read[.FFS] == 1, "SEN/FF/SHO/BLI/FFS read")
check(read[.FOR] == 100 && read[.SPR] == 100 && read[.DPR] == 100 && read[.NDP] == 49 && read[.NFR] == 0, "FOR/SPR/DPR/NDP/NFR read")
check(read[.BRF] == 50 && read[.FEI] == 100 && read[.INT] == 11 && read[.NIN] == 0 && read[.FUL] == 0, "BRF/FEI/INT/NIN/FUL read")
check(TuningSnapshot(report: [0xFF, 0x03, 0x82] + [UInt8](repeating: 0, count: 61))!.slot == 1, "standard menu flag ignored")
check(TuningSnapshot(report: [0xFF, 0x03, 0x01] + [UInt8](repeating: 0, count: 61))!.slot == nil, "raw 1 is no setup")
let standardSnap = TuningSnapshot(report: [0xFF, 0x03, 0x82] + [UInt8](repeating: 0, count: 61))!
check(!standardSnap.advancedMode, "standard menu flag read")
check(try standardSnap.writeFrame(for: standardSnap.setup)[3] == 0x02, "standard menu flag not written")
check(TuningSnapshot(report: [0xFF, 0x03, 0x81] + [UInt8](repeating: 0, count: 61))!.isAutoSetup, "auto setup read")
check(!standardSnap.isAutoSetup, "custom setup is not auto")
check(TuningProtocol.toggleMenuMode.count == 64 && TuningProtocol.toggleMenuMode.prefix(3) == [0xFF, 0x03, 0x06], "menu toggle frame")
check(TuningProtocol.selectAutoSetup.count == 64 && TuningProtocol.selectAutoSetup.prefix(4) == [0xFF, 0x03, 0x01, 0x01], "auto setup frame")
var brakeReport = [UInt8](repeating: 0, count: 64); brakeReport[0] = 0xFF; brakeReport[1] = 0x03; brakeReport[2] = 0x02
brakeReport[0x0F] = 75; brakeReport[0x10] = 85
check(TuningSnapshot(report: brakeReport)!.value(.BRF) == 85, "brake force read where the wheel changes it")
check(TuningSnapshot(report: [0x01] + [UInt8](repeating: 0, count: 63)) == nil, "input report is not a snapshot")

// Unchanged setup writes the base's bytes back as they were (unknown registers kept).
let same = try snap.writeFrame(for: read)
check(same.count == 64 && Array(same[0..<3]) == [0xFF, 0x03, 0x00], "write header")
check(Array(same[3..<64]) == Array(hwRead[2..<63]), "write = snapshot shifted by one")

// Changed settings: only those bytes move; BRF goes to both addresses.
var w = read; w[.FF] = 40; w[.SEN] = 540; w[.BRF] = 70; w[.FOR] = 60; w[.BLI] = 50
let frame = try snap.writeFrame(for: w)
check(reg(frame, "FF") == 40 && reg(frame, "SEN") == 0xB7 && reg(frame, "FOR") == 6 && reg(frame, "BLI") == 50, "changed values")
check(reg(frame, "BRF") == 70 && frame[TuningProtocol.brakeForceAlt + 1] == 70, "BRF at 0x0F and 0x10")
check(frame[0x13 + 1] == 0x01 && frame[0x12 + 1] == 0x03 && frame[0x17 + 1] == 0x01, "ACP and unknown registers kept")
check(reg(frame, "SLOT") == 0x02, "slot byte kept")
let snap2 = TuningSnapshot(report: [0xFF, 0x03] + frame[3..<64] + [0])!
check(snap2.setup == w, "frame reads back as written")
var off = w; off[.BLI] = 0; off[.SEN] = 0
let offFrame = try snap2.writeFrame(for: off)
check(reg(offFrame, "BLI") == 101 && reg(offFrame, "SEN") == 0x7E, "Off/Auto codes")
check(throwsError { _ = try snap.writeFrame(for: { var x = read; x[.FF] = 101; return x }()) }, "invalid setup rejected")

// Slot select and read request
check(Array(try TuningProtocol.selectSlot(1)[0..<4]) == [0xFF, 0x03, 0x01, 2], "select setup 1 = raw 2")
check(Array(try TuningProtocol.selectSlot(5)[0..<4]) == [0xFF, 0x03, 0x01, 6], "select setup 5 = raw 6")
check(throwsError { _ = try TuningProtocol.selectSlot(6) }, "slot 6 rejected")
check(TuningProtocol.requestTuning.count == 64 && Array(TuningProtocol.requestTuning[0..<3]) == [0xFF, 0x03, 0x02], "read request")


// Validation
var bad = Setup(); bad[.FF] = 101
check(throwsError { try bad.validate() }, "FF 101 rejected")
var badSen = Setup(); badSen[.SEN] = 50
check(throwsError { try badSen.validate() }, "SEN 50 rejected")
check(allParams.allSatisfy { Setup()[$0.key] == $0.defaultValue }, "defaults match metadata")
check(allParams.filter(\.standard).map(\.wheelLabel) == ["FFB", "SEN", "NDP", "BRF"], "standard menu matches wheel")

// Store round-trip and file format
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fanamac-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmp) }
let store = Store(root: tmp)
check(store.load() == AppState(), "empty store gives defaults")
var st = AppState(); var s2 = Setup(); s2[.FF] = 40
st.setups["2"] = s2; st.synced["2"] = true; st.active = 2
try store.save(st)
check(store.load() == st, "state round-trip")

let savedState = #"{"setups": {"1": {"SEN": 540, "FF": 50, "FFS": 1, "NDP": 50, "NFR": 0, "NIN": 0, "INT": 11, "FEI": 100, "FOR": 60, "SPR": 100, "DPR": 100, "SHO": 50, "BLI": 0, "BRF": 50, "FUL": 100}}, "active": 1, "synced": {"1": true}}"#
try savedState.write(to: tmp.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
let loaded = store.load()
check(loaded.setup(1)[.SEN] == 540 && loaded.setup(1)[.FOR] == 60 && loaded.isSynced(1), "reads a saved state file")
check(loaded.setup(2) == Setup(), "missing setups get defaults")

// Input report 0x01
var raw = [UInt8](repeating: 0, count: 34)
raw[0] = 0x01; raw[1] = 0x0F                    // hat centred
raw[2] = 0x01                                    // button 5 = bit 8
raw[17] = 0x00; raw[18] = 0x80                   // X centre
for i in [19, 21] { raw[i] = 0xFF; raw[i + 1] = 0xFF }  // Z, Rz at rest
raw[23] = 0; raw[24] = 0                          // Y (clutch) fully pressed
raw[29...33] = [0x05, 0x14, 0x04, 0x01, 0x06]
let rep = InputReport(bytes: raw)!
check(rep.hat == nil && rep.buttons == [5], "hat and buttons decoded")
check(rep.axes[.X] == 0x8000 && rep.pedal(.clutch) == 1 && rep.pedal(.brake) == 0, "axes and pedals decoded")
check(rep.rimName == "ClubSport Steering Wheel RS", "rim RS detected")
check(!rep.shifterInHMode, "vendor 05 = sequential")
check(InputReport(bytes: Array(raw.dropFirst())) == rep, "report without ID byte")
check(InputReport(bytes: [0xFF, 3]) == nil, "other reports ignored")
var tr = PeripheralTracker()
tr.feed(rep)
var pressed = raw; pressed[21] = 0x00; pressed[22] = 0xC0; pressed[27] = 40
tr.feed(InputReport(bytes: pressed)!)
check(tr.seen(.brake) && !tr.seen(.clutch) && tr.otherAxes.isEmpty, "tracker sees the brake")
check(tr.handbrakeSeen && tr.handbrake == 1, "handbrake on Slider, full at furthest pull")
var half = pressed; half[27] = 20
tr.feed(InputReport(bytes: half)!)
check(tr.handbrake == 0.5, "handbrake halfway")
check(!tr.shifterSeen, "no shifter yet")
var up = half; up[5] = 0x01                      // button 29 = bit 32
tr.feed(InputReport(bytes: up)!)
check(tr.shifterSeen && tr.shiftingUp && !tr.shiftingDown, "sequential shift up")

// H gear through the base (byte 3)
var hRaw = raw; hRaw[3] = 0x02
check(InputReport(bytes: hRaw)!.hGear.label == "1" && InputReport(bytes: hRaw)!.buttons.contains(14), "base H 1st = button 14")
hRaw[3] = 0x80
check(InputReport(bytes: hRaw)!.hGear.label == "7", "base H 7th")
hRaw[3] = 0x01
check(InputReport(bytes: hRaw)!.hGear.label == "R" && InputReport(bytes: hRaw)!.buttons.contains(13), "base H reverse = button 13")
check(rep.hGear.label == "N", "base H neutral")

// USB shifter
check(USBShifterReport(bytes: [0x00, 0, 1, 0x0A, 0x11])?.label == "N", "USB shifter neutral")
check(USBShifterReport(bytes: [0x02, 0, 1, 0x0A, 0x11])?.label == "1", "USB shifter 1st")
check(USBShifterReport(bytes: [0x40, 0, 1, 0x0A, 0x11])?.label == "6", "USB shifter 6th")
check(USBShifterReport(bytes: [0x01, 0, 1, 0x0A, 0x11])?.label == "R", "USB shifter reverse")
check(USBShifterReport(bytes: [0x01, 0x02]) == nil, "USB shifter: other sizes ignored")

// Game presets (the bundled file from the Fanatec App)
let presetURL = URL(fileURLWithPath: "Presets/fanatec_recommended.json")  // build.sh runs from app/
if let lib = try? PresetLibrary.load(presetURL) {
    let cslGames = lib.games(for: "CSLDD").map(\.game)
    check(cslGames.contains("iRacing") && cslGames.contains("Assetto Corsa Competizione") && !cslGames.contains("DiRT Rally"), "CSL DD games")
    let ir = lib.games.first { $0.game == "iRacing" }!.variant(for: "CSLDD")!
    check(ir.label.hasPrefix("CSL DD") && ir.tuning["SEN"] == 1080 && ir.tuning["NDP"] == 15 && ir.tuning["INT"] == 6, "iRacing CSL DD values")
    check(ir.userPreference == ["BLI", "BRF"] && ir.inGame.contains("Use Linear Mode: Checked"), "iRacing kept settings and in-game list")
    var mine = Setup(); mine[.BLI] = 40; mine[.BRF] = 70; mine[.FUL] = 0
    let applied = ir.applied(to: mine)
    check(applied[.SEN] == 1080 && applied[.FFS] == 1 && applied[.NIN] == 0 && applied[.BLI] == 40 && applied[.BRF] == 70 && applied[.FUL] == 0, "preset keeps what it doesn't list")
    check((try? applied.validate()) != nil, "preset values in range")
    let wrc = lib.games.first { $0.game == "WRC Generations" }!.variant(for: "CSLDD")!
    check(wrc.otherSettings.isEmpty && wrc.tuning["SEN"] == 0, "WRC: CSL DD section, not the belt-driven one")
    var allValid = true
    for g in lib.games { for (_, b) in g.bases { for v in b.variants where (try? v.applied(to: Setup()).validate()) == nil { allValid = false } } }
    check(allValid, "every preset value in range")
} else {
    check(false, "presets file loads")
}

// Force frames. Direction measured on a real CSL DD: raw below 0x8000 turns clockwise.
check(try ForceProtocol.constant(0.05) == [0x01, 0x01, 0x08, 0x9A, 0x79, 0, 0, 0x01], "5 % clockwise = raw 0x799A")
check(try ForceProtocol.constant(-0.05) == [0x01, 0x01, 0x08, 0x66, 0x86, 0, 0, 0x01], "5 % anti-clockwise = raw 0x8666")
check(try ForceProtocol.constant(1) == [0x01, 0x01, 0x08, 0x01, 0x00, 0, 0, 0x01], "full clockwise = raw 0x0001")
check(try ForceProtocol.constant(-1) == [0x01, 0x01, 0x08, 0xFF, 0xFF, 0, 0, 0x01], "full anti-clockwise = 0xFFFF")
check(try ForceProtocol.constant(0) == ForceProtocol.constantOff, "0 turns the slot off")
check(ForceProtocol.constantOff == [0x01, 0x03, 0x08, 0, 0, 0, 0, 0], "slot off frame")
check(ForceProtocol.stopAll == [0x01, 0xF3, 0, 0, 0, 0, 0, 0], "stop-all frame")
for bad in [1.01, -2, Double.nan, Double.infinity] {
    check(throwsError { _ = try ForceProtocol.constant(bad) }, "force \(bad) refused")
}

// Spring and damper frames: the same bytes as the CLI test that was felt on the wheel.
let spring20 = ConditionSlot(posCoeff: 0.2, negCoeff: 0.2, saturation: 0.2)
check(try ForceProtocol.spring(spring20) == [0x01, 0x11, 0x0B, 0x80, 0x80, 0x33, 0, 0x33], "spring 20 % as felt")
check(try ForceProtocol.damper(spring20) == [0x01, 0x21, 0x0C, 0x03, 0, 0x03, 0, 0x33], "damper 20 % as felt")
check(try ForceProtocol.spring(ConditionSlot(posCoeff: 0.05, negCoeff: 0.05, saturation: 0.05))?[5] == 0x11,
      "weak spring 5 % keeps step 1 (nearest step, not 0)")
check(ForceProtocol.coeff4(0.03) == 0 && ForceProtocol.coeff4(0.04) == 1 && ForceProtocol.coeff4(0.4999) == 7
      && ForceProtocol.coeff4(0.5) == 8 && ForceProtocol.coeff4(-1) == 15, "stiffness to the nearest of 16 steps")
check(try ForceProtocol.spring(ConditionSlot(posCoeff: 1, negCoeff: -0.5, saturation: 1)) ==
      [0x01, 0x11, 0x0B, 0x80, 0x80, 0xF8, 0, 0xFF], "spring sides: positive high, negative low, sign dropped")
check(try ForceProtocol.spring(ConditionSlot(offset: 0.5, deadband: 0.25, posCoeff: 1, negCoeff: 1, saturation: 1))?[3...4] == [0xA0, 0xDF],
      "spring edges: offset ± deadband")
check(try ForceProtocol.spring(ConditionSlot(offset: -1, deadband: 1, posCoeff: 1, saturation: 1))?[3...4] == [0x00, 0x80],
      "spring edges stop at the end of travel")
check(try ForceProtocol.damper(ConditionSlot(posCoeff: 1, negCoeff: 0.2, saturation: 1)) ==
      [0x01, 0x21, 0x0C, 0x03, 0, 0x0F, 0, 0xFF], "damper: negative side in byte 2, positive in byte 4")
check(try ForceProtocol.spring(.off) == nil && ForceProtocol.damper(ConditionSlot(posCoeff: 1)) == nil, "no saturation = off")
check(ForceProtocol.springOff == [0x01, 0x13, 0x0B, 0, 0, 0, 0, 0], "spring off frame")
check(ForceProtocol.damperOff == [0x01, 0x23, 0x0C, 0, 0, 0, 0, 0xFF], "damper off frame")
check(throwsError { _ = try ForceProtocol.spring(ConditionSlot(saturation: 1.5)) }, "saturation past 1 refused")
check(throwsError { _ = try ForceProtocol.damper(ConditionSlot(posCoeff: .nan, saturation: 1)) }, "NaN coefficient refused")

// Force engine: keep-alive, safety stop, Stop.
do {
    let t0 = Date(timeIntervalSince1970: 1000)
    var e = ForceEngine(timeout: 0.25)
    check(e.tick(at: t0).isEmpty && !e.isActive, "idle engine sends nothing")
    let push = try ForceProtocol.constant(0.3)
    check(try e.set(0.3, at: t0) == [push] && e.isActive, "new force goes out at once")
    check(try e.set(0.3, at: t0.addingTimeInterval(0.01)).isEmpty, "same force is not sent twice by set")
    check(e.tick(at: t0.addingTimeInterval(0.02)) == [push], "keep-alive resends it")
    check(e.tick(at: t0.addingTimeInterval(0.2)) == [push], "still on within the timeout")
    check(e.tick(at: t0.addingTimeInterval(0.3)) == [ForceProtocol.constantOff] && !e.isActive, "no command for 0.29 s: cut")
    check(e.tick(at: t0.addingTimeInterval(0.32)).isEmpty, "then quiet")
    check(try e.set(0.3, at: t0.addingTimeInterval(1)) == [push], "same level after a cut goes out again")
    check(try e.set(0, at: t0.addingTimeInterval(1.01)) == [ForceProtocol.constantOff] && !e.isActive, "level 0 cuts")
    check(try e.set(0.00001, at: t0.addingTimeInterval(1.02)).isEmpty && !e.isActive, "a level too small for the base is off")
    _ = try e.set(-1, at: t0.addingTimeInterval(2))
    check(e.stop() == [ForceProtocol.constantOff, ForceProtocol.springOff, ForceProtocol.damperOff, ForceProtocol.stopAll] && !e.isActive,
          "Stop cuts everything")
    check(e.tick(at: t0.addingTimeInterval(2.01)).isEmpty, "nothing after Stop until a new command")
    check(throwsError { _ = try e.set(3, at: t0) } && e.level == 0, "bad level refused, engine unchanged")

    // Spring and damper: sent once, then only when they change.
    var g = ForceEngine(timeout: 0.25)
    let sp = try ForceProtocol.spring(spring20)!, dp = try ForceProtocol.damper(spring20)!
    check(try g.set(ForceCommand(level: 0, spring: spring20), at: t0) == [sp] && g.isActive, "spring goes out at once")
    check(g.tick(at: t0.addingTimeInterval(0.02)).isEmpty, "the base keeps the spring: no resend")
    check(try g.set(ForceCommand(level: 0.3, spring: spring20, damper: spring20), at: t0.addingTimeInterval(0.04)) == [push, dp],
          "only what changed goes out")
    check(g.tick(at: t0.addingTimeInterval(0.06)) == [push], "keep-alive resends the constant force only")
    check(try g.set(ForceCommand(level: 0.3, damper: spring20), at: t0.addingTimeInterval(0.08)) == [ForceProtocol.springOff],
          "spring dropped: its slot is switched off")
    check(g.tick(at: t0.addingTimeInterval(0.4)) == [ForceProtocol.constantOff, ForceProtocol.damperOff] && !g.isActive,
          "no command for a while: every slot that was on is switched off")
    check(throwsError { _ = try g.set(ForceCommand(level: 0, spring: ConditionSlot(deadband: -1)), at: t0) }, "bad spring refused")
} catch { check(false, "force engine threw \(error)") }

// Force packets (ffplugin/src/packet.h): level 0.5, spring {offset 0.25, deadband 0, +0.5, -0.5, saturation 1},
// damper {0, 0, 0.5, 0.5, 0.5}.
func f32(_ v: Float) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }
var pkt: [UInt8] = [0x46, 0x4D, 0x46, 0x46, 1, 1, 0, 0, 4, 3, 2, 1] + f32(0.5)
pkt += f32(0.25) + f32(0) + f32(0.5) + f32(-0.5) + f32(1)
pkt += f32(0) + f32(0) + f32(0.5) + f32(0.5) + f32(0.5)
check(ForcePacket(bytes: pkt)?.level == 0.5, "packet level 0.5")
check(ForcePacket(bytes: pkt)?.sequence == 0x01020304 && ForcePacket(bytes: pkt)?.active == true, "packet seq and flag")
check(ForcePacket(bytes: pkt)?.command == ForceCommand(level: 0.5, spring: ConditionSlot(offset: 0.25, posCoeff: 0.5, negCoeff: -0.5, saturation: 1),
                                                       damper: ConditionSlot(posCoeff: 0.5, negCoeff: 0.5, saturation: 0.5)), "packet spring and damper")
var released = pkt; released[5] = 0
check(ForcePacket(bytes: released)?.active == false, "release flag")
var otherVersion = pkt; otherVersion[4] = 2
check(ForcePacket(bytes: otherVersion) == nil, "unknown version refused")
var badMagic = pkt; badMagic[0] = 0x58
check(ForcePacket(bytes: badMagic) == nil, "bad magic refused")
check(ForcePacket(bytes: Array(pkt[0..<55])) == nil && ForcePacket(bytes: pkt + [0]) == nil, "packet size checked")
var big = pkt; big[12...15] = [0, 0, 0, 0x40]  // 2.0
check(ForcePacket(bytes: big) == nil, "level past 1 refused")
var nan = pkt; nan[12...15] = [0, 0, 0xC0, 0x7F]
check(ForcePacket(bytes: nan) == nil, "NaN refused")
var badSpring = pkt; badSpring[32...35] = ArraySlice(f32(2))
check(ForcePacket(bytes: badSpring) == nil, "spring saturation past 1 refused")

// Recording analysis (fanamac record)
check(Record.decode(ForceProtocol.constantOff) == Record.Decoded(kind: "constant", level: 0), "decode constant off")
check(abs((Record.decode(try ForceProtocol.constant(0.5)).level ?? 0) - 0.5) < 0.001, "decode constant level")
let testSpring = ConditionSlot(posCoeff: 0.2, negCoeff: 0.2, saturation: 0.2)
let springFrame = try ForceProtocol.spring(testSpring)!
check(Record.decode(springFrame).detail == "edges (128, 128), stiffness + 3, stiffness − 3, max 51", "decode spring")
check(Record.decode(ForceProtocol.springOff) == Record.Decoded(kind: "spring"), "decode spring off")
let damperFrame = try ForceProtocol.damper(testSpring)!
check(Record.decode(damperFrame).detail == "coeff + 3, coeff − 3, max 51", "decode damper")
check(Record.decode(ForceProtocol.stopAll).kind == "stop all", "decode stop all")

// A 10 Hz vibration, as FanaMac would record it: packets, frames, wheel position.
func hexLine(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
var sineLines: [String] = []
for i in 0..<1000 {
    let t = Double(i) * 2
    let wave = sin(2 * Double.pi * 10 * t / 1000)
    let text = String(format: "%.5f", 0.05 * wave)
    sineLines.append(String(format: "%.2f pkt \(i) 1 ", t) + text + " | 0 0 0 0 0 | 0 0 0 0 0")
    let raw = 0x8000 - Int((Double(text)! * 0x7FFF).rounded())
    sineLines.append(String(format: "%.2f out ", t + 0.3) + hexLine([1, 1, 8, UInt8(raw & 0xFF), UInt8(raw >> 8), 0, 0, 1]))
    sineLines.append(String(format: "%.2f x \(32768 + Int((200 * wave).rounded()))", t + 0.5))
}
let sineText = Record.summary(sineLines.joined(separator: "\n")).joined(separator: "\n")
check(sineText.contains("the requested force oscillates at 10.0 Hz"), "packets' frequency found")
check(sineText.contains(", oscillates at 10.0 Hz"), "frames' frequency found")
check(sineText.contains("the wheel oscillates at 10.0 Hz"), "wheel's frequency found")
check(sineText.contains("packet to frame delay: median 0.30 ms"), "packet to frame delay")

let springLines = ["0.00 pkt 0 1 0 | 0 0 0.2 0.2 0.2 | 0 0 0 0 0",
                   "0.40 out " + hexLine(springFrame),
                   "500.00 out " + hexLine(ForceProtocol.springOff),
                   "10.00 x 32768", "300.00 x 34000"]
let springText = Record.summary(springLines.joined(separator: "\n")).joined(separator: "\n")
check(springText.contains("requested spring: stiffness +0.200"), "spring asked")
check(springText.contains("spring: 2 — edges (128, 128), stiffness + 3, stiffness − 3, max 51 | off"), "spring frames summed up")
check(springText.contains("32768 … 34000"), "wheel range")
check(Record.summary("")[0].contains("Empty"), "empty recording")

// One-off commands: the bytes read from Fanatec's SDK (docs/PROTOCOL.md).
check(WheelCommand.centerCalibrate == [0x01, 0xF9, 0x05, 0, 0, 0, 0, 0], "centre calibration frame")
check(WheelCommand.shifterCalibrationStart == [0x01, 0xF8, 0x09, 0x01, 0x19, 1, 0, 0], "shifter start frame")
check(WheelCommand.shifterCalibrationNext == [0x01, 0xF8, 0x09, 0x01, 0x19, 2, 0, 0], "shifter next frame")
check(WheelCommand.shifterPositions.count == 9 && WheelCommand.shifterPositions.prefix(2) == ["N", "R"], "CSL DD starts with neutral")
check(TuningProtocol.resetAllSetups.count == 64 && TuningProtocol.resetAllSetups.prefix(3) == [0xFF, 0x03, 0x04], "reset frame")

// Setup import and export.
let exchange = tmp.appendingPathComponent("exchange")
try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
var shared = Setup(); shared[.FF] = 42
let sharedFile = exchange.appendingPathComponent("shared.json")
try Store.exportSetup(shared, to: sharedFile)
check(try Store.importSetup(from: sharedFile) == shared, "setup file round-trip")
let notJSON = exchange.appendingPathComponent("note.json")
try Data("hello".utf8).write(to: notJSON)
check(throwsError { _ = try Store.importSetup(from: notJSON) }, "refuses a file that isn't a setup")
let emptyFile = exchange.appendingPathComponent("empty.json")
try Data("{}".utf8).write(to: emptyFile)
check(throwsError { _ = try Store.importSetup(from: emptyFile) }, "refuses a file with missing settings")
var outOfRange = Setup(); outOfRange[.FF] = 500
let badValue = exchange.appendingPathComponent("bad.json")
try Store.exportSetup(outOfRange, to: badValue)
check(throwsError { _ = try Store.importSetup(from: badValue) }, "refuses out-of-range values")
let huge = exchange.appendingPathComponent("huge.json")
try Data(repeating: 0x20, count: 70_000).write(to: huge)
check(throwsError { _ = try Store.importSetup(from: huge) }, "refuses an oversized file")

let atRest = MouseStick.velocity(rx: -1, ry: 0, speed: 800)
check(atRest.x == 0 && atRest.y == 0, "joystick at rest doesn't move the cursor")
check(MouseStick.velocity(rx: 0, ry: -128, speed: 800).y == -800, "joystick up moves the cursor up, at full speed")
check(MouseStick.velocity(rx: 127, ry: 0, speed: 800).x == -800, "joystick left moves the cursor left")
check(abs(MouseStick.velocity(rx: 30, ry: 0, speed: 800).x) < 40, "small moves stay slow")

print("\(count - failures)/\(count) checks passed")
exit(failures == 0 ? 0 : 1)
