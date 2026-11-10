import Darwin
import Foundation

// The test process holds a driver's end of its connection, so a session socket's options are read off it.
enum SessionSocketProbe {
    struct Keepalive: Equatable {
        let enabled: Bool
        let idleSeconds: Int32
        let intervalSeconds: Int32
        let probeCount: Int32
    }

    static let expected = Keepalive(enabled: true, idleSeconds: 60, intervalSeconds: 10, probeCount: 3)

    static func clientSocket(connectedTo port: Int) -> Int32? {
        (0..<getdtablesize()).first { descriptor in
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &length) }
            }
            return named == 0 && address.sin_family == sa_family_t(AF_INET) && Int(address.sin_port.bigEndian) == port
        }
    }

    static func keepalive(_ socket: Int32) -> Keepalive {
        Keepalive(
            enabled: intOption(socket, SOL_SOCKET, SO_KEEPALIVE) != 0,
            idleSeconds: intOption(socket, IPPROTO_TCP, TCP_KEEPALIVE),
            intervalSeconds: intOption(socket, IPPROTO_TCP, TCP_KEEPINTVL),
            probeCount: intOption(socket, IPPROTO_TCP, TCP_KEEPCNT)
        )
    }

    static func receiveTimeout(_ socket: Int32) -> Double {
        var timeout = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        getsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, &length)
        return Double(timeout.tv_sec) + Double(timeout.tv_usec) / 1_000_000
    }

    private static func intOption(_ socket: Int32, _ level: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socket, level, name, &value, &length)
        return value
    }
}
