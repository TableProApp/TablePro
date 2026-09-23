//
//  SourceObjectSyncBuilder.swift
//  TablePro
//
//  Statements for the objects whose definition is SQL text.
//
//  There is nothing to synthesise here: the source's own definition is the
//  statement. What the builder decides is how to get from the target's current
//  definition to that one, which for a view or a routine means dropping what is
//  there and running the source's text. `CREATE OR REPLACE` is not written here,
//  because the engines spell it differently and several do not accept it for a
//  signature change. The one exception is a definition the source already wrote
//  as `CREATE OR REPLACE`, on a target whose driver says that replaces the
//  object in place: there the DROP is what would lose the object when the new
//  definition fails, so it is left out.
//

import Foundation
import os
import TableProPluginKit

internal struct SourceObjectSyncBuilder {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SourceObjectSyncBuilder")

    private let targetDriver: any PluginDatabaseDriver
    private let targetDatabaseType: DatabaseType
    private let scriptText: SQLScriptText
    private let classifier = SyncSafetyClassifier()

    internal init(targetDriver: any PluginDatabaseDriver, targetDatabaseType: DatabaseType) {
        self.targetDriver = targetDriver
        self.targetDatabaseType = targetDatabaseType
        self.scriptText = SQLScriptText(databaseType: targetDatabaseType)
    }

    internal func build(for result: CompareObjectResult, action: TableSyncAction) throws -> [SyncStatement] {
        switch action {
        case .skip:
            return []
        case .create:
            try refuseWithoutACreateStatement(result)
            return createStatements(for: result, isReplacement: false)
        case .alter:
            try refuseWithoutACreateStatement(result)
            guard replacesInPlace(result.identity, with: result) else {
                return dropStatements(for: result, isReplacement: true)
                    + createStatements(for: result, isReplacement: false)
            }
            return createStatements(for: result, isReplacement: true)
        case .drop:
            return dropStatements(for: result, isReplacement: false)
        }
    }

    private func refuseWithoutACreateStatement(_ result: CompareObjectResult) throws {
        let definition = result.sourceDefinition.joined(separator: "\n")
        guard SourceDefinitionDefect.of(definition: definition, sentAs: scriptText) != nil else { return }
        Self.logger.fault(
            "Refused to script \(result.identity.kind.rawValue, privacy: .public) \(result.identity.name, privacy: .private(mask: .hash)) without a CREATE statement"
        )
        throw CompareSyncError.unsupportedOperation(
            String(
                format: String(localized: "%@ cannot be scripted, because its definition is not a statement that recreates it."),
                result.identity.displayName
            )
        )
    }

    /// Whether running `replacement`'s definition alone replaces `existing` on the target. Measured on Oracle 23ai, a
    /// DROP followed by a CREATE the engine refused left no trigger at all, while the same CREATE OR REPLACE refused
    /// on its own left the existing trigger VALID. A materialized view has no `CREATE OR REPLACE` on any engine.
    internal func replacesInPlace(_ existing: CompareObjectIdentity, with replacement: CompareObjectResult) -> Bool {
        guard targetDriver.replacesDefinitionsInPlace,
              existing.kind == replacement.identity.kind,
              existing.kind != .materializedView,
              let first = scriptText.sendableStatements(replacement.sourceDefinition.joined(separator: "\n")).first
        else { return false }
        let leadingWords = first.split(whereSeparator: \.isWhitespace).prefix(3).map { $0.uppercased() }
        return leadingWords == ["CREATE", "OR", "REPLACE"]
    }

    /// The source's definition goes out as the statements it holds, each the way the target's driver takes it. On
    /// Oracle that keeps a unit's own `;` and leaves a `CALL` trigger without one, which is the only form of either
    /// that Oracle stores VALID.
    private func createStatements(for result: CompareObjectResult, isReplacement: Bool) -> [SyncStatement] {
        let definition = result.sourceDefinition.joined(separator: "\n")
        let format = isReplacement ? String(localized: "Replace %1$@ %2$@") : String(localized: "Create %1$@ %2$@")
        let summary = String(
            format: format, result.identity.kind.displayName.lowercased(), result.identity.displayName
        )
        return scriptText.sendableStatements(definition).map { sql in
            SyncStatement(sql: sql, objectName: result.identity.displayName, summary: summary)
        }
    }

    private func dropStatements(for result: CompareObjectResult, isReplacement: Bool) -> [SyncStatement] {
        guard let keyword = dropKeyword(for: result.identity.kind) else { return [] }
        let sql = dialectDrop(for: result.identity) ?? "DROP \(keyword) \(qualified(result.identity))"
        let summary = isReplacement
            ? String(
                format: String(localized: "Replace %1$@ %2$@"),
                result.identity.kind.displayName.lowercased(), result.identity.displayName
            )
            : String(
                format: String(localized: "Drop %1$@ %2$@"),
                result.identity.kind.displayName.lowercased(), result.identity.displayName
            )
        let hazards = classifier.hazards(forDropping: result.identity, isReplacement: isReplacement)
        return scriptText.sendableStatements(sql).map { statement in
            SyncStatement(
                sql: statement,
                objectName: result.identity.displayName,
                summary: summary,
                hazards: hazards
            )
        }
    }

    /// A routine and a trigger are not addressed by name alone on every engine. PostgreSQL needs an
    /// overloaded routine's argument list and spells a trigger drop `DROP TRIGGER name ON table`,
    /// while MySQL rejects the argument list and takes no `ON`. Only the driver knows which, so the
    /// bare qualified name is the fallback rather than the rule.
    private func dialectDrop(for identity: CompareObjectIdentity) -> String? {
        switch identity.kind {
        case .procedure, .function:
            return targetDriver.generateDropRoutineSQL(
                name: identity.name,
                signature: identity.signature,
                schema: identity.schema,
                isFunction: identity.kind == .function
            )
        case .trigger:
            guard let table = identity.signature, !table.isEmpty else { return nil }
            return targetDriver.generateDropTriggerSQL(
                name: identity.name, table: table, schema: identity.schema
            )
        case .view, .materializedView, .table, .sequence:
            return nil
        }
    }

    private func dropKeyword(for kind: CompareObjectKind) -> String? {
        switch kind {
        case .view: return "VIEW"
        case .materializedView: return "MATERIALIZED VIEW"
        case .procedure: return "PROCEDURE"
        case .function: return "FUNCTION"
        case .trigger: return "TRIGGER"
        case .table, .sequence: return nil
        }
    }

    private func qualified(_ identity: CompareObjectIdentity) -> String {
        SchemaQualifiedName.render(
            name: identity.name,
            schema: identity.schema,
            databaseType: targetDatabaseType,
            quote: targetDriver.quoteIdentifier
        )
    }
}
