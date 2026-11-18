//
//  LibPQDirectTLS.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os

// Which servers take TLS without the SSLRequest round trip. A server earns it by a connection that reached a version 17
// backend directly over TLS, since a proxy in front of one can report the same version and refuse the handshake. A
// refusal outlives any later proof, so a connect pays for a failed attempt once per endpoint.
final class LibPQDirectTLSMemory: Sendable {
    static let shared = LibPQDirectTLSMemory()
    static let minimumServerVersion: Int32 = 170_000

    struct Endpoint: Hashable, Sendable {
        let host: String
        let port: Int
        let serverName: String?
    }

    private struct State {
        var proven: Set<Endpoint> = []
        var refused: Set<Endpoint> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func allowsDirect(_ endpoint: Endpoint) -> Bool {
        state.withLock { $0.proven.contains(endpoint) && !$0.refused.contains(endpoint) }
    }

    func noteDirectBackend(_ endpoint: Endpoint) {
        _ = state.withLock { $0.proven.insert(endpoint) }
    }

    func noteRefused(_ endpoint: Endpoint) {
        _ = state.withLock { $0.refused.insert(endpoint) }
    }
}

// How far one connect attempt got. Before sign-in starts no credential has left this Mac, so another attempt is safe.
struct LibPQHandshakeProgress: Equatable, Sendable {
    var startedEncryption = false
    var startedSignIn = false

    var refusedDirectTLS: Bool {
        startedEncryption && !startedSignIn
    }
}
