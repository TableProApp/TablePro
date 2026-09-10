//
//  ContainerDropEligibility.swift
//  TablePro
//

import Foundation

enum ContainerDropEligibility {
    struct Context {
        let activeDatabase: String?
        let activeSchema: String?
        let supportsDropDatabase: Bool
        let supportsDropSchema: Bool
        let isReadOnly: Bool
    }

    static func droppable(_ targets: [DatabaseContainerRef], context: Context) -> [DatabaseContainerRef] {
        guard !context.isReadOnly else { return [] }
        return targets.filter { isDroppable($0, context: context) }
    }

    private static func isDroppable(_ target: DatabaseContainerRef, context: Context) -> Bool {
        guard !target.isSystem else { return false }
        switch target.kind {
        case .database:
            guard context.supportsDropDatabase else { return false }
            return target.database != context.activeDatabase
        case .schema:
            guard context.supportsDropSchema else { return false }
            guard target.database == context.activeDatabase else { return true }
            return target.schema != context.activeSchema
        }
    }
}
