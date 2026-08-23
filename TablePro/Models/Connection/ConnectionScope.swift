//
//  ConnectionScope.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One dimension of what a connection is currently browsing, as the toolbar presents it.
///
/// The label and the chooser both come from `kind`, so a component can never describe one scope
/// while acting on another. That split is what shipped as a chip reading "Schema: public" whose
/// click opened the database list (#2196).
internal struct ConnectionScopeComponent: Equatable, Identifiable {
    internal let kind: ContainerSwitchTarget
    internal let name: String
    internal let label: String
    internal let isSwitchable: Bool

    internal var id: String {
        switch kind {
        case .database: "database\u{1}\(name)"
        case .schema: "schema\u{1}\(name)"
        }
    }
}

internal enum ConnectionScopeResolver {
    /// Builds the ordered components from plain values, so every engine is testable without a
    /// plugin registry or a live connection.
    ///
    /// `switchable` arrives already reduced from the plugin capabilities. An engine that switches
    /// nothing still gets one component, because the chip has always shown what a file-based or
    /// single-container connection is browsing and taking that away would be the same regression
    /// this resolver exists to fix.
    internal static func components(
        switchable: [ContainerSwitchTarget],
        groupingStrategy: GroupingStrategy,
        currentDatabase: String,
        currentSchema: String?,
        containerEntityName: String,
        schemaEntityName: String
    ) -> [ConnectionScopeComponent] {
        let kinds = switchable.isEmpty
            ? [staticDisplayKind(groupingStrategy: groupingStrategy, currentSchema: currentSchema)]
            : switchable

        let resolved = kinds.compactMap { kind in
            component(
                kind: kind,
                currentDatabase: currentDatabase,
                currentSchema: currentSchema,
                containerEntityName: containerEntityName,
                schemaEntityName: schemaEntityName,
                isSwitchable: !switchable.isEmpty
            )
        }
        guard resolved.isEmpty else { return resolved }

        /// A schema-only engine has nothing to name until its schema resolves, and a chip that
        /// disappears reads as a connection that lost its place. Fall back to the database it is
        /// on, without offering to switch a dimension this engine cannot switch.
        guard let fallback = component(
            kind: .database,
            currentDatabase: currentDatabase,
            currentSchema: currentSchema,
            containerEntityName: containerEntityName,
            schemaEntityName: schemaEntityName,
            isSwitchable: false
        ) else { return [] }
        return [fallback]
    }

    private static func component(
        kind: ContainerSwitchTarget,
        currentDatabase: String,
        currentSchema: String?,
        containerEntityName: String,
        schemaEntityName: String,
        isSwitchable: Bool
    ) -> ConnectionScopeComponent? {
        let name = switch kind {
        case .database: currentDatabase
        case .schema: currentSchema ?? ""
        }
        guard !name.isEmpty else { return nil }
        let label = switch kind {
        case .database: containerEntityName
        case .schema: schemaEntityName
        }
        return ConnectionScopeComponent(kind: kind, name: name, label: label, isSwitchable: isSwitchable)
    }

    /// What a connection that switches nothing still displays. A schema-grouped engine that has
    /// resolved a schema shows it; everything else shows the database, which is what a file-based
    /// connection has.
    private static func staticDisplayKind(
        groupingStrategy: GroupingStrategy,
        currentSchema: String?
    ) -> ContainerSwitchTarget {
        guard groupingStrategy == .bySchema, let currentSchema, !currentSchema.isEmpty else {
            return .database
        }
        return .schema
    }
}
