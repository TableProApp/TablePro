namespace TablePro.Drivers.SqlServer;

/// <summary>
/// Catalog reads against the <c>sys</c> views, bound to <c>@schema</c> and <c>@table</c>. Lists are built with
/// FOR XML PATH rather than STRING_AGG so the queries run on SQL Server 2012 and later.
/// </summary>
internal static class SqlServerCatalog
{
    private const string ObjectId = "OBJECT_ID(QUOTENAME(@schema) + N'.' + QUOTENAME(@table))";

    // How SSMS spells a column type: lengths in characters, max for -1, precision and scale where they apply.
    private const string TypeName = """
        CASE WHEN t.is_user_defined = 1 THEN QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
             WHEN t.name IN (N'varchar', N'char', N'varbinary', N'binary')
                  THEN t.name + N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length AS nvarchar(10)) END + N')'
             WHEN t.name IN (N'nvarchar', N'nchar')
                  THEN t.name + N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length / 2 AS nvarchar(10)) END + N')'
             WHEN t.name IN (N'decimal', N'numeric')
                  THEN t.name + N'(' + CAST(c.precision AS nvarchar(10)) + N',' + CAST(c.scale AS nvarchar(10)) + N')'
             WHEN t.name IN (N'datetime2', N'time', N'datetimeoffset')
                  THEN t.name + N'(' + CAST(c.scale AS nvarchar(10)) + N')'
             ELSE t.name END
        """;

    public const string Databases = "SELECT name FROM sys.databases WHERE HAS_DBACCESS(name) = 1 ORDER BY name";

    // Schemas 16384 to 16399 belong to the fixed database roles and hold nothing a user made.
    public const string Schemas = """
        SELECT name FROM sys.schemas
        WHERE name NOT IN (N'sys', N'INFORMATION_SCHEMA', N'guest') AND schema_id < 16384
        ORDER BY name
        """;

    public const string Objects = """
        SELECT o.name, RTRIM(o.type),
               CASE WHEN o.type = 'U'
                    THEN (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = o.object_id AND p.index_id IN (0, 1)) END,
               CAST(ep.value AS nvarchar(max))
        FROM sys.objects o
        JOIN sys.schemas s ON s.schema_id = o.schema_id
        LEFT JOIN sys.extended_properties ep
               ON ep.class = 1 AND ep.major_id = o.object_id AND ep.minor_id = 0 AND ep.name = N'MS_Description'
        WHERE s.name = @schema AND o.is_ms_shipped = 0
          AND o.type IN ('U', 'V', 'P', 'PC', 'FN', 'IF', 'TF', 'FS', 'FT', 'SO')
        ORDER BY o.type, o.name
        """;

    public const string Columns = $$"""
        SELECT c.name,
               {{TypeName}},
               c.is_nullable,
               OBJECT_DEFINITION(c.default_object_id),
               CAST(CASE WHEN EXISTS (
                        SELECT 1 FROM sys.index_columns ic
                        JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                        WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id) THEN 1 ELSE 0 END AS bit),
               c.is_identity,
               CAST(ep.value AS nvarchar(max))
        FROM sys.columns c
        JOIN sys.types t ON t.user_type_id = c.user_type_id
        LEFT JOIN sys.extended_properties ep
               ON ep.class = 1 AND ep.major_id = c.object_id AND ep.minor_id = c.column_id AND ep.name = N'MS_Description'
        WHERE c.object_id = {{ObjectId}}
        ORDER BY c.column_id
        """;

    public const string Indexes = $$"""
        SELECT i.name, i.is_unique, i.is_primary_key, i.type_desc, col.name
        FROM sys.indexes i
        JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
        JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
        WHERE i.object_id = {{ObjectId}} AND i.type > 0 AND i.is_hypothetical = 0
        ORDER BY i.is_primary_key DESC, i.name, ic.key_ordinal, ic.index_column_id
        """;

    public const string ForeignKeys = $$"""
        SELECT fk.name, pc.name, rs.name, rt.name, rc.name, fk.update_referential_action_desc, fk.delete_referential_action_desc
        FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
        JOIN sys.objects rt ON rt.object_id = fk.referenced_object_id
        JOIN sys.schemas rs ON rs.schema_id = rt.schema_id
        JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
        WHERE fk.parent_object_id = {{ObjectId}}
        ORDER BY fk.name, fkc.constraint_column_id
        """;

    public const string Triggers = $$"""
        SELECT t.name,
               CASE WHEN t.is_instead_of_trigger = 1 THEN 'INSTEAD OF' ELSE 'AFTER' END,
               STUFF((SELECT N' OR ' + te.type_desc FROM sys.trigger_events te WHERE te.object_id = t.object_id
                      FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 4, N''),
               OBJECT_DEFINITION(t.object_id)
        FROM sys.triggers t
        WHERE t.parent_id = {{ObjectId}}
        ORDER BY t.name
        """;

    public const string ColumnDefinitions = $$"""
        SELECT QUOTENAME(c.name) + N' ' +
               CASE WHEN c.is_computed = 1
                    THEN N'AS ' + cc.definition + CASE WHEN cc.is_persisted = 1 THEN N' PERSISTED' ELSE N'' END
                    ELSE {{TypeName}}
                         + CASE WHEN c.is_identity = 1
                                THEN N' IDENTITY(' + CAST(idc.seed_value AS nvarchar(40)) + N',' + CAST(idc.increment_value AS nvarchar(40)) + N')'
                                ELSE N'' END
                         + CASE WHEN c.collation_name IS NOT NULL
                                 AND c.collation_name COLLATE DATABASE_DEFAULT
                                     <> CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS sysname) COLLATE DATABASE_DEFAULT
                                THEN N' COLLATE ' + c.collation_name ELSE N'' END
                         + CASE WHEN c.is_nullable = 1 THEN N' NULL' ELSE N' NOT NULL' END
                         + CASE WHEN dc.definition IS NOT NULL
                                THEN N' CONSTRAINT ' + QUOTENAME(dc.name) + N' DEFAULT ' + dc.definition ELSE N'' END
               END
        FROM sys.columns c
        JOIN sys.types t ON t.user_type_id = c.user_type_id
        LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
        LEFT JOIN sys.identity_columns idc ON idc.object_id = c.object_id AND idc.column_id = c.column_id
        LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
        WHERE c.object_id = {{ObjectId}}
        ORDER BY c.column_id
        """;

    public const string KeyConstraintDefinitions = $$"""
        SELECT N'CONSTRAINT ' + QUOTENAME(i.name) + CASE WHEN i.is_primary_key = 1 THEN N' PRIMARY KEY ' ELSE N' UNIQUE ' END
               + i.type_desc COLLATE DATABASE_DEFAULT + N' ('
               + STUFF((SELECT N', ' + QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
                        FROM sys.index_columns ic
                        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                        ORDER BY ic.key_ordinal
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')'
        FROM sys.indexes i
        WHERE i.object_id = {{ObjectId}} AND (i.is_primary_key = 1 OR i.is_unique_constraint = 1)
        ORDER BY i.is_primary_key DESC, i.name
        """;

    public const string CheckConstraintDefinitions = $$"""
        SELECT N'CONSTRAINT ' + QUOTENAME(name) + N' CHECK ' + definition
        FROM sys.check_constraints
        WHERE parent_object_id = {{ObjectId}}
        ORDER BY name
        """;

    public const string ForeignKeyDefinitions = $$"""
        SELECT N'CONSTRAINT ' + QUOTENAME(fk.name) + N' FOREIGN KEY ('
               + STUFF((SELECT N', ' + QUOTENAME(c.name) FROM sys.foreign_key_columns k
                        JOIN sys.columns c ON c.object_id = k.parent_object_id AND c.column_id = k.parent_column_id
                        WHERE k.constraint_object_id = fk.object_id ORDER BY k.constraint_column_id
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
               + N') REFERENCES ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.referenced_object_id)) + N'.' + QUOTENAME(OBJECT_NAME(fk.referenced_object_id)) + N' ('
               + STUFF((SELECT N', ' + QUOTENAME(c.name) FROM sys.foreign_key_columns k
                        JOIN sys.columns c ON c.object_id = k.referenced_object_id AND c.column_id = k.referenced_column_id
                        WHERE k.constraint_object_id = fk.object_id ORDER BY k.constraint_column_id
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
               + N')'
               + CASE WHEN fk.delete_referential_action <> 0 THEN N' ON DELETE ' + REPLACE(fk.delete_referential_action_desc, N'_', N' ') ELSE N'' END
               + CASE WHEN fk.update_referential_action <> 0 THEN N' ON UPDATE ' + REPLACE(fk.update_referential_action_desc, N'_', N' ') ELSE N'' END
        FROM sys.foreign_keys fk
        WHERE fk.parent_object_id = {{ObjectId}}
        ORDER BY fk.name
        """;

    public const string IndexDefinitions = $$"""
        SELECT N'CREATE ' + CASE WHEN i.is_unique = 1 THEN N'UNIQUE ' ELSE N'' END + i.type_desc COLLATE DATABASE_DEFAULT
               + N' INDEX ' + QUOTENAME(i.name) + N' ON ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table) + N' ('
               + STUFF((SELECT N', ' + QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
                        FROM sys.index_columns ic
                        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                        ORDER BY ic.key_ordinal
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')'
               + COALESCE(N' INCLUDE (' + STUFF((SELECT N', ' + QUOTENAME(c.name)
                        FROM sys.index_columns ic
                        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
                        ORDER BY ic.index_column_id
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')', N'')
               + CASE WHEN i.has_filter = 1 THEN N' WHERE ' + i.filter_definition ELSE N'' END
        FROM sys.indexes i
        WHERE i.object_id = {{ObjectId}} AND i.type IN (1, 2) AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
          AND i.is_hypothetical = 0
        ORDER BY i.name
        """;

    public const string ModuleDefinition = $"SELECT OBJECT_DEFINITION({ObjectId})";

    public const string SequenceDefinition = $$"""
        SELECT N'CREATE SEQUENCE ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table) + N' AS ' + TYPE_NAME(s.user_type_id)
               + N' START WITH ' + CAST(s.start_value AS nvarchar(40)) + N' INCREMENT BY ' + CAST(s.increment AS nvarchar(40))
               + N' MINVALUE ' + CAST(s.minimum_value AS nvarchar(40)) + N' MAXVALUE ' + CAST(s.maximum_value AS nvarchar(40))
               + CASE WHEN s.is_cycling = 1 THEN N' CYCLE' ELSE N' NO CYCLE' END
               + CASE WHEN s.is_cached = 0 THEN N' NO CACHE'
                      WHEN s.cache_size IS NOT NULL THEN N' CACHE ' + CAST(s.cache_size AS nvarchar(20)) ELSE N'' END
        FROM sys.sequences s
        WHERE s.object_id = {{ObjectId}}
        """;

    public const string Activity = """
        SELECT s.session_id, s.login_name, DB_NAME(COALESCE(r.database_id, s.database_id)) AS database_name, s.host_name,
               s.program_name, s.status, r.status AS request_status, r.command, r.wait_type, r.blocking_session_id,
               s.login_time, r.start_time, r.total_elapsed_time, s.cpu_time, s.reads, s.writes, t.text AS sql_text
        FROM sys.dm_exec_sessions s
        LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
        WHERE s.is_user_process = 1
        ORDER BY s.session_id
        """;

    public const string Users = """
        SELECT name, type_desc, is_disabled, default_database_name, create_date, modify_date
        FROM sys.server_principals
        WHERE type IN ('S', 'U', 'G', 'R', 'E', 'X', 'C', 'K') AND name NOT LIKE N'##%'
        ORDER BY name
        """;

    public const string Configuration = """
        SELECT name, value, value_in_use, minimum, maximum, is_dynamic, is_advanced, description
        FROM sys.configurations
        ORDER BY name
        """;

    // parent_column_id is 0 for a check over several columns, so the columns come from the expression dependencies,
    // one row each, which lists them for both shapes and needs no FOR XML that would entity-escape a name.
    public const string CheckConstraints = $"""
        SELECT cc.name, cc.definition, cc.is_not_trusted, COL_NAME(d.referenced_id, d.referenced_minor_id)
        FROM sys.check_constraints cc
        LEFT JOIN sys.sql_expression_dependencies d ON d.referencing_id = cc.object_id AND d.referenced_minor_id > 0
        WHERE cc.parent_object_id = {ObjectId}
        ORDER BY cc.name, d.referenced_minor_id
        """;

    // Compression is per partition; the first partition of the heap or clustered index stands for the table.
    public const string TableOptions = $"""
        SELECT CAST(ep.value AS nvarchar(max)), t.lock_escalation_desc,
               (SELECT TOP (1) p.data_compression_desc FROM sys.partitions p
                WHERE p.object_id = t.object_id AND p.index_id IN (0, 1) ORDER BY p.partition_number),
               (SELECT TOP (1) ds.name FROM sys.indexes i JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
                WHERE i.object_id = t.object_id AND i.index_id IN (0, 1))
        FROM sys.tables t
        LEFT JOIN sys.extended_properties ep ON ep.class = 1 AND ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = N'MS_Description'
        WHERE t.object_id = {ObjectId}
        """;
}
