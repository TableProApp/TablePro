//
//  MySQLServerGreeting.swift
//  TablePro
//

import Foundation
import Network
import os

// MariaDB's client tools on Preferred fall back to plaintext when the server offers no TLS, and still send the typed
// password when caching_sha2_password asks for full authentication. Reading the server's greeting first, which carries
// no credentials, lets the dump pick TLS or plaintext up front instead.
enum MySQLServerGreeting {
    private static let clientSSL: UInt16 = 0x0800
    private static let errorPacket: UInt8 = 0xFF
    private static let queue = DispatchQueue(label: "com.TablePro.MySQLServerGreeting", qos: .userInitiated)

    // Nil when the server cannot be read, which a caller treats as no TLS.
    static func offersTLS(host: String, port: Int, deadline: Duration = .seconds(10)) async -> Bool? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let answer: Bool? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let complete: @Sendable (Bool?) -> Void = { value in
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
                    readGreeting(from: connection, complete: complete)
                case .failed, .cancelled, .waiting:
                    complete(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + deadline.timeInterval) { complete(nil) }
        }
        return answer
    }

    static func offersTLS(greeting payload: [UInt8]) -> Bool? {
        guard let protocolVersion = payload.first, protocolVersion != errorPacket else { return nil }
        guard let versionEnd = payload.dropFirst().firstIndex(of: 0) else { return nil }
        // Thread id (4), the first part of the scramble (8) and a filler byte sit before the capability flags.
        let flagsStart = versionEnd + 1 + 4 + 8 + 1
        guard payload.count >= flagsStart + 2 else { return nil }
        let flags = UInt16(payload[flagsStart]) | UInt16(payload[flagsStart + 1]) << 8
        return flags & clientSSL != 0
    }

    private static func readGreeting(from connection: NWConnection, complete: @escaping @Sendable (Bool?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard error == nil, let header, header.count == 4 else {
                complete(nil)
                return
            }
            let length = Int(header[header.startIndex])
                | Int(header[header.startIndex + 1]) << 8
                | Int(header[header.startIndex + 2]) << 16
            guard length > 0 else {
                complete(nil)
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { payload, _, _, error in
                guard error == nil, let payload, payload.count == length else {
                    complete(nil)
                    return
                }
                complete(offersTLS(greeting: Array(payload)))
            }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
