import Darwin
import Foundation
import os

enum MCPPortAllocatorError: Error, LocalizedError {
    case rangeExhausted(ClosedRange<UInt16>)

    var errorDescription: String? {
        switch self {
        case .rangeExhausted(let range):
            return String(
                format: String(localized: "No free port in range %d-%d"),
                Int(range.lowerBound),
                Int(range.upperBound)
            )
        }
    }
}

enum MCPPortAllocator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPPortAllocator")

    static func findFreePort(in range: ClosedRange<UInt16>) throws -> UInt16 {
        for port in range where probe(port: port) {
            return port
        }
        logger.error("Port allocator exhausted range \(range.lowerBound)-\(range.upperBound)")
        throw MCPPortAllocatorError.rangeExhausted(range)
    }

    static func isFree(port: UInt16) -> Bool {
        probe(port: port)
    }

    private static func probe(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
