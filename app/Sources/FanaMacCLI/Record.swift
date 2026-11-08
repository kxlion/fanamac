// Analyses a recording made by FanaMac (FANAMAC_RECORD, see Recorder.swift).
// Reads the frames the way the base reads them and sums up what happened.

import Foundation

enum Record {
    struct Decoded: Equatable {
        var kind: String
        var level: Double?    // constant force
        var detail: String?   // spring or damper settings, nil when switched off
    }

    private struct Packet {
        var t: Double, level: Double, spring: [Double], damper: [Double]
    }

    private typealias Sample = (t: Double, value: Double)

    /// Reads one 8-byte force frame.
    static func decode(_ f: [UInt8]) -> Decoded {
        guard f.count == 8, f[0] == 0x01 else { return Decoded(kind: "other") }
        if f[1] == 0xF3 { return Decoded(kind: "stop all") }
        let slot = f[1] >> 4, off = f[1] & 0x02 != 0
        switch (slot, f[2]) {
        case (0, 0x08):
            let raw = Int(f[3]) | Int(f[4]) << 8
            return Decoded(kind: "constant", level: off ? 0 : Double(0x8000 - raw) / 0x7FFF)
        case (1, 0x0B):
            return Decoded(kind: "spring", detail: off ? nil :
                "edges (\(f[3]), \(f[4])), stiffness + \(f[5] >> 4), stiffness − \(f[5] & 0x0F), max \(f[7])")
        case (2, 0x0C):
            return Decoded(kind: "damper", detail: off ? nil : "coeff + \(f[5]), coeff − \(f[3]), max \(f[7])")
        default:
            return Decoded(kind: "other")
        }
    }

    /// Main frequency (Hz) of a series: crossings of its moving average, with a
    /// little hysteresis. nil when there is too little data.
    private static func frequency(_ samples: [Sample], windowMs w: Int = 200) -> Double? {
        guard samples.count >= 4, let t0 = samples.first?.t, let t1 = samples.last?.t, t1 - t0 >= Double(2 * w) else { return nil }
        // Each value holds until the next change, on a 1 ms grid.
        var grid: [Double] = []
        var j = 0
        for ms in Int(t0)..<Int(t1) {
            while j + 1 < samples.count, samples[j + 1].t <= Double(ms) { j += 1 }
            grid.append(samples[j].value)
        }
        guard let low = grid.min(), let high = grid.max(), high > low else { return nil }
        let half = w / 2
        let hysteresis = (high - low) * 0.1
        var crossings: [Int] = []
        var state = 0
        var sum = grid[..<w].reduce(0, +)
        for i in half..<(grid.count - half) {
            let d = grid[i] - sum / Double(w)
            let s = d > hysteresis ? 1 : d < -hysteresis ? -1 : 0
            if s != 0, s != state {
                if state != 0 { crossings.append(i) }
                state = s
            }
            if i + half < grid.count { sum += grid[i + half] - grid[i - half] }
        }
        guard crossings.count >= 3 else { return nil }
        // Two crossings per period.
        return Double(crossings.count - 1) / 2 / (Double(crossings.last! - crossings[0]) / 1000)
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func f(_ format: String, _ value: Double) -> String { String(format: format, value) }

    static func summary(_ text: String) -> [String] {
        var packets: [Packet] = []
        var frames: [(t: Double, bytes: [UInt8])] = []
        var positions: [Sample] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let t = Double(parts[0]) else { continue }
            switch parts[1] {
            case "pkt":
                let n = parts[2...].filter { $0 != "|" }.compactMap { Double($0) }
                if n.count == 13 { packets.append(Packet(t: t, level: n[2], spring: Array(n[3..<8]), damper: Array(n[8..<13]))) }
            case "out":
                frames.append((t, parts[2...].compactMap { UInt8($0, radix: 16) }))
            case "x":
                if let x = Double(parts[2]) { positions.append((t, x)) }
            default:
                break
            }
        }
        if packets.isEmpty, frames.isEmpty, positions.isEmpty {
            return ["Empty recording: was FanaMac started with FANAMAC_RECORD?"]
        }

        var out: [String] = []
        if let first = packets.first, let last = packets.last {
            let span = (last.t - first.t) / 1000
            let levels = packets.map(\.level)
            let (low, high) = (levels.min()!, levels.max()!)
            out.append("Force packets: \(packets.count) in \(f("%.2f", span)) s"
                + (span > 0 ? " (\(f("%.0f", Double(packets.count) / span)) per second)" : ""))
            out.append("  requested force: \(f("%+.3f", low)) … \(f("%+.3f", high))")
            let sp = packets.max { $0.spring[4] < $1.spring[4] }!.spring
            if sp[4] > 0 {
                out.append("  requested spring: stiffness +\(f("%.3f", sp[2])) / −\(f("%.3f", sp[3])), max \(f("%.3f", sp[4])), centre \(f("%+.3f", sp[0])), deadband \(f("%.3f", sp[1]))")
            }
            let dp = packets.max { $0.damper[4] < $1.damper[4] }!.damper
            if dp[4] > 0 {
                out.append("  requested damper: coeff +\(f("%.3f", dp[2])) / −\(f("%.3f", dp[3])), max \(f("%.3f", dp[4]))")
            }
            if let hz = frequency(packets.map { ($0.t, $0.level) }), high - low > 0.001 {
                out.append("  the requested force oscillates at \(f("%.1f", hz)) Hz")
            }
        } else {
            out.append("No force packets.")
        }

        if !frames.isEmpty {
            var kinds: [String] = []
            var byKind: [String: [(t: Double, decoded: Decoded)]] = [:]
            for (t, bytes) in frames {
                let d = decode(bytes)
                if byKind[d.kind] == nil { kinds.append(d.kind) }
                byKind[d.kind, default: []].append((t, d))
            }
            out.append("Frames sent to the base: \(frames.count)")
            for kind in kinds {
                let items = byKind[kind]!
                var line = "  \(kind): \(items.count)"
                if kind == "constant" {
                    let levels = items.map { $0.decoded.level ?? 0 }
                    let (low, high) = (levels.min()!, levels.max()!)
                    line += ", level \(f("%+.3f", low)) … \(f("%+.3f", high))"
                    if let hz = frequency(items.map { ($0.t, $0.decoded.level ?? 0) }), high - low > 0.001 {
                        line += ", oscillates at \(f("%.1f", hz)) Hz"
                    }
                } else if kind == "spring" || kind == "damper" {
                    var seen: [String] = []
                    for item in items {
                        let s = item.decoded.detail ?? "off"
                        if !seen.contains(s) { seen.append(s) }
                    }
                    line += " — " + seen.joined(separator: " | ")
                }
                out.append(line)
            }
            var delays: [Double] = []
            var j = 0
            for p in packets {
                while j < frames.count, frames[j].t < p.t { j += 1 }
                if j < frames.count, frames[j].t - p.t < 50 { delays.append(frames[j].t - p.t) }
            }
            if !delays.isEmpty {
                out.append("  packet to frame delay: median \(f("%.2f", median(delays))) ms, max \(f("%.2f", delays.max()!)) ms")
            }
        } else {
            out.append("No frames sent to the base.")
        }

        if !positions.isEmpty {
            let values = positions.map(\.value)
            let (low, high) = (values.min()!, values.max()!)
            out.append("Wheel position: \(Int(low)) … \(Int(high)) (centre 32768), start \(Int(values[0])), end \(Int(values.last!))")
            if let hz = frequency(positions), high - low > 20 {
                out.append("  the wheel oscillates at \(f("%.1f", hz)) Hz")
            }
        } else {
            out.append("Wheel position: no change recorded.")
        }
        return out
    }
}
