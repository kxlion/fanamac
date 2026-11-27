// Moves the cursor with the rim's joystick. Nothing is sent to the base. macOS has
// to allow it once, in the Accessibility settings.

import AppKit
import ApplicationServices

@MainActor
final class MouseEmulation: ObservableObject {
    @Published private(set) var isOn = false
    @Published var speed = UserDefaults.standard.object(forKey: "mouseSpeed") as? Double ?? 800 {
        didSet { UserDefaults.standard.set(speed, forKey: "mouseSpeed") }
    }
    var input: () -> InputReport? = { nil }

    private static let rate = 60.0
    private var timer: Timer?
    private var pressed = false
    private var carry = CGPoint.zero  // the part of a point not moved yet

    /// false: macOS doesn't allow FanaMac to move the cursor yet.
    func set(_ on: Bool) -> Bool {
        guard on else {
            timer?.invalidate()
            timer = nil
            isOn = false
            release()
            return true
        }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else { return false }
        guard timer == nil else { return true }
        let t = Timer(timeInterval: 1 / Self.rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes: keeps working while a menu is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        isOn = true
        return true
    }

    private func tick() {
        guard let r = input(), let here = CGEvent(source: nil)?.location else {
            release()
            return
        }
        let press = r.buttons.contains(MouseStick.clickButton)
        if press != pressed {
            pressed = press
            post(press ? .leftMouseDown : .leftMouseUp, at: here)
        }
        let v = MouseStick.velocity(rx: r.axes[.Rx] ?? 0, ry: r.axes[.Ry] ?? 0, speed: speed)
        carry.x += v.x / Self.rate
        carry.y += v.y / Self.rate
        let dx = carry.x.rounded(.towardZero), dy = carry.y.rounded(.towardZero)
        carry.x -= dx
        carry.y -= dy
        if dx != 0 || dy != 0 {
            post(pressed ? .leftMouseDragged : .mouseMoved, at: CGPoint(x: here.x + dx, y: here.y + dy))
        }
    }

    private func release() {
        guard pressed, let here = CGEvent(source: nil)?.location else { return }
        pressed = false
        post(.leftMouseUp, at: here)
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
