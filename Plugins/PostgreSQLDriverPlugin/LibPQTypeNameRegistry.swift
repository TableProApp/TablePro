//
//  LibPQTypeNameRegistry.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os

/// The type names one connection has learned and the PostGIS types its probe found. The connection's
/// queue reads them while a result arrives and the driver writes them from its own task, so they
/// carry a lock of their own. A learned name wins over the built-in table, and an oid neither knows is
/// `PostgreSQLCatalogTypeNames.unresolved`. An oid learned as unresolved counts as learned, so the
/// catalog is asked about it once.
final class LibPQTypeNameRegistry: Sendable {
    private struct State {
        var learnedNames: [UInt32: String] = [:]
        var postgisTypes: [UInt32: PostGISType] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var postgisTypes: [UInt32: PostGISType] {
        state.withLock { $0.postgisTypes }
    }

    func setPostgisTypes(_ types: [UInt32: PostGISType]) {
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

    func unresolvedOids(in oids: [UInt32]) -> [UInt32] {
        state.withLock { state in
            oids.filter { state.learnedNames[$0] == nil && PostgreSQLCatalogTypeNames.builtinTypeName(for: $0) == nil }
        }
    }
}
