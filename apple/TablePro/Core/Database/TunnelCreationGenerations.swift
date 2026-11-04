//
//  TunnelCreationGenerations.swift
//  TablePro
//

import Foundation

// A manager's createTunnel suspends while it dials, so two calls for one connection interleave; only the newest adopts.
internal struct TunnelCreationGenerations: Sendable {
    private var lastIssued: UInt64 = 0
    private var newest: [UUID: UInt64] = [:]

    internal mutating func begin(_ connectionId: UUID) -> UInt64 {
        lastIssued &+= 1
        newest[connectionId] = lastIssued
        return lastIssued
    }

    internal func isNewest(_ generation: UInt64, for connectionId: UUID) -> Bool {
        newest[connectionId] == generation
    }

    internal mutating func finish(_ generation: UInt64, for connectionId: UUID) {
        guard newest[connectionId] == generation else { return }
        newest[connectionId] = nil
    }

    internal mutating func invalidate(_ connectionId: UUID) {
        newest[connectionId] = nil
    }

    internal mutating func invalidateAll() {
        newest.removeAll()
    }
}
