// Runs the force engine against the base, on its own queue so a slow tuning
// read never delays a force frame.

import Foundation

/// Writes a new force right away, resends the constant force 50 times a second
/// while it is on, and cuts everything on quit, on disconnect, on a write
/// error, and when the commands stop coming for a quarter of a second.
final class ForceOutput: @unchecked Sendable {
    static let period: TimeInterval = 0.02

    private let wheelbase: Wheelbase
    private let queue = DispatchQueue(label: "fanamac.force", qos: .userInteractive)
    // Touched only on `queue`.
    private var engine = ForceEngine()
    private var timer: DispatchSourceTimer?
    private var reportedActive = false
    // The newest command not yet applied. A game can send faster than frames
    // are written; only the newest one matters.
    private let lock = NSLock()
    private var latest: ForceCommand?

    /// Main thread: true while the base is producing a force.
    var onActive: ((Bool) -> Void)?
    /// Main thread: a force frame could not be written (the force was cut).
    var onError: ((Error) -> Void)?

    init(wheelbase: Wheelbase) {
        self.wheelbase = wheelbase
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.period, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.write(self.engine.tick(at: Date()))
        }
        t.resume()
        timer = t
    }

    /// The connected base's force format and limit, from its profile.
    func configure(highRes: Bool, cap: Double) {
        queue.async {
            self.cut()
            self.engine.highRes = highRes
            self.engine.cap = cap
        }
    }

    /// Keep calling it: without a new command for 0.25 s everything drops to zero.
    func set(_ command: ForceCommand) {
        lock.lock()
        let queued = latest != nil
        latest = command
        lock.unlock()
        guard !queued else { return }
        queue.async {
            self.lock.lock()
            let c = self.latest
            self.latest = nil
            self.lock.unlock()
            guard let c else { return }
            do { self.write(try self.engine.set(c, at: Date())) }
            catch { self.failed(error) }
        }
    }

    /// For quit: returns once the stop frames are written.
    func stopNow() {
        queue.sync { self.cut() }
    }

    /// The base is gone: nothing to write to, just forget the force.
    func baseGone() {
        queue.async {
            _ = self.engine.stop()
            self.report()
        }
    }

    private func cut() {
        lock.lock(); latest = nil; lock.unlock()
        for frame in engine.stop() {
            Recorder.shared.frame(frame)
            try? wheelbase.writeNow(frame)
        }
        report()
    }

    private func write(_ frames: [[UInt8]]) {
        for frame in frames {
            Recorder.shared.frame(frame)
            do { try wheelbase.writeNow(frame) } catch { failed(error); return }
        }
        report()
    }

    private func failed(_ error: Error) {
        cut()
        DispatchQueue.main.async { self.onError?(error) }
    }

    private func report() {
        let active = engine.isActive
        guard active != reportedActive else { return }
        reportedActive = active
        DispatchQueue.main.async { self.onActive?(active) }
    }
}
