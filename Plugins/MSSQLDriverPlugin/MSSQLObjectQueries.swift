//
//  MSSQLObjectQueries.swift
//  MSSQLDriverPlugin
//
//  Catalog SQL for routines, triggers and views. Pure, so it is testable without a server.
//

import Foundation
import TableProMSSQLCore
import TableProPluginKit

public enum MSSQLObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        MSSQLStringLiteral.escaped(value)
    }

    /// `sys.objects.type` for everything that is a routine. The three CLR codes and the extended
    /// procedure were missing, so a database that has them listed fewer routines than it holds with
    /// nothing saying so. `AF` is a CLR aggregate, which is called like a function and belongs with
    /// them.
    public static let routineObjectTypes = ["P", "PC", "X", "FN", "IF", "TF", "FS", "FT", "AF"]

    private static let procedureObjectTypes: Set<String> = ["P", "PC", "X"]

    /// A CLR routine's body lives in sys.assembly_modules and an extended procedure's lives in a
    /// DLL, so neither has a sys.sql_modules row. Without this the reader is told the source was
    /// withheld by permissions, which is a different thing and sends them to the wrong fix.
    private static let nonSQLObjectTypes: Set<String> = ["PC", "FS", "FT", "AF", "X"]

    public static func routineHasSQLSource(forObjectType type: String) -> Bool {
        !nonSQLObjectTypes.contains(normalizedObjectType(type))
    }

    public static func routineLanguage(forObjectType type: String) -> String {
        let code = normalizedObjectType(type)
        if code == "X" { return "Extended" }
        return nonSQLObjectTypes.contains(code) ? "CLR" : "T-SQL"
    }

    private static func normalizedObjectType(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Reads sys.sql_modules, never INFORMATION_SCHEMA.ROUTINES.ROUTINE_DEFINITION. That column is
    /// nvarchar(4000) and silently returns the first 4000 characters of a longer body, which looks
    /// like a routine that ends mid-statement.
    ///
    /// The body itself is deliberately not selected. A listing needs a name, a kind and a
    /// signature; fetching every body to show a row per routine pulls a whole schema's source over
    /// the wire and drops it, and `moduleDefinition` reads the one the reader opens anyway.
    ///
    /// This query uses an XML data type method, so it needs the session `MSSQLSessionOptions`
    /// establishes. Against db-lib's own defaults the server answers `Msg 1934` and the whole list
    /// comes back empty.
    public static func routineList(schema: String) -> String {
        let schemaLiteral = MSSQLStringLiteral.quoted(schema)
        let typeList = routineObjectTypes.map { "'\($0)'" }.joined(separator: ", ")
        return """
            SELECT
                o.name,
                s.name AS schema_name,
                o.type,
                OBJECTPROPERTY(o.object_id, 'IsEncrypted') AS is_encrypted,
                CASE WHEN m.definition IS NULL THEN 1 ELSE 0 END AS definition_withheld,
                (
                    SELECT STUFF((
                        SELECT ', ' + p.name + ' ' + TYPE_NAME(p.user_type_id)
                        FROM sys.parameters p
                        WHERE p.object_id = o.object_id AND p.parameter_id > 0
                        ORDER BY p.parameter_id
                        FOR XML PATH(''), TYPE
                    ).value('.', 'nvarchar(max)'), 1, 2, '')
                ) AS parameter_list,
                (
                    SELECT TOP 1 TYPE_NAME(r.user_type_id)
                    FROM sys.parameters r
                    WHERE r.object_id = o.object_id AND r.is_output = 1 AND r.parameter_id = 0
                ) AS return_type
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
            WHERE s.name = \(schemaLiteral)
                AND o.type IN (\(typeList))
                AND o.is_ms_shipped = 0
            ORDER BY o.type, o.name
            """
    }

    /// One object's stored source and kind, found by schema and name. Routines, triggers and views all
    /// keep their text in `sys.sql_modules`, and a table has a `sys.objects` row with no module, so the
    /// same row tells a view from a table and carries the view's text.
    ///
    /// `definition` is NULL for two unrelated reasons, and the second one is the common one:
    /// `WITH ENCRYPTION`, and a caller without VIEW DEFINITION. Measured on SQL Server 2022, a user
    /// with only SELECT and EXECUTE still sees the `sys.sql_modules` row, so the row's presence
    /// cannot tell them apart. `OBJECTPROPERTY(..., 'IsEncrypted')` can, and answers for a
    /// low-privilege caller too, so it comes back beside the definition and decides which of the
    /// two the reader is told.
    ///
    /// Driven from sys.objects with sys.sql_modules joined on the outside, because a CLR routine
    /// and an extended procedure have no row there at all. Measured: the inner join this replaced
    /// returned zero rows for such an object, which the caller read as "no longer exists" for a
    /// routine sitting in the list in front of the reader. The object type comes back so the caller
    /// can say the source is not T-SQL rather than guess at a cause.
    public static func moduleDefinition(schema: String, name: String) -> String {
        """
        SELECT m.definition, OBJECTPROPERTY(o.object_id, 'IsEncrypted') AS is_encrypted, o.type
        FROM sys.objects o
        JOIN sys.schemas s ON s.schema_id = o.schema_id
        LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
        WHERE s.name = \(MSSQLStringLiteral.quoted(schema)) AND o.name = \(MSSQLStringLiteral.quoted(name))
        """
    }

    /// One row per trigger per event, so the caller folds the events back together. Filtering to
    /// one table is one more predicate on the same query, so the per-table list and the
    /// schema-wide list cannot disagree.
    public static func triggerList(schema: String, table: String?) -> String {
        let schemaLiteral = MSSQLStringLiteral.quoted(schema)
        let tablePredicate = table.map { "AND parent.name = \(MSSQLStringLiteral.quoted($0))" } ?? ""
        return """
            SELECT
                t.name,
                parent.name AS table_name,
                s.name AS schema_name,
                t.is_instead_of_trigger,
                te.type_desc AS event,
                t.is_disabled,
                OBJECT_DEFINITION(t.object_id) AS definition
            FROM sys.triggers t
            JOIN sys.objects parent ON parent.object_id = t.parent_id
            JOIN sys.schemas s ON s.schema_id = parent.schema_id
            JOIN sys.trigger_events te ON te.object_id = t.object_id
            WHERE t.parent_class = 1
                AND s.name = \(schemaLiteral)
                \(tablePredicate)
            ORDER BY parent.name, t.name, te.type_desc
            """
    }

    /// What Edit View opens when the definition cannot be read. Qualified, because a tab's schema
    /// is not a search path on SQL Server: an unqualified name binds to the login's default schema,
    /// so running the template for `sales.v` created `dbo.v` beside it. Before `CREATE OR ALTER`
    /// (2016 SP1) the view is dropped first, and the `GO` line keeps `CREATE VIEW` first in its own
    /// batch, which the server requires.
    public static func editViewTemplate(schema: String, view: String, createOrAlter: Bool) -> String {
        let qualified = MSSQLSchemaQueries.bracketed(schema: schema, table: view)
        guard !createOrAlter else {
            return "CREATE OR ALTER VIEW \(qualified) AS\nSELECT * FROM table_name;"
        }
        return """
            IF OBJECT_ID(\(MSSQLStringLiteral.quoted(qualified)), 'V') IS NOT NULL DROP VIEW \(qualified);
            GO
            CREATE VIEW \(qualified) AS
            SELECT * FROM table_name;
            """
    }

    public static func isView(objectType type: String) -> Bool {
        normalizedObjectType(type) == "V"
    }

    /// A view's source from its ``moduleDefinition(schema:name:)`` row, `nil` when no such view
    /// exists. The stored text gets its header naming the view as it is named now, since `sp_rename`
    /// leaves the old name in it. A missing definition is an encrypted view or one this login may not
    /// read, and either is said rather than handed back as an empty definition.
    public static func viewSource(row: [String?]?, schema: String, name: String) throws -> String {
        guard let row, isView(objectType: row[safe: 2].flatMap { $0 } ?? "") else {
            throw PluginObjectSourceError.notFound(name)
        }
        guard let definition = row[safe: 0].flatMap({ $0 }), !definition.isEmpty else {
            throw row[safe: 1].flatMap({ $0 }) == "1"
                ? PluginObjectSourceError.unsupported(name)
                : PluginObjectSourceError.insufficientPrivilege(name)
        }
        return MSSQLModuleHeader.namingObject(in: definition, objectKeyword: "VIEW", schema: schema, name: name)
    }

    /// `sys.objects.type` is `char(2)`, so a one-letter code arrives padded. Anything unrecognised
    /// reads as a function, which is what a future routine code is far more likely to be.
    public static func routineKind(forObjectType type: String) -> String {
        procedureObjectTypes.contains(normalizedObjectType(type)) ? "PROCEDURE" : "FUNCTION"
    }
}
