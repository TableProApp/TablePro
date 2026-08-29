//
//  ObjectCopyEligibility.swift
//  TablePro
//
//  Why a copy cannot run.
//
//  The rules are pure so the sheet can say no at selection time rather than
//  after the user has filled in a form and pressed Copy. What a driver can
//  actually do is asked of the driver, never inferred: the first version keyed
//  the menu on the editor language, which is `.sql` for DynamoDB's PartiQL and
//  for Cassandra's CQL, so both offered a command that failed while planning.
//

import Foundation
import TableProPluginKit

internal enum ObjectCopyEligibility {
    /// Whether this engine can take part at all.
    ///
    /// Both halves of a copy are SQL: the DDL comes from `generateCreateTableSQL` and the rows go
    /// through `SQLStatementGenerator`, the same writer CSV and JSON import use. An engine whose
    /// query language is not SQL has neither, so the commands are omitted rather than offered and
    /// then refused. This is a necessary condition, not a sufficient one: the planner asks the
    /// driver itself before generating anything.
    internal static func supportsCopying(editorLanguage: EditorLanguage) -> Bool {
        editorLanguage == .sql
    }

    /// Whether the Duplicate Database command is worth offering at all.
    ///
    /// Deliberately optimistic, and paired with a refusal that is not. Whether a driver can create
    /// a database is only knowable by asking it, which a contextual menu cannot do while it is
    /// being built, so the menu answers from what it has and the sheet names the engine that
    /// cannot when its create-database form comes back empty. That is the shape Compare & Sync
    /// already uses for its own gate: a command the user might be able to run stays visible, and
    /// choosing it explains what it needs.
    internal static func mayOfferDuplicateDatabase(
        editorLanguage: EditorLanguage,
        supportsDatabaseSwitching: Bool,
        isReadOnly: Bool
    ) -> Bool {
        supportsCopying(editorLanguage: editorLanguage) && supportsDatabaseSwitching && !isReadOnly
    }

    /// The one refusal the user cannot work around by choosing differently, so it is checked first.
    internal static func targetRefusal(_ target: DatabaseEndpoint) -> String? {
        target.ineligibleAsTargetReason
    }

    /// A copy stays inside one engine, whatever half of an object it carries.
    ///
    /// Structure cannot cross because column data types are driver-native strings. Data cannot
    /// cross either, and the first version let it: the row writer emits `INSERT … VALUES` and a
    /// MongoDB or Elasticsearch target parses neither, while a SQL Server `dbo` source handed a
    /// MySQL target a schema that engine does not have. Comparing the two remains available in
    /// Compare & Sync, which reads rather than writes.
    internal static func engineRefusal(from source: DatabaseType, to target: DatabaseType) -> String? {
        guard !CompareSyncEngineFamily.canGenerateStructureScript(from: source, to: target) else { return nil }
        return String(
            format: String(localized: "%1$@ cannot be copied to %2$@. Choose a target of the same type."),
            source.rawValue, target.rawValue
        )
    }

    /// A source object and a target object that are the same object.
    ///
    /// Copying a table onto itself either drops the rows it is about to read or doubles them, and
    /// which of the two depends on a policy the user picked for every object at once.
    internal static func sameObjectRefusal(
        source: DatabaseEndpoint,
        target: DatabaseEndpoint
    ) -> String? {
        guard source.id == target.id else { return nil }
        return String(localized: "The source and the target are the same database. Choose a different target.")
    }

    /// Whether a view, routine or trigger can be copied as it stands.
    ///
    /// Its definition is the source's own SQL text, and nothing here parses it, so every object it
    /// names stays qualified the way the source qualified it. Run against a different namespace it
    /// either recreates the object pointing back at the source or, for a replacement, drops the
    /// source's own. Copying one is sound only where both sides share a namespace: the same schema
    /// name on PostgreSQL, which a duplicate keeps, and never across two MySQL databases, whose
    /// DDL carries the database name.
    internal static func canCopyDefinition(sourceNamespace: String?, targetNamespace: String?) -> Bool {
        ObjectCopyNamespace.isSame(sourceNamespace, targetNamespace)
    }

    internal static var definitionNamespaceRefusal: String {
        String(
            localized: "Its definition names the source's own database or schema, so it is only copied where that name is the same."
        )
    }

    /// A definition the driver reports as a bare body rather than as a statement.
    ///
    /// ClickHouse, Oracle, Dameng and BigQuery answer `fetchViewDefinition` with the view's SELECT,
    /// not its `CREATE`. Executing that runs a read, which the runner would then report as the view
    /// copied, after Replace had already dropped the target's.
    internal static func isExecutableDefinition(_ definition: String) -> Bool {
        definition
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .hasPrefix("CREATE")
    }

    internal static var definitionNotExecutableRefusal: String {
        String(localized: "This driver reports its body rather than a statement that recreates it.")
    }
}
