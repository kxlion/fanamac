// Listens on 127.0.0.1 for the plug-in's force packets. Loopback only: nothing
// from the network can drive the wheel.

import Darwin
import Foundation

final class ForceListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fanamac.force-listener", qos: .userInteractive)
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1

    /// Called on the listener's queue for each valid packet.
    var onPacket: ((ForcePacket) -> Void)?

    /// Returns false if the port is taken (another app already listens).
    func start() -> Bool {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ForcePacket.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(fd); fd = -1; return false }
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.read() }
        s.resume()
        source = s
        return true
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 64)
        while true {
            let n = recv(fd, &buf, buf.count, MSG_DONTWAIT)
            guard n > 0 else { return }
            if let p = ForcePacket(bytes: Array(buf[0..<n])) { onPacket?(p) }
        }
    }
}
