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
}
