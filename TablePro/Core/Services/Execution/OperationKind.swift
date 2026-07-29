//
//  OperationKind.swift
//  TablePro
//

import Foundation

internal enum OperationKind: Sendable, Equatable {
    case readQuery
    case writeQuery
    case destructiveQuery
    case schemaMutation
    case importData
    case maintenance
    case metadataRead
}

internal extension OperationKind {
    var declaresWrite: Bool {
        switch self {
        case .readQuery, .metadataRead:
            return false
        case .writeQuery, .destructiveQuery, .schemaMutation, .importData, .maintenance:
            return true
        }
    }

    var declaresDestructive: Bool {
        self == .destructiveQuery
    }

    static func from(_ tier: QueryTier) -> OperationKind {
        switch tier {
        case .safe: return .readQuery
        case .write: return .writeQuery
        case .destructive: return .destructiveQuery
        }
    }

    static func worst(of statements: [String], databaseType: DatabaseType) -> OperationKind {
        var result: OperationKind = .readQuery
        for statement in statements {
            let tier = QueryClassifier.classifyTier(statement, databaseType: databaseType)
            if tier == .destructive || QueryClassifier.isDangerousQuery(statement, databaseType: databaseType) {
                return .destructiveQuery
            }
            if tier == .write {
                result = .writeQuery
            }
        }
        return result
    }
}
