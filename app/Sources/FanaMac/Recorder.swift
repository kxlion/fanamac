// Records what goes through FanaMac during a force test, for analysis
// afterwards: the plug-in's packets, every frame written to the base, and the
// wheel position. Off unless FanaMac is started with FANAMAC_RECORD set to a
// file path:
//
//   open --env FANAMAC_RECORD=/path/to/record.txt build/FanaMac.app
//
// One line per event, time in milliseconds since FanaMac started:
//   <ms> pkt <seq> <active> <level> | <spring 5 values> | <damper 5 values>
//   <ms> out <frame bytes in hex>
//   <ms> in <tuning report bytes in hex>
//   <ms> x <wheel position 0 … 65535>      (only when it changes)
//   <ms> c <hat and buttons, then Rx Ry Slider Dial, in hex>   (only when it changes)
//
// Empty the file between two tests (: > record.txt); analyse it with
// `fanamac record record.txt`.

import Foundation

final class Recorder: @unchecked Sendable {
    static let shared = Recorder()

    private let queue = DispatchQueue(label: "fanamac.recorder", qos: .utility)
    private let file: FileHandle?
    private let start = ProcessInfo.processInfo.systemUptime
    private var lastX = -1  // touched only on `queue`
    private var lastControls: [UInt8] = []  // same

    private init() {
        guard let path = ProcessInfo.processInfo.environment["FANAMAC_RECORD"], !path.isEmpty else { file = nil; return }
        FileManager.default.createFile(atPath: path, contents: nil)
        file = FileHandle(forWritingAtPath: path)
    }

    var isOn: Bool { file != nil }

    func packet(_ p: ForcePacket) {
        guard isOn else { return }
        let c = p.command
        func slot(_ s: ConditionSlot) -> String {
            [s.offset, s.deadband, s.posCoeff, s.negCoeff, s.saturation].map { String(format: "%.4f", $0) }.joined(separator: " ")
        }
        line("pkt \(p.sequence) \(p.active ? 1 : 0) \(String(format: "%.5f", c.level)) | \(slot(c.spring)) | \(slot(c.damper))")
    }

    func frame(_ f: [UInt8]) {
        guard isOn else { return }
        line("out " + f.map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    /// Tuning reports are kept whole. Input report 0x01: the wheel position is bytes 17-18.
    func input(_ bytes: [UInt8]) {
        guard isOn else { return }
        if bytes.first == 0xFF {
            line("in " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
            return
        }
        guard bytes.count >= 19, bytes[0] == 0x01 else { return }
        let x = Int(bytes[17]) | Int(bytes[18]) << 8
        let controls = bytes.count >= 29 ? Array(bytes[1...16] + bytes[25...28]) : []
        let t = now()
        queue.async {
            if controls != self.lastControls {
                self.lastControls = controls
                self.write(t, "c " + controls.map { String(format: "%02x", $0) }.joined())
            }
            guard x != self.lastX else { return }
            self.lastX = x
            self.write(t, "x \(x)")
        }
    }

    private func now() -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }

    private func line(_ text: String) {
        let t = now()
        queue.async { self.write(t, text) }
    }

    private func write(_ t: Double, _ text: String) {
        // Always at the end, so the file can be emptied between two tests.
        file?.seekToEndOfFile()
        file?.write(Data((String(format: "%.2f ", t) + text + "\n").utf8))
    }
}
