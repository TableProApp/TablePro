//
//  ReadOnlyEnforcement.swift
//  TablePro
//

import Foundation

// What stands behind Read Only for external clients on an engine. Curated per type in PluginMetadataRegistry.
enum ReadOnlyEnforcement: Sendable, Equatable {
    case engineEnforced
    case sessionDefault
    case loginPrivileges
    case clientGuard

    init(_ capabilities: PluginMetadataSnapshot.CapabilityFlags) {
        self = capabilities.isEngineReadOnly ? .engineEnforced : capabilities.readOnlyEnforcement
    }

    // A live driver that cannot run a statement read-only, an older plugin or a flavour that drops the mode, leaves
    // only the login behind Read Only. An engine that cannot write at all needs no help from its driver.
    init(_ capabilities: PluginMetadataSnapshot.CapabilityFlags, liveDriverRunsReadOnly: Bool?) {
        self.init(capabilities)
        guard liveDriverRunsReadOnly == false, !capabilities.isEngineReadOnly else { return }
        switch self {
        case .engineEnforced, .sessionDefault:
            self = .loginPrivileges
        case .loginPrivileges, .clientGuard:
            break
        }
    }

    init(for databaseType: DatabaseType, liveDriverRunsReadOnly: Bool? = nil) {
        guard let snapshot = PluginMetadataRegistry.shared.snapshot(for: databaseType) else {
            self = .loginPrivileges
            return
        }
        self.init(snapshot.capabilities, liveDriverRunsReadOnly: liveDriverRunsReadOnly)
    }

    static func externalClientsNote(for databaseType: DatabaseType, liveDriverRunsReadOnly: Bool? = nil) -> String {
        ReadOnlyEnforcement(for: databaseType, liveDriverRunsReadOnly: liveDriverRunsReadOnly)
            .externalClientsNote(engine: PluginManager.registryDisplayName(of: databaseType))
    }

    func externalClientsNote(engine: String) -> String {
        switch self {
        case .engineEnforced:
            return String(
                format: String(localized: "%@ refuses changes from external clients on this connection."),
                engine
            )
        case .sessionDefault:
            return String(
                format: String(
                    localized: """
                    Statements from external clients run in a read-only transaction, but %@ still allows some \
                    changes. Use a login that can only read.
                    """
                ),
                engine
            )
        case .loginPrivileges:
            return String(
                format: String(
                    localized: "Read Only depends on the login: %@ has no read-only mode. Use a login that can only read."
                ),
                engine
            )
        case .clientGuard:
            return String(
                format: String(
                    localized: """
                    Read Only depends on the login: %@ has no read-only mode, and TablePro refuses commands that \
                    write. Use a user that can only read.
                    """
                ),
                engine
            )
        }
    }
}
