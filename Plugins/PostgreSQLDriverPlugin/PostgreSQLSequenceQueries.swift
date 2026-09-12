//
//  PostgreSQLSequenceQueries.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

struct PostgreSQLSequenceDefinition: Equatable, Sendable {
    let name: String
    let startValue: String?
    let minValue: String?
    let maxValue: String?
    let increment: String?
    let cycles: Bool
    let lastValue: String?
    let needsLastValueRead: Bool

    func withLastValue(_ value: String?) -> PostgreSQLSequenceDefinition {
        PostgreSQLSequenceDefinition(
            name: name,
            startValue: startValue,
            minValue: minValue,
            maxValue: maxValue,
            increment: increment,
            cycles: cycles,
            lastValue: value,
            needsLastValueRead: false
        )
    }

    var ddl: String {
        let quotedName = PostgreSQLObjectQueries.quoteIdentifier(name)
        let parameters = [startValue, minValue, maxValue, increment]
        var statement: String
        if parameters.allSatisfy({ $0 == nil }) {
            statement = "CREATE SEQUENCE \(quotedName);"
        } else {
            statement = "CREATE SEQUENCE \(quotedName) INCREMENT BY \(increment ?? "1")"
                + " MINVALUE \(minValue ?? "1") MAXVALUE \(maxValue ?? "9223372036854775807")"
                + " START WITH \(startValue ?? "1")\(cycles ? " CYCLE" : "");"
        }
        guard let lastValue, Int64(lastValue) != nil else { return statement }
        let target = PostgreSQLObjectQueries.quoteLiteral(quotedName)
        statement += "\nSELECT pg_catalog.setval(\(target), \(lastValue), true);"
        return statement
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

    static func sequenceList(schema: String, dependentOnTable table: String?, source: Source) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let dependency = table.map { dependencyPredicate(schemaLiteral: schemaLiteral, table: $0) } ?? ""
        switch source {
        case .sequencesView:
            return """
                SELECT s.sequencename,
                       s.start_value,
                       s.min_value,
                       s.max_value,
                       s.increment_by,
                       s.cycle,
                       s.last_value,
                       false AS needs_last_value_read
                FROM pg_catalog.pg_sequences s
                JOIN pg_catalog.pg_namespace n ON n.nspname = s.schemaname
                JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = s.sequencename
                WHERE s.schemaname = \(schemaLiteral)\(dependency)
                ORDER BY s.sequencename
                """
        case .sequenceParameters:
            return """
                SELECT s.relname,
                       \(parameter("start_value")),
                       \(parameter("minimum_value")),
                       \(parameter("maximum_value")),
                       \(parameter("increment")),
                       \(parameter("cycle_option")),
                       NULL::bigint AS last_value,
                       s.readable
                FROM (
                    SELECT c.oid,
                           c.relname,
                           pg_catalog.has_sequence_privilege(c.oid, 'SELECT,USAGE,UPDATE') AS can_read_parameters,
                           pg_catalog.has_sequence_privilege(c.oid, 'SELECT') AS readable
                    FROM pg_catalog.pg_class c
                    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                    WHERE c.relkind = 'S'
                        AND n.nspname = \(schemaLiteral)\(dependency)
                    OFFSET 0
                ) s
                ORDER BY s.relname
                """
        }
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
            return PostgreSQLSequenceDefinition(
                name: name,
                startValue: row[safe: 1]?.asText,
                minValue: row[safe: 2]?.asText,
                maxValue: row[safe: 3]?.asText,
                increment: row[safe: 4]?.asText,
                cycles: PostgreSQLCatalogBoolean.isTrue(row[safe: 5]?.asText),
                lastValue: row[safe: 6]?.asText,
                needsLastValueRead: PostgreSQLCatalogBoolean.isTrue(row[safe: 7]?.asText)
            )
        }
    }

    private static func dependencyPredicate(schemaLiteral: String, table: String) -> String {
        """

                  AND EXISTS (
                        SELECT 1
                        FROM pg_catalog.pg_attrdef ad
                        JOIN pg_catalog.pg_depend d
                            ON d.classid = 'pg_catalog.pg_attrdef'::pg_catalog.regclass
                            AND d.objid = ad.oid
                            AND d.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
                            AND d.refobjid = c.oid
                        JOIN pg_catalog.pg_class t ON t.oid = ad.adrelid
                        JOIN pg_catalog.pg_namespace tn ON tn.oid = t.relnamespace
                        WHERE t.relname = \(PostgreSQLObjectQueries.quoteLiteral(table))
                            AND tn.nspname = \(schemaLiteral))
        """
    }
}
