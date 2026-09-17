//
//  StructureChangeGuard.swift
//  TablePro
//
//  Checks that the structure a script is about to be built from is still the
//  structure that was compared.
//
//  The data half re-walks both sides when it builds its script and refuses when
//  the difference digest moves. The structure half generates DDL from the
//  snapshot the comparison took and never looks again, so a window left open
//  while someone else works on either database produces a script written
//  against a schema that no longer exists: a CREATE TABLE missing a column
//  added since, an ALTER against a column already dropped, a DROP of a table
//  that was recreated with rows in it.
//
//  What is compared here is what the generators read, not what the comparison
//  displayed. `SchemaSyncScriptBuilder` renders a raw `TableStructureSnapshot`,
//  and `SourceObjectSyncBuilder` emits `sourceDefinition` verbatim, while the
//  comparison reaches both through normalizers that fold case, collapse
//  whitespace and drop an AUTO_INCREMENT seed. Guarding the normalized values
//  would pass exactly the edits the generators would then carry into the target.
//
//  The one thing left out is the `id` each column, index and foreign key carries. Every read mints
//  a fresh one and no generator reads it, so comparing it refused every table the script would
//  create or alter, even when neither database had changed.
//

import Foundation

internal struct StructureGenerationInput: Hashable, Sendable {
    internal let qualifiedName: String
    internal let action: TableSyncAction
    internal let status: TableDiffStatus
    internal let changes: [SchemaChange]
    internal let sourceSnapshot: TableStructureSnapshot?
    internal let sourceDefinition: [String]
}

internal enum StructureChangeGuard {
    internal static func inputs(
        for results: [CompareObjectResult],
        actions: (CompareObjectResult) -> TableSyncAction,
        sourceSnapshots: [String: TableStructureSnapshot]
    ) -> [String: StructureGenerationInput] {
        var inputs: [String: StructureGenerationInput] = [:]
        for result in results {
            let action = actions(result)
            guard action != .skip else { continue }
            inputs[result.id] = StructureGenerationInput(
                qualifiedName: result.identity.qualifiedName,
                action: action,
                status: result.status,
                changes: result.identity.kind == .table ? result.changes.map { $0.withoutIdentity() } : [],
                sourceSnapshot: result.identity.kind == .table
                    ? sourceSnapshots[result.identity.qualifiedName]?.withoutIdentity()
                    : nil,
                sourceDefinition: result.identity.kind == .table ? [] : result.sourceDefinition
            )
        }
        return inputs
    }

    /// Only the objects the script would write are checked. Another table changing elsewhere in the
    /// same schema is somebody else's work and has nothing to do with this script, so refusing on it
    /// would make a busy database impossible to sync.
    internal static func refusal(
        expected: [String: StructureGenerationInput],
        actual: [String: StructureGenerationInput]
    ) -> CompareSyncError? {
        for (id, input) in expected.sorted(by: { $0.key < $1.key }) {
            guard let current = actual[id], current == input else { return changed(input.qualifiedName) }
        }
        return nil
    }

    private static func changed(_ name: String) -> CompareSyncError {
        .objectsChangedSinceComparison(
            String(
                format: String(
                    localized: "%@ changed after it was compared. Compare again before generating the script."
                ),
                name
            )
        )
    }
}
