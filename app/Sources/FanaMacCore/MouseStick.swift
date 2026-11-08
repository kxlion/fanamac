// The rim's joystick as a mouse. Axes Rx and Ry of the input report, recorded on a
// ClubSport Steering Wheel RS: both span -128 to 127 and rest at -1 and 0.

import Foundation

enum MouseStick {
    static let clickButton = 26
    private static let deadZone = 8.0

    /// Cursor speed in points per second, `speed` at full travel. Up is Ry -128,
    /// left is Rx 127; on screen, y goes down. Squared so small moves stay precise.
    static func velocity(rx: Int, ry: Int, speed: Double) -> (x: Double, y: Double) {
        let x = Double(rx), y = Double(ry)
        let size = (x * x + y * y).squareRoot()
        guard size > deadZone else { return (0, 0) }
        let travel = min((size - deadZone) / (127 - deadZone), 1)
        let scale = speed * travel * travel / size
        return (-x * scale, y * scale)
    }
}
