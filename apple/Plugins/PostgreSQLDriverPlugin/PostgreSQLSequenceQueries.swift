//
//  PostgreSQLSequenceQueries.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

struct PostgreSQLSequenceDefinition: Equatable, Sendable {
    let name: String
    let startValue: String?
    let minValue: String?
    let maxValue: String?
    let increment: String?
    let cycles: Bool
    let lastValue: String?
    let needsLastValueRead: Bool
    var dataType: String?
    var cacheSize: String?
    var ownedByTable: String?
    var ownedByColumn: String?
    // 'a' for OWNED BY, 'i' for an identity column's own sequence.
    var ownerDependency: String?

    func withLastValue(_ value: String?) -> PostgreSQLSequenceDefinition {
        var read = PostgreSQLSequenceDefinition(
            name: name,
            startValue: startValue,
            minValue: minValue,
            maxValue: maxValue,
            increment: increment,
            cycles: cycles,
            lastValue: value,
            needsLastValueRead: false
        )
        read.dataType = dataType
        read.cacheSize = cacheSize
        read.ownedByTable = ownedByTable
        read.ownedByColumn = ownedByColumn
        read.ownerDependency = ownerDependency
        return read
    }

    // Relative, because a copy recreates the sequence beside its table under the same name.
    var ddl: String {
        statements(target: PostgreSQLObjectQueries.quoteIdentifier(name), ownerSchema: nil)
    }

    // The sequence on its own, as the DDL tab shows it: qualified, with the column that owns it.
    func qualifiedDDL(schema: String) -> String {
        statements(target: PostgreSQLObjectQueries.qualifiedName(schema: schema, name: name), ownerSchema: schema)
    }

    private func statements(target: String, ownerSchema: String?) -> String {
        let parameters = [startValue, minValue, maxValue, increment]
        var statement: String
        if parameters.allSatisfy({ $0 == nil }) {
            statement = "CREATE SEQUENCE \(target);"
        } else {
            statement = "CREATE SEQUENCE \(target)\(typeClause) INCREMENT BY \(increment ?? "1")"
                + " MINVALUE \(minValue ?? "1") MAXVALUE \(maxValue ?? "9223372036854775807")"
                + " START WITH \(startValue ?? "1")\(cacheClause)\(cycles ? " CYCLE" : "");"
        }
        // An identity column's sequence is created by its column, so only OWNED BY is written.
        if let ownerSchema, ownerDependency == "a", let ownedByTable, let ownedByColumn {
            let column = PostgreSQLObjectQueries.qualifiedName(schema: ownerSchema, name: ownedByTable)
                + "." + PostgreSQLObjectQueries.quoteIdentifier(ownedByColumn)
            statement += "\nALTER SEQUENCE \(target) OWNED BY \(column);"
        }
        guard let lastValue, Int64(lastValue) != nil else { return statement }
        statement += "\nSELECT pg_catalog.setval(\(PostgreSQLObjectQueries.quoteLiteral(target)), \(lastValue), true);"
        return statement
    }

    // bigint is the default, and the only other types a sequence takes are these two.
    private var typeClause: String {
        switch dataType {
        case "smallint", "integer": " AS \(dataType ?? "")"
        default: ""
        }
    }

    private var cacheClause: String {
        guard let cacheSize, let cache = Int64(cacheSize), cache != 1 else { return "" }
        return " CACHE \(cache)"
    }

    func details(schema: String, position: PostgreSQLSequencePosition? = nil) -> PluginSequenceDetails {
        PluginSequenceDetails(
            name: name,
            schema: schema,
            dataType: dataType,
            startValue: startValue.flatMap { Int64($0) },
            increment: increment.flatMap { Int64($0) },
            minValue: minValue.flatMap { Int64($0) },
            maxValue: maxValue.flatMap { Int64($0) },
            cacheSize: cacheSize.flatMap { Int64($0) },
            cycles: cycles,
            lastValue: lastValue.flatMap { Int64($0) },
            nextValue: position?.nextValue(
                increment: increment.flatMap { Int64($0) } ?? 1,
                minValue: minValue.flatMap { Int64($0) },
                maxValue: maxValue.flatMap { Int64($0) },
                cycles: cycles
            ),
            ownedByTable: ownedByTable,
            ownedByColumn: ownedByColumn
        )
    }
}

// The sequence relation's own row: pg_sequences reports NULL both before the first nextval and after
// setval(..., false), so only last_value with is_called says where the sequence stands.
struct PostgreSQLSequencePosition: Equatable, Sendable {
    let lastValue: Int64
    let isCalled: Bool

    static func query(schema: String, sequence: String) -> String {
        "SELECT last_value, is_called FROM \(PostgreSQLObjectQueries.qualifiedName(schema: schema, name: sequence))"
    }

    init(lastValue: Int64, isCalled: Bool) {
        self.lastValue = lastValue
        self.isCalled = isCalled
    }

    init?(row: [PluginCellValue]?) {
        guard let last = row?[safe: 0]?.asText.flatMap({ Int64($0) }) else { return nil }
        self.init(lastValue: last, isCalled: PostgreSQLCatalogBoolean.isTrue(row?[safe: 1]?.asText))
    }

    func nextValue(increment: Int64, minValue: Int64?, maxValue: Int64?, cycles: Bool) -> Int64? {
        guard isCalled else { return lastValue }
        let (next, overflow) = lastValue.addingReportingOverflow(increment)
        let inRange = !overflow && next >= (minValue ?? .min) && next <= (maxValue ?? .max)
        if inRange { return next }
        guard cycles else { return nil }
        return increment > 0 ? minValue : maxValue
    }
}

enum PostgreSQLSequenceQueries {
    enum Source: Equatable {
        case sequencesView
        case sequenceParameters
    }

    /// `pg_sequence_parameters` answers on every supported release, so a server whose version
    /// promises `pg_sequences` but whose catalog does not carry it still lists its sequences.
    static func source(hasSequencesCatalog: Bool) -> Source {
        hasSequencesCatalog ? .sequencesView : .sequenceParameters
    }

    static func sequenceList(
        schema: String,
        dependentOnTable table: String?,
        source: Source,
        named sequence: String? = nil
    ) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let dependency = table.map { dependencyPredicate(schemaLiteral: schemaLiteral, table: $0) } ?? ""
        switch source {
        case .sequencesView:
            let nameFilter = sequence.map { "\n                  AND s.sequencename = \(PostgreSQLObjectQueries.quoteLiteral($0))" } ?? ""
            return """
                SELECT s.sequencename,
                       s.start_value,
                       s.min_value,
                       s.max_value,
                       s.increment_by,
                       s.cycle,
                       s.last_value,
                       false AS needs_last_value_read,
                       s.data_type::text,
                       s.cache_size,
                       \(ownerColumns(sequence: "c.oid"))
                FROM pg_catalog.pg_sequences s
                JOIN pg_catalog.pg_namespace n ON n.nspname = s.schemaname
                JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = s.sequencename
                WHERE s.schemaname = \(schemaLiteral)\(nameFilter)\(dependency)
                ORDER BY s.sequencename
                """
        case .sequenceParameters:
            let nameFilter = sequence.map { "\n                        AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral($0))" } ?? ""
            return """
                SELECT s.relname,
                       \(parameter("start_value")),
                       \(parameter("minimum_value")),
                       \(parameter("maximum_value")),
                       \(parameter("increment")),
                       \(parameter("cycle_option")),
                       NULL::bigint AS last_value,
                       s.readable,
                       NULL::text AS data_type,
                       NULL::bigint AS cache_size,
                       \(ownerColumns(sequence: "s.oid"))
                FROM (
                    SELECT c.oid,
                           c.relname,
                           pg_catalog.has_sequence_privilege(c.oid, 'SELECT,USAGE,UPDATE') AS can_read_parameters,
                           pg_catalog.has_sequence_privilege(c.oid, 'SELECT') AS readable
                    FROM pg_catalog.pg_class c
                    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                    WHERE c.relkind = 'S'
                        AND n.nspname = \(schemaLiteral)\(nameFilter)\(dependency)
                    OFFSET 0
                ) s
                ORDER BY s.relname
                """
        }
    }

    private static func ownerColumns(sequence: String) -> String {
        let dependency = PostgreSQLTableListing.sequenceOwnerDependency("d", sequence: sequence)
        return """
        (SELECT owner.relname FROM pg_catalog.pg_depend d
                            JOIN pg_catalog.pg_class owner ON owner.oid = d.refobjid
                            WHERE \(dependency) LIMIT 1) AS owned_by_table,
                               (SELECT a.attname FROM pg_catalog.pg_depend d
                            JOIN pg_catalog.pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
                            WHERE \(dependency) LIMIT 1) AS owned_by_column,
                               (SELECT d.deptype::text FROM pg_catalog.pg_depend d
                            WHERE \(dependency) LIMIT 1) AS owner_dependency
        """
    }

    /// The privilege test runs once per sequence in the fenced derived table (`OFFSET 0` stops it
    /// being flattened back into every CASE). The parameters cannot be read once the same way:
    /// `pg_sequence_parameters` returns an anonymous record that loses its type in a derived-table
    /// column (9.1 and 9.3 answer "record type has not been registered"), and moving the privilege
    /// test into WHERE lets the server run it against relations that are not sequences.
    private static func parameter(_ field: String) -> String {
        """
        CASE WHEN s.can_read_parameters
                           THEN (pg_catalog.pg_sequence_parameters(s.oid)).\(field) END
        """
    }

    /// One statement per sequence. A sequence dropped or revoked between the listing and this read
    /// then costs its own `setval` line rather than the whole listing.
    static func lastValue(schema: String, sequence: String) -> String {
        let relation = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: sequence)
        return "SELECT CASE WHEN is_called THEN last_value END FROM \(relation)"
    }

    static func definitions(from rows: [[PluginCellValue]]) -> [PostgreSQLSequenceDefinition] {
        rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            var definition = PostgreSQLSequenceDefinition(
                name: name,
                startValue: row[safe: 1]?.asText,
                minValue: row[safe: 2]?.asText,
                maxValue: row[safe: 3]?.asText,
                increment: row[safe: 4]?.asText,
                cycles: PostgreSQLCatalogBoolean.isTrue(row[safe: 5]?.asText),
                lastValue: row[safe: 6]?.asText,
                needsLastValueRead: PostgreSQLCatalogBoolean.isTrue(row[safe: 7]?.asText)
            )
            definition.dataType = row[safe: 8]?.asText
            definition.cacheSize = row[safe: 9]?.asText
            definition.ownedByTable = row[safe: 10]?.asText
            definition.ownedByColumn = row[safe: 11]?.asText
            definition.ownerDependency = row[safe: 12]?.asText
            return definition
        }
    }

    /// A `pg_depend` row recording that a column default names a relation. `pg_get_expr` never says
    /// which sequences a default reads, and this row does, for `nextval`, `currval` and every other
    /// `regclass` constant alike. The column DDL read and the dependent-sequence listing both start
    /// from it, so the sequences a copy recreates are the ones whose names a copied default writes
    /// relative. Each caller adds its own correlation and its own same-schema rule.
    static func columnDefaultDependency(alias: String) -> String {
        """
        \(alias).classid = 'pg_catalog.pg_attrdef'::pg_catalog.regclass
                            AND \(alias).refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
        """
    }

    private static func dependencyPredicate(schemaLiteral: String, table: String) -> String {
        """

                  AND EXISTS (
                        SELECT 1
                        FROM pg_catalog.pg_attrdef ad
                        JOIN pg_catalog.pg_depend d
                            ON \(columnDefaultDependency(alias: "d"))
                            AND d.objid = ad.oid
                            AND d.refobjid = c.oid
                        JOIN pg_catalog.pg_class t ON t.oid = ad.adrelid
                        JOIN pg_catalog.pg_namespace tn ON tn.oid = t.relnamespace
                        WHERE t.relname = \(PostgreSQLObjectQueries.quoteLiteral(table))
                            AND tn.nspname = \(schemaLiteral))
        """
    }
}

enum PostgreSQLSequenceStatements {
    static let createTemplate = """
        CREATE SEQUENCE sequence_name
            INCREMENT BY 1
            START WITH 1
            CACHE 1;
        """

    // is_called false, so the next nextval returns the value itself.
    static func nextValue(
        _ sequence: PluginSequenceDetails,
        schema: String,
        nextValue: PluginSequenceNextValue,
        hasRowSecurity: Bool = true
    ) -> String? {
        let target = PostgreSQLObjectQueries.quoteLiteral(
            PostgreSQLObjectQueries.qualifiedName(schema: schema, name: sequence.name)
        )
        switch nextValue {
        case .value(let value):
            return "SELECT pg_catalog.setval(\(target), \(value), false)"
        case .afterOwnedColumn:
            guard let table = sequence.ownedByTable, let column = sequence.ownedByColumn else { return nil }
            let increment = sequence.increment ?? 1
            let descending = increment < 0
            let start = sequence.startValue ?? (descending ? -1 : 1)
            let source = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: table)
            let relation = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: sequence.name)
            let quotedColumn = PostgreSQLObjectQueries.quoteIdentifier(column)
            let afterColumn = "COALESCE(pg_catalog.\(descending ? "min" : "max")(\(quotedColumn))::bigint + \(increment), \(start))"
            // Never behind where the sequence already is: another session may hold values cached past it.
            let current = "(SELECT CASE WHEN is_called THEN last_value + \(increment) ELSE last_value END FROM \(relation))"
            let value = "\(descending ? "LEAST" : "GREATEST")(\(afterColumn), \(current))"
            // One query string is one implicit transaction: the lock holds writers off until setval lands,
            // and with row security off a policy that would hide rows fails the read instead.
            let rowSecurity = hasRowSecurity ? "SET LOCAL row_security = off;\n" : ""
            return rowSecurity
                + "LOCK TABLE \(source) IN SHARE ROW EXCLUSIVE MODE;\n"
                + "SELECT pg_catalog.setval(\(target), \(value), false) FROM \(source)"
        @unknown default:
            return nil
        }
    }

    static func alter(
        _ sequence: PluginSequenceDetails,
        schema: String,
        settings: PluginSequenceSettings
    ) -> String? {
        var clauses: [String] = []
        if settings.increment != sequence.increment { clauses.append("INCREMENT BY \(settings.increment)") }
        if settings.minValue != sequence.minValue { clauses.append("MINVALUE \(settings.minValue)") }
        if settings.maxValue != sequence.maxValue { clauses.append("MAXVALUE \(settings.maxValue)") }
        if settings.cacheSize != sequence.cacheSize { clauses.append("CACHE \(settings.cacheSize)") }
        if settings.cycles != sequence.cycles { clauses.append(settings.cycles ? "CYCLE" : "NO CYCLE") }
        guard !clauses.isEmpty else { return nil }
        let target = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: sequence.name)
        return "ALTER SEQUENCE \(target) \(clauses.joined(separator: " "))"
    }
}
