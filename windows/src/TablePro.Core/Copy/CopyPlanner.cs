using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Schema;

namespace TablePro.Core.Copy;

/// <summary>
/// Reads the source objects and the target schema and decides, before anything runs, what each object becomes: the
/// target's column types, the indexes and keys that follow it, and whether it is created, replaced, filled or skipped.
/// </summary>
public static class CopyPlanner
{
    private static readonly HashSet<ObjectKind> DefinitionKinds =
        [ObjectKind.View, ObjectKind.MaterializedView, ObjectKind.Function, ObjectKind.Procedure, ObjectKind.Sequence, ObjectKind.Trigger];

    public static async Task<CopyPlan> PlanAsync(CopyRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var sourceEngine = request.Source.Profile.Engine;
        var targetEngine = request.Target.Profile.Engine;
        var warnings = new List<string>();
        if (CopyTypeMapper.Refusal(sourceEngine, targetEngine) is { } refusal)
        {
            return new CopyPlan(
                [.. request.Objects.Where(o => o.Kind == ObjectKind.Table).Select(o => new CopyTablePlan(o, Empty(o.Name), o.Name with { Schema = request.TargetSchema }, CopyAction.Skip))],
                [.. request.Objects.Where(o => DefinitionKinds.Contains(o.Kind)).Select(o => new CopyDefinitionPlan(o, o.Name with { Schema = request.TargetSchema }, CopyAction.Skip))])
            {
                Warnings = [refusal],
                CrossesEngines = true,
            };
        }

        var shares = CopyTypeMapper.SharesTypes(sourceEngine, targetEngine);
        var canCreate = request.Target is ISchemaDdlProvider;
        if (request.IncludesStructure && !canCreate)
        {
            warnings.Add(CoreStrings.Format("Copy/CannotCreateTables", EngineDescriptor.For(targetEngine).DisplayName));
        }

        if (request.Target.Profile.IsReadOnly)
        {
            warnings.Add(CoreStrings.Get("Copy/TargetReadOnly"));
        }

        var existing = new Dictionary<string, DatabaseObject>(StringComparer.OrdinalIgnoreCase);
        foreach (var obj in await request.Target.GetObjectsAsync(request.TargetSchema, cancellationToken))
        {
            existing.TryAdd(obj.Name.Name, obj);
        }

        var tables = request.Objects.Where(o => o.Kind == ObjectKind.Table).ToArray();
        var structures = new List<TableStructure>(tables.Length);
        foreach (var table in tables)
        {
            structures.Add(await request.Source.GetStructureAsync(table.Name, cancellationToken));
        }

        var copied = tables.Select(t => t.Name.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var plans = new List<CopyTablePlan>(tables.Length);
        for (var i = 0; i < tables.Length; i++)
        {
            plans.Add(await PlanTableAsync(request, tables[i], structures[i], existing, copied, shares, canCreate, cancellationToken));
        }

        var definitions = request.Objects.Where(o => DefinitionKinds.Contains(o.Kind)).Select(o => PlanDefinition(request, o, existing, shares)).ToArray();
        return new CopyPlan(ParentsFirst(plans), definitions) { CrossesEngines = !shares, Warnings = warnings };
    }

    private static TableStructure Empty(ObjectName name) => new(name, [], [], [], []);

    private static async Task<CopyTablePlan> PlanTableAsync(
        CopyRequest request,
        DatabaseObject table,
        TableStructure structure,
        Dictionary<string, DatabaseObject> existing,
        HashSet<string> copied,
        bool shares,
        bool canCreate,
        CancellationToken cancellationToken)
    {
        var sourceEngine = request.Source.Profile.Engine;
        var targetEngine = request.Target.Profile.Engine;
        var target = new ObjectName(request.TargetSchema, structure.Table.Name);
        var notes = new List<string>();
        var exists = existing.TryGetValue(target.Name, out var found);
        if (exists)
        {
            target = found!.Name;
        }

        CopyAction action;
        if (exists && found!.Kind != ObjectKind.Table)
        {
            action = CopyAction.Skip;
            notes.Add(CoreStrings.Format("Copy/TargetHasOtherObject", target.Name));
        }
        else if (!exists)
        {
            action = request.IncludesStructure && canCreate ? CopyAction.Create : CopyAction.Skip;
            if (action == CopyAction.Skip)
            {
                notes.Add(request.IncludesStructure ? CoreStrings.Get("Copy/TargetCannotCreate") : CoreStrings.Format("Copy/NoTableToAddRows", target.Name));
            }
        }
        else
        {
            action = request.ExistingPolicy switch
            {
                CopyExistingPolicy.Replace when request.IncludesStructure && !canCreate => CopyAction.Skip,
                CopyExistingPolicy.Replace => CopyAction.Replace,
                CopyExistingPolicy.AppendData when request.IncludesData => CopyAction.Append,
                _ => CopyAction.Skip,
            };
            if (action == CopyAction.Skip)
            {
                notes.Add(CoreStrings.Format("Copy/AlreadyExists", target.Name));
            }
        }

        var recreates = request.IncludesStructure && action is CopyAction.Create or CopyAction.Replace;
        var keyed = structure.PrimaryKey
            .Concat(structure.Indexes.SelectMany(i => i.Columns))
            .Concat(structure.ForeignKeys.SelectMany(k => k.Columns))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var columns = new List<ColumnDefinition>(structure.Columns.Count);
        var shapes = new Dictionary<string, SqlTypeShape>(StringComparer.OrdinalIgnoreCase);
        var inserts = new List<(string, string)>(structure.Columns.Count);
        var identity = new List<string>();
        var ordered = structure.Columns.OrderBy(c => c.Ordinal).ToArray();
        if (recreates)
        {
            foreach (var column in ordered)
            {
                var (definition, columnNotes) = CopyTypeMapper.Translate(column, sourceEngine, targetEngine, request.Target.ServerVersion, keyed.Contains(column.Name), request.IncludesData);
                columns.Add(definition);
                notes.AddRange(columnNotes);
                var sourceShape = SqlTypeShape.Parse(column.DataType, sourceEngine);
                if (shares && sourceShape.Category == SqlTypeCategory.ServerComputed)
                {
                    continue;
                }

                shapes[column.Name] = SqlTypeShape.Parse(definition.DataType, targetEngine);
                inserts.Add((column.Name, column.Name));
                if (definition.IsIdentity && CopyTypeMapper.FamilyOf(targetEngine) == TypeFamily.PostgreSql)
                {
                    identity.Add(column.Name);
                }
            }
        }
        else if (action is CopyAction.Append or CopyAction.Replace)
        {
            var targetStructure = await request.Target.GetStructureAsync(target, cancellationToken);
            var byName = targetStructure.Columns.ToDictionary(c => c.Name, StringComparer.OrdinalIgnoreCase);
            foreach (var column in ordered)
            {
                if (!byName.TryGetValue(column.Name, out var targetColumn))
                {
                    notes.Add(CoreStrings.Format("Copy/ColumnNotInTarget", column.Name));
                    continue;
                }

                var targetShape = SqlTypeShape.Parse(targetColumn.DataType, targetEngine);
                if (targetShape.Category == SqlTypeCategory.ServerComputed || SqlTypeShape.Parse(column.DataType, sourceEngine).Category == SqlTypeCategory.ServerComputed)
                {
                    continue;
                }

                if (targetColumn.IsIdentity && targetEngine == DatabaseEngine.SqlServer)
                {
                    notes.Add(CoreStrings.Format("Copy/SqlServerIdentityLeftOut", column.Name));
                    continue;
                }

                shapes[targetColumn.Name] = targetShape;
                inserts.Add((column.Name, targetColumn.Name));
            }
        }

        var indexes = recreates
            ? structure.Indexes
                .Where(i => !i.IsPrimary && i.Columns.Count > 0 && i.Columns.All(c => ordered.Any(o => string.Equals(o.Name, c, StringComparison.OrdinalIgnoreCase))))
                .Select(i => new IndexDefinition(IndexName(i, structure.Table.Name), i.Columns, i.IsUnique))
                .ToArray()
            : [];
        var keys = recreates ? ForeignKeys(structure, request, existing, copied, notes) : [];

        return new CopyTablePlan(table, structure, target, action)
        {
            Columns = columns,
            Indexes = indexes,
            ForeignKeys = keys,
            InsertColumns = inserts,
            TargetShapes = shapes,
            PageOrder = PageOrder(structure, sourceEngine),
            Notes = notes,
            IdentityColumns = request.IncludesData ? identity : [],
        };
    }

    // SQLite names the index behind a UNIQUE constraint itself and refuses that name in a CREATE INDEX.
    private static string IndexName(IndexInfo index, string table) =>
        index.Name.StartsWith("sqlite_autoindex_", StringComparison.OrdinalIgnoreCase)
            ? $"{table}_{string.Join('_', index.Columns)}_{(index.IsUnique ? "key" : "idx")}"
            : index.Name;

    // A key to a table this copy brings, or to one the target schema already has, follows the table; any other key
    // would point at nothing in the target and is left out.
    private static ForeignKeyDefinition[] ForeignKeys(
        TableStructure structure, CopyRequest request, Dictionary<string, DatabaseObject> existing, HashSet<string> copied, List<string> notes)
    {
        var targetEngine = request.Target.Profile.Engine;
        var sourceSchema = structure.Table.Schema;
        var keys = new List<ForeignKeyDefinition>(structure.ForeignKeys.Count);
        foreach (var key in structure.ForeignKeys)
        {
            var referenced = key.ReferencedTable;
            var sameSchema = string.IsNullOrEmpty(referenced.Schema) || string.Equals(referenced.Schema, sourceSchema, StringComparison.OrdinalIgnoreCase);
            ObjectName? target = null;
            if (sameSchema && copied.Contains(referenced.Name))
            {
                target = new ObjectName(request.TargetSchema, referenced.Name);
            }
            else if (sameSchema && existing.TryGetValue(referenced.Name, out var present) && present.Kind == ObjectKind.Table)
            {
                target = present.Name;
            }

            if (target is not { } name)
            {
                notes.Add(CoreStrings.Format("Copy/ForeignKeyLeftOut", key.Name, referenced));
                continue;
            }

            keys.Add(new ForeignKeyDefinition(key.Name, key.Columns, name, key.ReferencedColumns, Action(key.OnDelete, targetEngine, onDelete: true), Action(key.OnUpdate, targetEngine, onDelete: false)));
        }

        return [.. keys];
    }

    /// <summary>A referential action the target accepts; NO ACTION and anything it lacks become the default.</summary>
    private static string? Action(string? action, DatabaseEngine target, bool onDelete)
    {
        var normalized = action?.Trim().ToUpperInvariant();
        if (string.IsNullOrEmpty(normalized) || normalized == "NO ACTION")
        {
            return null;
        }

        return CopyTypeMapper.FamilyOf(target) switch
        {
            // Oracle has no ON UPDATE, and deletes only cascade or set null.
            TypeFamily.Oracle => onDelete && normalized is "CASCADE" or "SET NULL" ? normalized : null,
            TypeFamily.SqlServer => normalized == "RESTRICT" ? null : normalized,
            _ => normalized,
        };
    }

    /// <summary>
    /// The primary key, else a unique index, else every column that can be sorted: rows that tie on all of them are
    /// identical, so which copy comes first does not matter. Empty means the table is read in one page.
    /// </summary>
    public static IReadOnlyList<string> PageOrder(TableStructure structure, DatabaseEngine engine)
    {
        ArgumentNullException.ThrowIfNull(structure);
        if (structure.PrimaryKey.Count > 0)
        {
            return structure.PrimaryKey;
        }

        var unique = structure.Indexes.FirstOrDefault(i => i.IsUnique && i.Columns.Count > 0
            && i.Columns.All(c => structure.Columns.Any(col => string.Equals(col.Name, c, StringComparison.OrdinalIgnoreCase) && !col.IsNullable)));
        if (unique is not null)
        {
            return unique.Columns;
        }

        var family = CopyTypeMapper.FamilyOf(engine);
        return [.. structure.Columns.OrderBy(c => c.Ordinal).Where(c => Sortable(SqlTypeShape.Parse(c.DataType, engine), family)).Select(c => c.Name)];
    }

    private static bool Sortable(SqlTypeShape shape, TypeFamily family) => shape.Category switch
    {
        SqlTypeCategory.Integer or SqlTypeCategory.Decimal or SqlTypeCategory.Float or SqlTypeCategory.Boolean or SqlTypeCategory.Date
            or SqlTypeCategory.Time or SqlTypeCategory.Timestamp or SqlTypeCategory.Uuid or SqlTypeCategory.Enumeration => true,

        // SQL Server cannot sort ntext or varchar(max) in every version, nor Oracle a CLOB.
        SqlTypeCategory.Text => shape.Length is not null || family is TypeFamily.PostgreSql or TypeFamily.MySql or TypeFamily.Sqlite or TypeFamily.DuckDb,
        _ => false,
    };

    private static CopyDefinitionPlan PlanDefinition(CopyRequest request, DatabaseObject obj, Dictionary<string, DatabaseObject> existing, bool shares)
    {
        var target = new ObjectName(request.TargetSchema, obj.Name.Name);
        if (!request.IncludesStructure)
        {
            return new CopyDefinitionPlan(obj, target, CopyAction.Skip) { Notes = [CoreStrings.Format("Copy/DefinitionHasNoRows", obj.Name)] };
        }

        if (!shares)
        {
            var from = EngineDescriptor.For(request.Source.Profile.Engine).DisplayName;
            var to = EngineDescriptor.For(request.Target.Profile.Engine).DisplayName;
            return new CopyDefinitionPlan(obj, target, CopyAction.Skip) { Notes = [CoreStrings.Format("Copy/DefinitionOtherEngine", obj.Name, from, to)] };
        }

        if (!existing.TryGetValue(target.Name, out var present))
        {
            return new CopyDefinitionPlan(obj, target, CopyAction.Create);
        }

        return request.ExistingPolicy == CopyExistingPolicy.Replace && present.Kind == obj.Kind && request.Target is ISchemaDdlProvider
            ? new CopyDefinitionPlan(obj, present.Name, CopyAction.Replace)
            : new CopyDefinitionPlan(obj, present.Name, CopyAction.Skip) { Notes = [CoreStrings.Format("Copy/AlreadyExists", target.Name)] };
    }

    // Parents first, so a table's rows can check against keys already there when the target cannot add its keys
    // later. A cycle keeps the order the tables came in.
    private static List<CopyTablePlan> ParentsFirst(List<CopyTablePlan> plans)
    {
        var placed = new List<CopyTablePlan>(plans.Count);
        var placedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var remaining = new List<CopyTablePlan>(plans);
        var names = plans.Select(p => p.Structure.Table.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        while (remaining.Count > 0)
        {
            var next = remaining.FirstOrDefault(p => p.Structure.ForeignKeys
                .Select(k => k.ReferencedTable.Name)
                .Where(n => names.Contains(n) && !string.Equals(n, p.Structure.Table.Name, StringComparison.OrdinalIgnoreCase))
                .All(placedNames.Contains)) ?? remaining[0];
            placed.Add(next);
            placedNames.Add(next.Structure.Table.Name);
            remaining.Remove(next);
        }

        return placed;
    }
}
