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

    /// A copy stays inside SQL, and inside SQL it may cross engines.
    ///
    /// It could not before, because a column's data type is the source driver's own string and
    /// handing it to another engine's `CREATE TABLE` produced DDL that engine rejects.
    /// `CrossEngineStructureTranslator` is what removed that reason: the types, defaults and
    /// indexes are said in the target's own words before the target driver ever sees them, and
    /// every approximation is listed in the review step.
    ///
    /// What has not changed is the floor. The row writer emits `INSERT … VALUES` and the structure
    /// writer emits `CREATE TABLE`, so an engine whose query language is not SQL parses neither.
    /// Comparing the two remains available in Compare & Sync, which reads rather than writes.
    internal static func engineRefusal(
        from source: DatabaseType,
        to target: DatabaseType,
        sourceLanguage: EditorLanguage,
        targetLanguage: EditorLanguage
    ) -> String? {
        guard supportsCopying(editorLanguage: sourceLanguage),
              supportsCopying(editorLanguage: targetLanguage) else {
            return String(
                format: String(localized: "%1$@ cannot be copied to %2$@. Choose a target that speaks SQL."),
                source.rawValue, target.rawValue
            )
        }
        return crossEngineRefusal(from: source, to: target)
    }

    /// The second half of the gate, and the one the editor language cannot answer.
    ///
    /// `.sql` is what DynamoDB declares for PartiQL and Cassandra for CQL, so the language alone
    /// lets a MySQL to DynamoDB copy through to a planner that can only fail. A crossing is offered
    /// where both engines have a type system `SQLTypeFamily` names, which is the same set the
    /// translation was written and tested against. Within one engine nothing is translated, so an
    /// engine no family names still copies to itself.
    private static func crossEngineRefusal(from source: DatabaseType, to target: DatabaseType) -> String? {
        guard SQLTypeFamily.needsTranslation(from: source, to: target) else { return nil }
        let unnamed = [source, target].filter { SQLTypeFamily.of($0) == .generic }
        guard let first = unnamed.first else { return nil }
        return String(
            format: String(
                localized: "A copy to another engine needs a type system TablePro can translate, and %@ has none it knows. Copy to a target of the same type."
            ),
            first.rawValue
        )
    }

    /// Why a view, routine or trigger cannot cross to another engine.
    ///
    /// Its definition is the source's own SQL text and nothing here parses it, so a MySQL view's
    /// backtick quoting, a PostgreSQL function's `$$` body and a SQL Server trigger's `inserted`
    /// pseudo-table all arrive verbatim at an engine that has none of them. A table has a
    /// structure the translator can restate; a definition has only text.
    internal static func definitionEngineRefusal(
        from source: DatabaseType,
        to target: DatabaseType
    ) -> String? {
        guard SQLTypeFamily.needsTranslation(from: source, to: target) else { return nil }
        return String(
            format: String(
                localized: "Its definition is written in %1$@'s own SQL, which %2$@ does not parse."
            ),
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
        guard sharesObjectSpace(source, target) else { return nil }
        return String(localized: "The source and the target are the same database. Choose a different target.")
    }

    /// Whether the two sides can resolve to one set of objects.
    ///
    /// Not `DatabaseEndpoint.id`, which spells the schema into the identity and so answered "these
    /// are different" for a database-scoped source and a schema-scoped target that name the same
    /// objects. Right-clicking a PostgreSQL database gives a source with no schema; choosing that
    /// same database's `public` as the target then passed every refusal, and the planner went on to
    /// resolve both sides to `public` and drop each table before streaming from the table it had
    /// just emptied.
    ///
    /// An endpoint that names no schema stands for whichever schema its objects turn out to be in,
    /// so it overlaps every schema of its database rather than none of them. The database itself is
    /// compared as spelled, which is what the identity already did: engines disagree about whether
    /// a database name folds case, and this rule is not the place to decide that.
    private static func sharesObjectSpace(_ source: DatabaseEndpoint, _ target: DatabaseEndpoint) -> Bool {
        guard source.connectionId == target.connectionId, source.database == target.database else {
            return false
        }
        guard let sourceSchema = source.schema?.nilIfEmpty,
              let targetSchema = target.schema?.nilIfEmpty else { return true }
        return ObjectCopyNamespace.isSame(sourceSchema, targetSchema)
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
