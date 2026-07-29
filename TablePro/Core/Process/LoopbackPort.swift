//
//  LoopbackPort.swift
//  TablePro
//

import Darwin
import Foundation
import Network
import os

enum LoopbackPort {
    static func allocateFree() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    static func isReachable(host: String, port: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let complete: (Bool) -> Void = { value in
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard shouldResume else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(true)
                case .failed, .cancelled, .waiting:
                    complete(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }
}
