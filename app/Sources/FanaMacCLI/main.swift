// Development tool: reads the base, plays test forces on it and analyses
// FanaMac's recordings. It goes through the app's own force output, safety stop
// included, and never marks the base.
//
//   fanamac monitor [--seconds N]
//   fanamac force [--level 5] [--seconds 1] [--send]
//   fanamac effect spring|damper [--level 20] [--max 20] [--seconds 5] [--send]
//   fanamac record <file>
//   fanamac diagnose [file] [--seconds 10] [--ask-tuning]
//   fanamac ingest <file> [--add]
//
// Without --send, force and effect only print the frames.

import Foundation

let usage = """
    Usage:
      fanamac monitor [--seconds N]        read-only view of axes and buttons
      fanamac force [--level 5] [--seconds 1] [--send]
                                           constant force, one way then the other
      fanamac effect spring|damper [--level 20] [--max 20] [--seconds 5] [--send]
                                           spring or damper played by the base
      fanamac record <file>                analyses a recording (FANAMAC_RECORD)
      fanamac diagnose [file] [--seconds 10] [--ask-tuning]
                                           captures every Fanatec device into a diagnostic
                                           file (default: fanamac-diagnostic.json).
                                           --ask-tuning also asks a base FanaMac doesn't
                                           know for its tuning report
      fanamac ingest <file> [--add]        reads a diagnostic someone sent: what matches,
                                           what doesn't, the profile to try. --add keeps it
                                           in Tests/Fixtures, where the tests replay it
    Without --send, force and effect only print the frames.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func hex(_ frame: [UInt8]) -> String { frame.map { String(format: "%02X", $0) }.joined(separator: " ") }

/// Parses `--name value` numbers and the --send flag; anything unknown is refused.
func parse(_ args: [String], defaults: [String: Double], allowSend: Bool = true) -> (numbers: [String: Double], send: Bool, rest: [String]) {
    var numbers = defaults, send = false, rest: [String] = []
    var it = args.makeIterator()
    while let a = it.next() {
        if a == "--send", allowSend {
            send = true
        } else if a.hasPrefix("--") {
            guard numbers[a] != nil else { fail("Unknown option: \(a)\n\n\(usage)") }
            guard let text = it.next(), let v = Double(text), v.isFinite else { fail("\(a): number expected") }
            numbers[a] = v
        } else {
            rest.append(a)
        }
    }
    return (numbers, send, rest)
}

/// What the main thread and the running command share.
final class Session: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = PeripheralTracker()
    private var stopped = false
    private var error: String?

    func feed(_ r: InputReport) { lock.lock(); tracker.feed(r); lock.unlock() }
    var input: PeripheralTracker { lock.lock(); defer { lock.unlock() }; return tracker }

    var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop(error message: String? = nil) { lock.lock(); stopped = true; error = message ?? error; lock.unlock() }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return error }

    var wheel: Int? { input.latest?.axes[.X] }

    /// Runs until `seconds` have passed or the command is stopped; returns the wheel positions seen.
    func hold(_ seconds: Double, every step: TimeInterval = 0.02, _ tick: () -> Void) -> [Int] {
        var seen: [Int] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !shouldStop {
            tick()
            Thread.sleep(forTimeInterval: step)
            if let x = wheel { seen.append(x) }
        }
        return seen
    }
}

var signalSources: [DispatchSourceSignal] = []

/// Opens the base, then runs `body` away from the main thread, which has to
/// keep delivering the input reports. Ctrl-C ends `body` through `shouldStop`,
/// so the stop frames are always the last thing sent.
func withBase(_ body: @escaping (Wheelbase, Session) -> Void) -> Never {
    let base = Wheelbase(productIDs: BaseCatalog.load().profiles.map(\.productID))
    let session = Session()
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { session.stop() }
        source.resume()
        signalSources.append(source)
    }
    base.onInput = { bytes in if let r = InputReport(bytes: bytes) { session.feed(r) } }
    var started = false
    base.onChange = { info in
        guard info != nil, !started else { return }
        started = true
        // A moment for the base's other interfaces and its first input reports.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.2) {
            body(base, session)
            if let message = session.failure { fail(message) }
            exit(0)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        if !started { fail("No wheelbase found. Is the base on, in PC mode (red LED)? For a base FanaMac doesn't know, run: fanamac diagnose") }
    }
    RunLoop.main.run()
    exit(0)
}

/// Handshake, force output, and everything cut at the end whatever happened.
func withForce(_ body: @escaping (ForceOutput, Session) -> Void) -> Never {
    withBase { base, session in
        do {
            try base.writeNow(TuningProtocol.initReport)
        } catch {
            session.stop(error: "Handshake refused: \(error.localizedDescription)")
            return
        }
        Thread.sleep(forTimeInterval: 0.02)
        let output = ForceOutput(wheelbase: base)
        // An untested base gets its profile's frame format and a capped force.
        if let profile = base.productID.flatMap(BaseCatalog.load().profile(productID:)) {
            if !profile.isTested { print("\(profile.name): untested base, force capped at \(Int(BaseProfile.untestedForceCap * 100)) % of what is asked.") }
            output.configure(highRes: profile.highResForce, cap: profile.forceCap)
        }
        output.onError = { session.stop(error: "Write refused, force cut: \($0.localizedDescription)") }
        body(output, session)
        output.stopNow()
    }
}

func direction(_ seen: [Int]) -> String {
    guard let start = seen.first, let end = seen.last else { return "unknown position" }
    let moved = end - start
    if abs(moved) < 200 { return "not moving (X \(start) → \(end))" }
    return "\(moved > 0 ? "clockwise, to the right" : "anti-clockwise, to the left") (X \(start) → \(end))"
}

func printStop() {
    var engine = ForceEngine()
    print("Stop:      " + engine.stop().map(hex).joined(separator: " | "))
}

func forceTest(_ args: [String]) -> Never {
    let (n, send, rest) = parse(args, defaults: ["--level": 5, "--seconds": 1])
    guard rest.isEmpty, n["--seconds"]! > 0 else { fail(usage) }
    let level = n["--level"]! / 100, seconds = n["--seconds"]!
    guard let clockwise = try? ForceProtocol.constant(level), let other = try? ForceProtocol.constant(-level) else {
        fail("Force \(n["--level"]!) outside −100 … 100 %")
    }
    print("Init:      " + hex(TuningProtocol.initReport))
    print("Clockwise: " + hex(clockwise))
    print("Reverse:   " + hex(other))
    printStop()
    guard send else {
        print("\nDry run: nothing was sent. Add --send, with your hands ready on the wheel.")
        exit(0)
    }
    withForce { output, session in
        for (label, value) in [("clockwise", level), ("reverse", -level)] where !session.shouldStop {
            print("\(label): \(String(format: "%+g", value * 100)) %")
            let seen = session.hold(seconds) { output.set(ForceCommand(level: value)) }
            output.set(.none)
            print("  " + direction(seen))
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("force off")
    }
}

func effectTest(_ args: [String]) -> Never {
    let (n, send, rest) = parse(args, defaults: ["--level": 20, "--max": 20, "--seconds": 5])
    guard rest.count == 1, ["spring", "damper"].contains(rest[0]), n["--seconds"]! > 0 else { fail(usage) }
    let isSpring = rest[0] == "spring"
    guard (0...100).contains(n["--level"]!), (0...100).contains(n["--max"]!) else { fail("--level and --max: 0 to 100 %") }
    let slot = ConditionSlot(posCoeff: n["--level"]! / 100, negCoeff: n["--level"]! / 100, saturation: n["--max"]! / 100)
    let frame = isSpring ? try? ForceProtocol.spring(slot) : try? ForceProtocol.damper(slot)
    let command = isSpring ? ForceCommand(level: 0, spring: slot) : ForceCommand(level: 0, damper: slot)
    print("Init:      " + hex(TuningProtocol.initReport))
    print("Effect:    " + (frame.map(hex) ?? "off (--max 0)"))
    printStop()
    guard send else {
        print("\nDry run: nothing was sent. Add --send, with your hands on the wheel.")
        exit(0)
    }
    withForce { output, session in
        print("\(rest[0]) for \(String(format: "%g", n["--seconds"]!)) s: turn the wheel by hand.")
        let seen = session.hold(n["--seconds"]!) { output.set(command) }
        output.set(.none)
        if let low = seen.min(), let high = seen.max(), let end = seen.last {
            print("X seen: from \(low) to \(high), end \(end) (centre 32768)")
        }
        print("effect off")
    }
}

func monitor(_ args: [String]) -> Never {
    let (n, _, rest) = parse(args, defaults: ["--seconds": 0], allowSend: false)
    guard rest.isEmpty else { fail(usage) }
    withBase { _, session in
        print("Read-only. Move the pedals, handbrake and shifter. Ctrl+C to stop.\n")
        _ = session.hold(n["--seconds"]! > 0 ? n["--seconds"]! : 1e9, every: 0.05) {
            guard let r = session.input.latest else { return }
            let axes = Axis.allCases.map { "\($0.rawValue) \(r.axes[$0] ?? 0)" }.joined(separator: " ")
            let buttons = r.buttons.isEmpty ? "-" : r.buttons.map(String.init).joined(separator: ",")
            print("\r\u{1B}[K\(axes) hat \(r.hat.map(String.init) ?? "-") buttons \(buttons)", terminator: "")
            fflush(stdout)
        }
        let seen = session.input
        guard let last = seen.latest else {
            print("No report received.")
            return
        }
        let moved = Axis.allCases.filter { seen.moved.contains($0) }.map(\.rawValue).joined(separator: ", ")
        print("\n\nAxes that moved: \(moved.isEmpty ? "none" : moved)")
        print("Vendor bytes: " + hex(last.vendor))
        if let rim = last.rimName { print("Rim detected: \(rim)") }
    }
}

/// Takes a flag out of the arguments; true if it was there.
func flag(_ name: String, in args: inout [String]) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func diagnose(_ args: [String]) -> Never {
    var args = args
    let ask = flag("--ask-tuning", in: &args)
    let (n, _, rest) = parse(args, defaults: ["--seconds": 10], allowSend: false)
    guard rest.count <= 1, n["--seconds"]! >= 1, n["--seconds"]! <= 120 else { fail(usage) }
    let url = URL(fileURLWithPath: rest.first ?? "fanamac-diagnostic.json")
    let catalog = BaseCatalog.load()
    print("Recording for \(Int(n["--seconds"]!)) s. Turn the wheel lock to lock, press each pedal fully, press a few buttons.")
    DiagnosticCapture.run(seconds: n["--seconds"]!, catalog: catalog, version: FanaMacVersion.current, askUnknown: ask) { d in
        guard !d.devices.isEmpty else { fail("No Fanatec device found. Is the base on, in PC mode (red LED)?") }
        do { try d.write(to: url) } catch { fail("Cannot write \(url.path): \(error.localizedDescription)") }
        print(DiagnosticReview(d, catalog: catalog).lines.joined(separator: "\n"))
        print("\nSaved \(url.path). No serial number is in it. Attach it to an issue on FanaMac's GitHub page.")
        exit(0)
    }
    RunLoop.main.run()
    exit(0)
}

/// Diagnostics kept as test fixtures: `app/build.sh test` replays them.
let fixtures = URL(fileURLWithPath: "Tests/Fixtures")

func loadFixtures() -> [Diagnostic] {
    let files = (try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { try? Diagnostic.load($0) }
}

func ingest(_ args: [String]) -> Never {
    var args = args
    let add = flag("--add", in: &args)
    guard args.count == 1 else { fail(usage) }
    let d: Diagnostic
    do { d = try Diagnostic.load(URL(fileURLWithPath: args[0])) } catch let error as DiagnosticError { fail("\(args[0]): \(error)") }
    catch { fail("\(args[0]) is not a FanaMac diagnostic.") }
    print("Captured by FanaMac \(d.fanamac) on macOS \(d.macOS), \(Int(d.seconds)) s\n")
    print(DiagnosticReview(d, catalog: BaseCatalog.load(), references: loadFixtures()).lines.joined(separator: "\n"))
    if add {
        guard (try? fixtures.checkResourceIsReachable()) == true else { fail("Run it from the app folder: Tests/Fixtures isn't here.") }
        let target = fixtures.appendingPathComponent(d.fixtureName)
        do { try d.write(to: target) } catch { fail("Cannot write \(target.path): \(error.localizedDescription)") }
        print("\nKept as \(target.path): ./build.sh test now replays it.")
    }
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "monitor": monitor(Array(arguments.dropFirst()))
case "force": forceTest(Array(arguments.dropFirst()))
case "effect": effectTest(Array(arguments.dropFirst()))
case "diagnose": diagnose(Array(arguments.dropFirst()))
case "ingest": ingest(Array(arguments.dropFirst()))
case "record":
    guard arguments.count == 2 else { fail(usage) }
    guard let text = try? String(contentsOfFile: arguments[1], encoding: .utf8) else { fail("Cannot read file: \(arguments[1])") }
    print(Record.summary(text).joined(separator: "\n"))
default:
    fail(usage)
}
