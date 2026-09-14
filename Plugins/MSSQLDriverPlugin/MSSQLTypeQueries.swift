//
//  MSSQLTypeQueries.swift
//  MSSQLDriverPlugin
//
//  Catalog SQL for user-defined types. Pure, so it is testable without a server.
//

import Foundation
import TableProMSSQLCore

public enum MSSQLTypeQueries {
    /// SQL Server has three shapes of user-defined type and `sys.types` tells them apart with two
    /// flags rather than a kind column.
    public enum Kind: String {
        case alias = "ALIAS"
        case table = "TABLE"
        case clr = "CLR"
    }

    /// Rebuilds the base type the way the user wrote it. `max_length` is in BYTES, so an
    /// `nvarchar(320)` reports 640 and has to be halved, and -1 means MAX. Measured against a
    /// server holding `nvarchar(320)`, `nvarchar(max)`, `varchar(32)` and `decimal(18,4)`: every
    /// spelling came back matching the original `CREATE TYPE`.
    private static let baseTypeSpelling = """
        CASE WHEN t.is_table_type = 1 OR t.is_assembly_type = 1 THEN NULL
             WHEN bt.name IN ('nvarchar', 'nchar')
                 THEN bt.name + '(' + CASE WHEN t.max_length = -1 THEN 'max'
                      ELSE CONVERT(varchar(11), t.max_length / 2) END + ')'
             WHEN bt.name IN ('varchar', 'char', 'varbinary', 'binary')
                 THEN bt.name + '(' + CASE WHEN t.max_length = -1 THEN 'max'
                      ELSE CONVERT(varchar(11), t.max_length) END + ')'
             WHEN bt.name IN ('decimal', 'numeric')
                 THEN bt.name + '(' + CONVERT(varchar(11), t.precision) + ',' + CONVERT(varchar(11), t.scale) + ')'
             WHEN bt.name IN ('datetime2', 'time', 'datetimeoffset')
                 THEN bt.name + '(' + CONVERT(varchar(11), t.scale) + ')'
             ELSE bt.name END
        """

    /// The identity is `user_type_id`, which is stable for the life of the type and survives a
    /// rename, so a re-fetch never keys on the name or the kind.
    public static func userDefinedTypeList(schema: String) -> String {
        """
        SELECT
            t.name,
            s.name AS schema_name,
            CONVERT(varchar(11), t.user_type_id) AS identity_id,
            CASE WHEN t.is_table_type = 1 THEN 'TABLE'
                 WHEN t.is_assembly_type = 1 THEN 'CLR'
                 ELSE 'ALIAS' END AS kind,
            \(baseTypeSpelling) AS base_type,
            CONVERT(varchar(1), t.is_nullable) AS is_nullable,
            t.collation_name,
            a.name AS assembly_name,
            at.assembly_class,
            CONVERT(varchar(1), ISNULL(tt.is_memory_optimized, 0)) AS is_memory_optimized
        FROM sys.types t
        JOIN sys.schemas s ON s.schema_id = t.schema_id
        LEFT JOIN sys.types bt ON bt.user_type_id = t.system_type_id AND bt.is_user_defined = 0
        LEFT JOIN sys.assembly_types at ON at.user_type_id = t.user_type_id
        LEFT JOIN sys.assemblies a ON a.assembly_id = at.assembly_id
        LEFT JOIN sys.table_types tt ON tt.user_type_id = t.user_type_id
        WHERE t.is_user_defined = 1 AND s.name = \(MSSQLStringLiteral.quoted(schema))
        ORDER BY t.name
        """
    }

    /// A table type's columns, in declaration order. `sys.table_types.type_table_object_id` is the
    /// hidden table behind the type, which is what `sys.columns` is keyed on.
    public static func tableTypeColumns(schema: String, name: String) -> String {
        """
        SELECT
            c.name,
            CASE WHEN c.is_computed = 1 THEN NULL
                 WHEN bt.is_user_defined = 1
                     THEN '[' + REPLACE(SCHEMA_NAME(bt.schema_id), ']', ']]') + '].['
                          + REPLACE(bt.name, ']', ']]') + ']'
                 WHEN bt.name IN ('nvarchar', 'nchar')
                     THEN bt.name + '(' + CASE WHEN c.max_length = -1 THEN 'max'
                          ELSE CONVERT(varchar(11), c.max_length / 2) END + ')'
                 WHEN bt.name IN ('varchar', 'char', 'varbinary', 'binary')
                     THEN bt.name + '(' + CASE WHEN c.max_length = -1 THEN 'max'
                          ELSE CONVERT(varchar(11), c.max_length) END + ')'
                 WHEN bt.name IN ('decimal', 'numeric')
                     THEN bt.name + '(' + CONVERT(varchar(11), c.precision) + ',' + CONVERT(varchar(11), c.scale) + ')'
                 WHEN bt.name IN ('datetime2', 'time', 'datetimeoffset')
                     THEN bt.name + '(' + CONVERT(varchar(11), c.scale) + ')'
                 ELSE bt.name END AS column_type,
            CONVERT(varchar(1), c.is_nullable) AS is_nullable,
            CASE WHEN c.is_identity = 1
                 THEN CONVERT(varchar(40), ic.seed_value) + ',' + CONVERT(varchar(40), ic.increment_value) END AS identity_spec,
            cc.definition AS computed_definition,
            dc.definition AS default_definition,
            c.collation_name
        FROM sys.table_types tt
        JOIN sys.schemas s ON s.schema_id = tt.schema_id
        JOIN sys.columns c ON c.object_id = tt.type_table_object_id
        LEFT JOIN sys.types bt ON bt.user_type_id = c.user_type_id
        LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
        LEFT JOIN sys.default_constraints dc
            ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
        WHERE tt.is_user_defined = 1
            AND s.name = \(MSSQLStringLiteral.quoted(schema))
            AND tt.name = \(MSSQLStringLiteral.quoted(name))
        ORDER BY c.column_id
        """
    }

    /// One row per index key column rather than a comma-joined aggregate. A column name may legally
    /// contain a comma (`[a,b]` is a valid identifier), which splitting turns into two columns, and
    /// an aggregate has nowhere to carry `is_descending_key`, so a `DESC` key silently replayed as
    /// ascending. Structured rows lose neither.
    public static func tableTypeIndexes(schema: String, name: String) -> String {
        """
        SELECT
            i.name,
            CONVERT(varchar(1), i.is_primary_key) AS is_primary_key,
            CONVERT(varchar(1), i.is_unique) AS is_unique,
            i.type_desc,
            c.name AS key_column,
            CONVERT(varchar(1), ic.is_descending_key) AS is_descending,
            CONVERT(varchar(11), i.index_id) AS index_id,
            CONVERT(varchar(11), ISNULL(hi.bucket_count, 0)) AS bucket_count
        FROM sys.table_types tt
        JOIN sys.schemas s ON s.schema_id = tt.schema_id
        JOIN sys.indexes i ON i.object_id = tt.type_table_object_id
        JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        LEFT JOIN sys.hash_indexes hi ON hi.object_id = i.object_id AND hi.index_id = i.index_id
        WHERE tt.is_user_defined = 1
            AND i.type > 0
            AND ic.is_included_column = 0
            AND s.name = \(MSSQLStringLiteral.quoted(schema))
            AND tt.name = \(MSSQLStringLiteral.quoted(name))
        ORDER BY i.index_id, ic.key_ordinal
        """
    }

    /// A CHECK on a table type is part of what the type validates, so a rebuilt statement that
    /// drops it recreates a type with weaker validation than the original.
    public static func tableTypeCheckConstraints(schema: String, name: String) -> String {
        """
        SELECT cc.definition
        FROM sys.table_types tt
        JOIN sys.schemas s ON s.schema_id = tt.schema_id
        JOIN sys.check_constraints cc ON cc.parent_object_id = tt.type_table_object_id
        WHERE tt.is_user_defined = 1
            AND s.name = \(MSSQLStringLiteral.quoted(schema))
            AND tt.name = \(MSSQLStringLiteral.quoted(name))
        ORDER BY cc.object_id
        """
    }

    /// The database's own collation. A column keeps its collation in `sys.columns` whether or not
    /// it differs from the database's, so without this every column would carry a `COLLATE` clause
    /// the user never wrote.
    public static let databaseCollation = "SELECT CONVERT(varchar(128), DATABASEPROPERTYEX(DB_NAME(), 'Collation'))"
}
