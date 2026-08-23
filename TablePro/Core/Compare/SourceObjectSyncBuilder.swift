//
//  SourceObjectSyncBuilder.swift
//  TablePro
//
//  Statements for the objects whose definition is SQL text.
//
//  There is nothing to synthesise here: the source's own definition is the
//  statement. What the builder decides is how to get from the target's current
//  definition to that one, which for a view or a routine means dropping what is
//  there and running the source's text. `CREATE OR REPLACE` is deliberately not
//  used, because the engines spell it differently, several do not accept it for
//  a signature change, and a replace that silently keeps the old object on
//  failure is worse than an explicit drop the user allowed.
//

import Foundation
import TableProPluginKit

internal struct SourceObjectSyncBuilder {
    private let targetDriver: any PluginDatabaseDriver
    private let classifier = SyncSafetyClassifier()

    internal init(targetDriver: any PluginDatabaseDriver) {
        self.targetDriver = targetDriver
    }

    internal func build(for result: CompareObjectResult, action: TableSyncAction) -> [SyncStatement] {
        switch action {
        case .skip:
            return []
        case .create:
            return createStatements(for: result)
        case .alter:
            return dropStatements(for: result, isReplacement: true) + createStatements(for: result)
        case .drop:
            return dropStatements(for: result, isReplacement: false)
        }
    }

    private func createStatements(for result: CompareObjectResult) -> [SyncStatement] {
        let definition = result.sourceDefinition.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.isEmpty else { return [] }
        return [SyncStatement(
            sql: terminated(definition),
            objectName: result.identity.displayName,
            summary: String(
                format: String(localized: "Create %1$@ %2$@"),
                result.identity.kind.displayName.lowercased(), result.identity.displayName
            )
        )]
    }

    private func dropStatements(for result: CompareObjectResult, isReplacement: Bool) -> [SyncStatement] {
        guard let keyword = dropKeyword(for: result.identity.kind) else { return [] }
        let name = qualified(result.identity)
        return [SyncStatement(
            sql: "DROP \(keyword) \(name);",
            objectName: result.identity.displayName,
            summary: isReplacement
                ? String(
                    format: String(localized: "Replace %1$@ %2$@"),
                    result.identity.kind.displayName.lowercased(), result.identity.displayName
                )
                : String(
                    format: String(localized: "Drop %1$@ %2$@"),
                    result.identity.kind.displayName.lowercased(), result.identity.displayName
                ),
            hazards: classifier.hazards(forDropping: result.identity, isReplacement: isReplacement)
        )]
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
        let quotedName = targetDriver.quoteIdentifier(identity.name)
        guard let schema = identity.schema, !schema.isEmpty else { return quotedName }
        return "\(targetDriver.quoteIdentifier(schema)).\(quotedName)"
    }

    private func terminated(_ sql: String) -> String {
        sql.hasSuffix(";") ? sql : sql + ";"
    }
}
