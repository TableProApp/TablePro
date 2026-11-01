using System.Globalization;
using System.Runtime.CompilerServices;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Copy;

/// <summary>One table of the fake database: its structure, its rows by column name, and the CLR type each column reads as.</summary>
internal sealed class FakeTable(TableStructure structure, Dictionary<string, Type> types)
{
    public TableStructure Structure { get; set; } = structure;

    public Dictionary<string, Type> Types { get; } = types;

    public List<Dictionary<string, object?>> Rows { get; } = [];
}

/// <summary>
/// An in-memory database behind the session contract. DDL comes back from <see cref="BuildDdl"/> as a token that the
/// channel applies when it runs, so a test sees the order changes ran in; adding a foreign key checks the rows already
/// there, as a real engine does.
/// </summary>
internal sealed class FakeSession(DatabaseEngine engine, string? schema = "public") : IDatabaseSession, ISchemaDdlProvider
{
    private readonly Dictionary<string, (ObjectName Table, SchemaChange Change)> _pending = new(StringComparer.Ordinal);

    public ConnectionProfile Profile { get; } = new() { Name = "fake", Engine = engine };

    public SqlDialect Dialect { get; } = SqlDialects.For(engine);

    public string ServerVersion => "1.0";

    public string? CurrentDatabase => "db";

    public string? DefaultSchema { get; } = schema;

    public Dictionary<ObjectName, FakeTable> Tables { get; } = [];

    public Dictionary<ObjectName, (DatabaseObject Object, string Definition)> Definitions { get; } = [];

    /// <summary>Every statement a channel ran, DDL as the change it stood for.</summary>
    public List<string> Executed { get; } = [];

    public List<int> SavedBatches { get; } = [];

    /// <summary>Checks foreign keys on every insert, as a target with its checks on would.</summary>
    public bool CheckKeysOnInsert { get; set; }

    public Func<ObjectName, IReadOnlyDictionary<string, object?>, bool>? RejectInsert { get; set; }

    public CancellationTokenSource? CancelAfterFirstBatch { get; set; }

    public IReadOnlyList<string> CommonDataTypes => ["integer", "text"];

    public FakeTable AddTable(string name, (string Name, string Type, Type Clr)[] columns, string[]? primaryKey = null, ForeignKeyInfo[]? keys = null, IndexInfo[]? indexes = null, string? tableSchema = null)
    {
        var table = new ObjectName(tableSchema ?? DefaultSchema, name);
        var key = primaryKey ?? [];
        var structure = new TableStructure(
            table,
            [.. columns.Select((c, i) => new ColumnInfo(c.Name, c.Type, !key.Contains(c.Name), null, key.Contains(c.Name), false, i))],
            indexes ?? [],
            keys ?? [],
            []);
        var fake = new FakeTable(structure, columns.ToDictionary(c => c.Name, c => c.Clr, StringComparer.OrdinalIgnoreCase));
        Tables[table] = fake;
        return fake;
    }

    public static ForeignKeyInfo Key(string name, string column, string parent, string parentColumn, string? schema = "public") =>
        new(name, [column], new ObjectName(schema, parent), [parentColumn]);

    public void Insert(string table, params object?[][] rows)
    {
        var fake = Tables[new ObjectName(DefaultSchema, table)];
        var names = fake.Structure.Columns.OrderBy(c => c.Ordinal).Select(c => c.Name).ToArray();
        foreach (var row in rows)
        {
            fake.Rows.Add(names.Select((n, i) => (n, row[i])).ToDictionary(p => p.n, p => p.Item2, StringComparer.OrdinalIgnoreCase));
        }
    }

    public Task PingAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>(["db"]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([.. Tables.Keys.Select(k => k.Schema ?? string.Empty).Distinct()]);

    public Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<DatabaseObject>>(
        [
            .. Tables.Keys.Where(k => k.Schema == schema).Select(k => new DatabaseObject(k, ObjectKind.Table)),
            .. Definitions.Values.Where(d => d.Object.Name.Schema == schema).Select(d => d.Object),
        ]);

    public Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken) =>
        Tables.TryGetValue(table, out var fake) ? Task.FromResult(fake.Structure) : throw new InvalidOperationException($"No table {table}.");

    public Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken) => Task.FromResult(Definitions[obj.Name].Definition);

    public Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        var fake = Tables[request.Table];
        var names = fake.Structure.Columns.OrderBy(c => c.Ordinal).Select(c => c.Name).ToArray();
        IEnumerable<Dictionary<string, object?>> rows = fake.Rows;
        foreach (var rule in request.Filter.Rules.Where(r => r.Enabled && r.Column is not null))
        {
            rows = rule.Operator switch
            {
                FilterOperator.IsNotNull => rows.Where(r => r[rule.Column!] is not null),
                FilterOperator.IsNull => rows.Where(r => r[rule.Column!] is null),
                _ => rows,
            };
        }

        if (request.Sort.Count > 0)
        {
            IOrderedEnumerable<Dictionary<string, object?>>? ordered = null;
            foreach (var sort in request.Sort)
            {
                ordered = ordered is null
                    ? sort.Descending ? rows.OrderByDescending(r => r[sort.Column], ValueComparer.Instance) : rows.OrderBy(r => r[sort.Column], ValueComparer.Instance)
                    : sort.Descending ? ordered.ThenByDescending(r => r[sort.Column], ValueComparer.Instance) : ordered.ThenBy(r => r[sort.Column], ValueComparer.Instance);
            }

            rows = ordered!;
        }

        var page = rows.Skip(request.Offset).Take(request.Limit).Select(r => names.Select(n => r.GetValueOrDefault(n)).ToArray()).ToList();
        var columns = names.Select(n => new ResultColumn(n, fake.Structure.Columns.First(c => c.Name == n).DataType, fake.Types.GetValueOrDefault(n, typeof(string)))).ToArray();
        return Task.FromResult(new ResultSet(columns, page));
    }

    public Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) => Task.FromResult((long)Tables[table].Rows.Count);

    public Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var fake = Tables[table];
        var added = new List<Dictionary<string, object?>>();
        foreach (var insert in changes.OfType<RowInsert>())
        {
            if (RejectInsert?.Invoke(table, insert.Values) == true)
            {
                throw new InvalidOperationException("The server refused the row.");
            }

            var row = fake.Structure.Columns.ToDictionary(c => c.Name, c => insert.Values.TryGetValue(c.Name, out var v) ? v : null, StringComparer.OrdinalIgnoreCase);
            if (CheckKeysOnInsert && Violation(fake.Structure, [row]) is { } violation)
            {
                throw new InvalidOperationException(violation);
            }

            added.Add(row);
        }

        // A batch is one transaction: it all goes in or none of it does.
        fake.Rows.AddRange(added);
        SavedBatches.Add(added.Count);
        CancelAfterFirstBatch?.Cancel();
        return Task.FromResult(added.Count);
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) => Task.FromResult<IQueryChannel>(new Channel(this));

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change)
    {
        var token = string.Create(CultureInfo.InvariantCulture, $"{change.GetType().Name} {table} #{_pending.Count}");
        _pending[token] = (table, change);
        return [token];
    }

    private string? Apply(ObjectName table, SchemaChange change)
    {
        switch (change)
        {
            case CreateTable create:
                if (Tables.ContainsKey(create.Table))
                {
                    return $"{create.Table} already exists.";
                }

                Tables[create.Table] = new FakeTable(
                    new TableStructure(create.Table, [.. create.Columns.Select((c, i) => new ColumnInfo(c.Name, c.DataType, c.IsNullable, c.DefaultExpression, c.IsPrimaryKey, c.IsIdentity, i))], [], [], []),
                    create.Columns.ToDictionary(c => c.Name, c => ClrFor(c.DataType), StringComparer.OrdinalIgnoreCase));
                return null;
            case DropObject drop:
                return Tables.Remove(table) || Definitions.Remove(table) ? null : $"{table} does not exist.";
            case TruncateTable:
                Tables[table].Rows.Clear();
                return null;
            case CreateIndex index:
            {
                var fake = Tables[table];
                fake.Structure = fake.Structure with { Indexes = [.. fake.Structure.Indexes, new IndexInfo(index.Index.Name, index.Index.Columns, index.Index.IsUnique, false)] };
                return null;
            }

            case AddForeignKey add:
            {
                var fake = Tables[table];
                var key = new ForeignKeyInfo(add.ForeignKey.Name, add.ForeignKey.Columns, add.ForeignKey.ReferencedTable, add.ForeignKey.ReferencedColumns);
                var structure = fake.Structure with { ForeignKeys = [.. fake.Structure.ForeignKeys, key] };
                if (Violation(structure, fake.Rows) is { } violation)
                {
                    return violation;
                }

                fake.Structure = structure;
                return null;
            }

            default:
                return $"Unsupported change {change.GetType().Name}.";
        }
    }

    private string? Violation(TableStructure structure, IEnumerable<Dictionary<string, object?>> rows)
    {
        foreach (var key in structure.ForeignKeys)
        {
            if (!Tables.TryGetValue(key.ReferencedTable, out var parent))
            {
                return $"{key.ReferencedTable} does not exist.";
            }

            foreach (var row in rows)
            {
                var values = key.Columns.Select(c => row[c]).ToArray();
                if (values.Any(v => v is null))
                {
                    continue;
                }

                if (!parent.Rows.Any(p => key.ReferencedColumns.Select((c, i) => ValueComparer.Instance.Compare(p[c], values[i]) == 0).All(b => b)))
                {
                    return $"The foreign key {key.Name} is violated by {string.Join(", ", values)}.";
                }
            }
        }

        return null;
    }

    private static Type ClrFor(string type) => type.ToUpperInvariant() switch
    {
        var t when t.Contains("INT", StringComparison.Ordinal) => typeof(long),
        var t when t.Contains("BOOL", StringComparison.Ordinal) => typeof(bool),
        "UUID" or "UNIQUEIDENTIFIER" => typeof(Guid),
        _ => typeof(string),
    };

    private sealed class Channel(FakeSession owner) : IQueryChannel
    {
        public async IAsyncEnumerable<StatementResult> ExecuteAsync(IReadOnlyList<string> statements, ExecuteOptions options, [EnumeratorCancellation] CancellationToken cancellationToken)
        {
            await Task.Yield();
            foreach (var statement in statements)
            {
                cancellationToken.ThrowIfCancellationRequested();
                owner.Executed.Add(statement);
                string? error = null;
                if (owner._pending.Remove(statement, out var pending))
                {
                    error = owner.Apply(pending.Table, pending.Change);
                }
                else if (statement.Contains("FAIL", StringComparison.Ordinal))
                {
                    error = "The statement failed.";
                }

                yield return new StatementResult(statement, [], 0, TimeSpan.Zero, error);
                if (error is not null && options.StopOnError)
                {
                    yield break;
                }
            }
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    /// <summary>Orders mixed values the way the tests need: nulls first, numbers by value, everything else by invariant text.</summary>
    private sealed class ValueComparer : IComparer<object?>
    {
        public static readonly ValueComparer Instance = new();

        public int Compare(object? x, object? y)
        {
            if (x is null || y is null)
            {
                return x is null ? (y is null ? 0 : -1) : 1;
            }

            if (x is IConvertible && y is IConvertible
                && decimal.TryParse(Convert.ToString(x, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out var a)
                && decimal.TryParse(Convert.ToString(y, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out var b))
            {
                return a.CompareTo(b);
            }

            return string.CompareOrdinal(Convert.ToString(x, CultureInfo.InvariantCulture), Convert.ToString(y, CultureInfo.InvariantCulture));
        }
    }
}
