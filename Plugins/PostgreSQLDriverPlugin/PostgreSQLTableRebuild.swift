//
//  PostgreSQLTableRebuild.swift
//  PostgreSQLDriverPlugin
//

import Foundation

struct PostgreSQLTableRebuild {
    var columnNames: [String] = []
    var columnDefinitions: [String: String] = [:]
    var copyableColumns: [String] = []
    var identityColumns: [String] = []
    var tableConstraints: [String] = []
    var outboundForeignKeys: [String] = []
    var inboundForeignKeyDrops: [String] = []
    var inboundForeignKeyAdds: [String] = []
    var indexes: [String] = []
    var invalidIndexes: [String] = []
    var triggers: [String] = []
    var triggerModes: [String] = []
    var comments: [String] = []
    var dependentViews: [String] = []
    var serialSequenceHandovers: [String] = []

    /// The order here is the whole difficulty, and every step of it was measured against
    /// PostgreSQL 17. The old table is renamed rather than dropped, so a foreign key in another
    /// table keeps pointing at real rows while the copy runs. But a rename moves nothing else:
    /// the staging table still owns every index name and every constraint name the original
    /// had, and both live in the schema rather than on the table. Declaring the constraints
    /// inside the `CREATE TABLE` therefore silently renames them, which shipped as `x_pkey1`,
    /// `x_a_b_key1` and `x_c_check1`; creating an index before the staging table goes fails
    /// outright with "relation already exists". So nothing that carries a name is created until
    /// the staging table is dropped, and the staging table cannot be dropped until every
    /// inbound foreign key has let go of it.
    func statements(
        table: String,
        schema: String,
        desiredOrder: [String],
        quote: (String) -> String,
        capabilities: PostgreSQLCapabilities
    ) -> [String] {
        let stagingName = "\(table)_tablepro_reorder"
        let qualified = "\(quote(schema)).\(quote(table))"
        let staging = "\(quote(schema)).\(quote(stagingName))"
        let copyList = copyableColumns.map(quote).joined(separator: ", ")
        let body = desiredOrder.compactMap { columnDefinitions[$0] }

        var statements: [String] = []
        statements.append("ALTER TABLE \(qualified) RENAME TO \(quote(stagingName))")
        statements.append("CREATE TABLE \(qualified) (\n  " + body.joined(separator: ",\n  ") + "\n)")
        statements.append(PostgreSQLVersionedStatements.copyRows(
            into: qualified,
            from: staging,
            columnList: copyList,
            capabilities: capabilities
        ))
        statements.append(contentsOf: identityResets(qualified: qualified, quote: quote))
        statements.append(contentsOf: inboundForeignKeyDrops)
        /// A `serial` column's default still calls the sequence the staging table owns, so `DROP
        /// TABLE` tries to take that sequence with it and PostgreSQL refuses, rolling the whole
        /// script back. Measured: handing ownership to the rebuilt table first lets the drop
        /// through, and the sequence keeps its original name.
        statements.append(contentsOf: serialSequenceHandovers)
        statements.append("DROP TABLE \(staging)")
        statements.append(contentsOf: tableConstraints.map { "ALTER TABLE \(qualified) ADD \($0)" })
        statements.append(contentsOf: indexes)
        statements.append(contentsOf: outboundForeignKeys.map { "ALTER TABLE \(qualified) ADD \($0)" })
        statements.append(contentsOf: inboundForeignKeyAdds)
        statements.append(contentsOf: triggers)
        statements.append(contentsOf: triggerModes)
        statements.append(contentsOf: comments)
        return statements
    }

    var caveats: [String] {
        dependentViewCaveat + invalidIndexCaveat + [
            String(localized: """
                Grants, row-level security policies, publications, extended statistics, partitioning and \
                table inheritance are not carried over.
                """),
            String(localized: """
                An identity column keeps its value, but its sequence is recreated under a new name because \
                the old table still holds the original name when the new one is created.
                """)
        ]
    }

    /// PostgreSQL binds a view to the table's OID, not its name, so a view follows the rename
    /// onto the staging table and then refuses to let it be dropped. Measured: the rebuild
    /// stops at `DROP TABLE` with "cannot drop table … because other objects depend on it" and
    /// the whole transaction rolls back. Naming them here is what stops that being discovered
    /// three quarters of the way through the script.
    private var dependentViewCaveat: [String] {
        guard !dependentViews.isEmpty else { return [] }
        return [
            String(
                format: String(
                    localized: "Drop and recreate these views first, or the script stops when it drops the old table: %@."
                ),
                dependentViews.joined(separator: ", ")
            )
        ]
    }

    private var invalidIndexCaveat: [String] {
        guard !invalidIndexes.isEmpty else { return [] }
        return [
            String(
                format: String(localized: "Invalid indexes are not recreated: %@."),
                invalidIndexes.joined(separator: ", ")
            )
        ]
    }

    /// A new identity column starts its sequence at one, so it is wound forward to the rows the
    /// copy just wrote. Without this the next insert collides with an existing key.
    ///
    /// `qualified` is already a quoted identifier pair, and `pg_get_serial_sequence` takes the
    /// whole pair as one literal, so it is composed first and quoted once. A schema, table or
    /// column name may legally contain an apostrophe or a backslash, and both land inside a
    /// literal here.
    private func identityResets(qualified: String, quote: (String) -> String) -> [String] {
        let relationLiteral = PostgreSQLObjectQueries.quoteLiteral(qualified)
        return identityColumns.map { column in
            let columnLiteral = PostgreSQLObjectQueries.quoteLiteral(column)
            return """
            SELECT setval(
              pg_get_serial_sequence(\(relationLiteral), \(columnLiteral)),
              GREATEST(COALESCE((SELECT MAX(\(quote(column))) FROM \(qualified)), 0), 1),
              true
            )
            """
        }
    }
}
