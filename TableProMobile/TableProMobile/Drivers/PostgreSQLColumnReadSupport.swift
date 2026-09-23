import Foundation

nonisolated struct PostgreSQLColumnReadShape: Equatable, Sendable {
    let includesIdentityColumns: Bool
    let includesMaterializedViews: Bool
}

nonisolated struct PostgreSQLColumnReadSupport: Equatable, Sendable {
    var identityColumns: Bool?
    var materializedViewColumns: Bool?

    func attempts(materializedViewsPresent: Bool) -> [PostgreSQLColumnReadShape] {
        let identityOptions = identityColumns == false ? [false] : [true, false]
        let readsMaterializedViews = materializedViewsPresent && materializedViewColumns != false
        let materializedViewOptions = readsMaterializedViews ? [true, false] : [false]
        return materializedViewOptions.flatMap { includesMaterializedViews in
            identityOptions.map { includesIdentityColumns in
                PostgreSQLColumnReadShape(
                    includesIdentityColumns: includesIdentityColumns,
                    includesMaterializedViews: includesMaterializedViews
                )
            }
        }
    }

    func learning(from shape: PostgreSQLColumnReadShape, materializedViewsPresent: Bool) -> PostgreSQLColumnReadSupport {
        PostgreSQLColumnReadSupport(
            identityColumns: shape.includesIdentityColumns,
            materializedViewColumns: materializedViewsPresent ? shape.includesMaterializedViews : materializedViewColumns
        )
    }
}
