//
//  SourceObjectIndexes.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum ObjectIndexRead: Sendable {
    case read([PluginIndexInfo])
    case failed(String)
}

internal enum SourceObjectIndexes {
    internal static func tableType(of kind: CompareObjectKind) -> TableInfo.TableType? {
        switch kind {
        case .view: return .view
        case .materializedView: return .materializedView
        case .table, .procedure, .function, .trigger, .sequence: return nil
        }
    }

    internal static func areCarried(for kind: CompareObjectKind, by matrix: StructureObjectEditMatrix) -> Bool {
        guard let tableType = tableType(of: kind) else { return false }
        return StructureEditEligibility.allows(.addIndex, on: tableType, matrix: matrix)
            && StructureEditEligibility.allows(.dropIndex, on: tableType, matrix: matrix)
    }

    internal static func carriedKinds(by matrix: StructureObjectEditMatrix) -> Set<CompareObjectKind> {
        Set(CompareObjectKind.allCases.filter { areCarried(for: $0, by: matrix) })
    }

    @MainActor
    internal static func carriedKinds(on databaseType: DatabaseType) -> Set<CompareObjectKind> {
        carriedKinds(by: PluginManager.shared.structureEditMatrix(for: databaseType))
    }

    internal static func definitions(_ indexes: [PluginIndexInfo]) -> [EditableIndexDefinition] {
        indexes.map { EditableIndexDefinition.from(IndexInfo($0)) }.filter { !$0.isPrimary }
    }

    internal static var notCarriedByTargetNote: String {
        String(localized: "Its indexes are left out, because the target is not known to take indexes on this kind of object.")
    }

    internal static var otherSchemaNote: String {
        String(
            localized: "Its indexes are left out, because the target's index statements would name a different schema than its definition."
        )
    }
}

internal enum SourceObjectIndexCopy: Equatable {
    case none
    case write([EditableIndexDefinition])
    case leaveOut(String)
    case refuse(String)

    internal static func decide(
        for read: RoutineSourceRead,
        targetCarries: Bool,
        indexSchema: String?
    ) -> SourceObjectIndexCopy {
        guard let indexes = read.indexes else { return .none }
        switch indexes {
        case .failed(let reason):
            guard targetCarries else { return .leaveOut(SourceObjectIndexes.notCarriedByTargetNote) }
            return .refuse(String(format: String(localized: "Its indexes could not be read: %@"), reason))
        case .read(let found):
            let definitions = SourceObjectIndexes.definitions(found)
            guard !definitions.isEmpty else { return .none }
            guard targetCarries else { return .leaveOut(SourceObjectIndexes.notCarriedByTargetNote) }
            guard let indexSchema, read.schema == indexSchema else {
                return .leaveOut(SourceObjectIndexes.otherSchemaNote)
            }
            return .write(definitions)
        }
    }
}

internal enum ConcurrentRefreshIndexRule {
    internal static func isUsable(_ index: EditableIndexDefinition) -> Bool {
        let predicate = index.whereClause?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return index.isUnique
            && index.expressions.isEmpty
            && predicate.isEmpty
            && index.type == .btree
    }

    internal static func allowsConcurrentRefresh(_ indexes: [EditableIndexDefinition]) -> Bool {
        indexes.contains(where: isUsable)
    }
}
