//
//  MySQLServerGreeting.swift
//  TablePro
//

import Foundation
import Network
import os

// MariaDB's client tools on Preferred fall back to plaintext when the server offers no TLS, and still send the typed
// password when caching_sha2_password asks for full authentication. Reading the server's greeting first, which carries
// no credentials, lets the dump pick TLS or plaintext up front instead. The greeting comes from the endpoint the tool
// dials, so a proxy answers for its own front end. Measured with max_connect_errors=1 and name resolution on, MySQL
// 8.4 and MariaDB 11.4 count a connection closed after the greeting as aborted, never as a blocking host error.
enum MySQLServerGreeting {
    enum Answer: Equatable, Sendable {
        case offersTLS(Bool)
        case serverError(String)
        case unreadable
    }

    private static let clientSSL: UInt16 = 0x0800
    private static let errorPacket: UInt8 = 0xFF
    private static let queue = DispatchQueue(label: "com.TablePro.MySQLServerGreeting", qos: .userInitiated)

    static func read(host: String, port: Int, deadline: Duration = .seconds(10)) async -> Answer {
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .unreadable }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let complete: @Sendable (Answer) -> Void = { value in
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
                    complete(.unreadable)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            let parts = deadline.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds) { complete(.unreadable) }
        }
    }

    static func answer(greeting payload: [UInt8]) -> Answer {
        guard let first = payload.first else { return .unreadable }
        if first == errorPacket {
            return serverError(payload).map { .serverError($0) } ?? .unreadable
        }
        guard let versionEnd = payload.dropFirst().firstIndex(of: 0) else { return .unreadable }
        // Thread id (4), the first part of the scramble (8) and a filler byte sit before the capability flags.
        let flagsStart = versionEnd + 1 + 4 + 8 + 1
        guard payload.count >= flagsStart + 2 else { return .unreadable }
        let flags = UInt16(payload[flagsStart]) | UInt16(payload[flagsStart + 1]) << 8
        return .offersTLS(flags & clientSSL != 0)
    }

    // A server refusing the connection outright, such as "Too many connections", answers with an error packet in place
    // of the greeting. Before the handshake it carries no SQL state marker.
    private static func serverError(_ payload: [UInt8]) -> String? {
        guard payload.count > 3 else { return nil }
        var message = payload.dropFirst(3)
        if message.first == UInt8(ascii: "#"), message.count >= 6 {
            message = message.dropFirst(6)
        }
        let text = String(bytes: message, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func readGreeting(from connection: NWConnection, complete: @escaping @Sendable (Answer) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard error == nil, let header, header.count == 4 else {
                complete(.unreadable)
                return
            }
            let length = Int(header[header.startIndex])
                | Int(header[header.startIndex + 1]) << 8
                | Int(header[header.startIndex + 2]) << 16
            guard length > 0 else {
                complete(.unreadable)
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { payload, _, _, error in
                guard error == nil, let payload, payload.count == length else {
                    complete(.unreadable)
                    return
                }
                complete(answer(greeting: Array(payload)))
            }
        }
    }
}
