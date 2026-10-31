using TablePro.Core.Browse;
using TablePro.Core.Compare;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Compare;

/// <summary>
/// One table held in memory behind the session contract: browse pages sorted on any columns, and saves applied in one
/// all-or-nothing transaction with the same one-row check the ADO.NET session makes.
/// </summary>
internal sealed class InMemoryTableSession(TableStructure structure, IEnumerable<object?[]> rows) : IDatabaseSession
{
    public List<object?[]> Rows { get; private set; } = [.. rows];

    public TableStructure Structure { get; } = structure;

    public int BrowseCalls { get; private set; }

    public int SaveCalls { get; private set; }

    /// <summary>The save call (counting from one) that throws without applying anything.</summary>
    public int? FailOnSaveCall { get; set; }

    public ConnectionProfile Profile { get; } = new() { Name = "memory", Engine = DatabaseEngine.Sqlite };

    public SqlDialect Dialect => SqliteDialect.Instance;

    public string ServerVersion => "test";

    public string? CurrentDatabase => "main";

    public string? DefaultSchema => null;

    private int Column(string name) => Structure.Columns.Select((c, i) => (c, i)).First(x => string.Equals(x.c.Name, name, StringComparison.OrdinalIgnoreCase)).i;

    public Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        BrowseCalls++;
        IEnumerable<object?[]> query = Rows;
        if (request.Sort.Count > 0)
        {
            var indexes = request.Sort.Select(s => Column(s.Column)).ToArray();
            query = Rows.Order(Comparer<object?[]>.Create((a, b) =>
            {
                foreach (var i in indexes)
                {
                    var order = CompareValues.CompareKeys(a[i], b[i], ignoreCase: false);
                    if (order != 0)
                    {
                        return order;
                    }
                }

                return 0;
            }));
        }

        var page = query.Skip(request.Offset).Take(request.Limit).Select(r => (object?[])r.Clone()).ToList();
        var columns = Structure.Columns.Select(c => new ResultColumn(c.Name, c.DataType, typeof(object))).ToArray();
        return Task.FromResult(new ResultSet(columns, page));
    }

    public Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        SaveCalls++;
        var working = Rows.Select(r => (object?[])r.Clone()).ToList();
        var affected = 0;
        if (SaveCalls == FailOnSaveCall)
        {
            throw new InvalidOperationException("Simulated failure.");
        }

        foreach (var change in changes)
        {
            switch (change)
            {
                case RowInsert insert:
                    if (Structure.PrimaryKey.Count > 0 && working.Any(r => Structure.PrimaryKey.All(k => Equals(r[Column(k)], insert.Values.GetValueOrDefault(k)))))
                    {
                        throw new InvalidOperationException("UNIQUE constraint failed.");
                    }

                    var row = new object?[Structure.Columns.Count];
                    foreach (var (column, value) in insert.Values)
                    {
                        row[Column(column)] = value;
                    }

                    working.Add(row);
                    break;
                case RowUpdate update:
                    var targets = Matching(working, update.Key);
                    if (targets.Count != 1)
                    {
                        throw new RowCountMismatchException(1, targets.Count, "UPDATE");
                    }

                    foreach (var (column, value) in update.Values)
                    {
                        targets[0][Column(column)] = value;
                    }

                    break;
                case RowDelete delete:
                    var doomed = Matching(working, delete.Key);
                    if (doomed.Count != 1)
                    {
                        throw new RowCountMismatchException(1, doomed.Count, "DELETE");
                    }

                    working.Remove(doomed[0]);
                    break;
            }

            affected++;
        }

        Rows = working;
        return Task.FromResult(affected);
    }

    private List<object?[]> Matching(List<object?[]> rows, IReadOnlyDictionary<string, object?> key) =>
        [.. rows.Where(r => key.All(k => CompareValues.AreEqual(r[Column(k.Key)], k.Value, DataCompareOptions.Default)))];

    public Task PingAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>(["main"]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<DatabaseObject>>([new DatabaseObject(Structure.Table, ObjectKind.Table)]);

    public Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken) => Task.FromResult(Structure);

    public Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken) => Task.FromResult(string.Empty);

    public Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) => Task.FromResult((long)Rows.Count);

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) => throw new NotSupportedException();

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    public static TableStructure Table(string name, string[] primaryKey, params string[] columns) => new(
        new ObjectName(null, name),
        [.. columns.Select((c, i) => new ColumnInfo(c, "TEXT", IsNullable: true, DefaultValue: null, IsPrimaryKey: primaryKey.Contains(c), IsIdentity: false, Ordinal: i))],
        [],
        [],
        []);
}
