//
//  LibPQTypeNameRegistry.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProPostgreSQLCore

// Read and written both on the connection's queue and off it, so it carries a lock of its own. An oid learned as
// unresolved counts as learned, so the catalog is not asked about it again.
final class LibPQTypeNameRegistry: Sendable {
    private struct State {
        var learnedNames: [UInt32: String] = [:]
        var postgisTypes: [UInt32: String] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var postgisTypes: [UInt32: String] {
        state.withLock { $0.postgisTypes }
    }

    func setPostgisTypes(_ types: [UInt32: String]) {
        state.withLock { $0.postgisTypes = types }
    }

    func merge(_ names: [UInt32: String]) {
        state.withLock { $0.learnedNames.merge(names) { _, learned in learned } }
    }

    func name(for oid: UInt32) -> String {
        let learned = state.withLock { $0.learnedNames[oid] }
        return learned
            ?? PostgreSQLCatalogTypeNames.builtinTypeName(for: oid)
            ?? PostgreSQLCatalogTypeNames.unresolved
    }

    func name(for oid: UInt32, modifier: Int32) -> String {
        PgvectorTypes.spelling(of: name(for: oid), modifier: modifier)
    }

    func unresolvedOids(in oids: [UInt32]) -> [UInt32] {
        state.withLock { state in
            oids.filter { state.learnedNames[$0] == nil && PostgreSQLCatalogTypeNames.builtinTypeName(for: $0) == nil }
        }
    }
}
