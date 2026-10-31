using System.Globalization;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Rewind;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Core.Tests.Compare;

namespace TablePro.Core.Tests.Rewind;

public sealed class RewindTests
{
    private static readonly ObjectName Table = new(null, "users");
    private static readonly TableStructure Structure = InMemoryTableSession.Table("users", ["id"], "id", "name", "email");
    private static readonly DateTimeOffset Now = new(2026, 10, 29, 12, 0, 0, TimeSpan.Zero);

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private static object?[][] Seed() => [[1, "Ann", "ann@x"], [2, "Bob", "bob@x"], [3, "Cat", "cat@x"]];

    private static TableEditBuffer Buffer(object?[][] rows, IReadOnlyList<string>? key = null)
    {
        ResultColumn[] columns = [new("id", "TEXT", typeof(object)), new("name", "TEXT", typeof(object)), new("email", "TEXT", typeof(object))];
        return new TableEditBuffer(new ResultSet(columns, [.. rows.Select(r => (object?[])r.Clone())]), key ?? ["id"]);
    }

    private static RewindRecord Capture(TableEditBuffer buffer, IReadOnlyList<string>? key = null) =>
        RewindCapture.FromBuffer(buffer, key ?? ["id"], Guid.NewGuid(), DatabaseEngine.Sqlite, "main", Table, Now)!;

    /// <summary>Saves the buffer to the session and captures it, as the table tab does.</summary>
    private static async Task<RewindRecord> SaveAsync(InMemoryTableSession session, Action<TableEditBuffer> edit)
    {
        var buffer = Buffer([.. session.Rows]);
        edit(buffer);
        await session.SaveChangesAsync(Table, buffer.BuildChanges(), Token);
        return Capture(buffer);
    }

    [Fact]
    public void NothingToCaptureWithoutChanges() =>
        Assert.Null(RewindCapture.FromBuffer(Buffer(Seed()), ["id"], Guid.NewGuid(), DatabaseEngine.Sqlite, null, Table, Now));

    [Fact]
    public void CaptureKeepsBeforeAndAfterInSaveOrder()
    {
        var buffer = Buffer(Seed());
        buffer.SetValue(0, 1, "Anne");
        buffer.ToggleDelete([1]);
        var added = buffer.InsertRow();
        buffer.SetValue(added, 0, 9);
        buffer.SetValue(added, 1, "Neu");

        var record = Capture(buffer);

        Assert.Equal([RewindOperationKind.Delete, RewindOperationKind.Update, RewindOperationKind.Insert], record.Operations.Select(o => o.Kind));
        var update = record.Operations[1];
        Assert.Equal("Ann", update.Before![1]);
        Assert.Equal("Anne", update.After![1]);
        Assert.Equal(["name"], update.Written);
        Assert.Equal(["id", "name"], record.Operations[2].Written);
        Assert.Equal("1 edited, 1 added, 1 deleted", record.Summary);
    }

    [Fact]
    public void TheSummaryIsWordedInTheUiLanguage()
    {
        var counts = new RewindCounts(2, 1, 0);
        var saved = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("fr");
            Assert.Equal("2 modifiées, 1 ajoutée", counts.Describe());

            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("zh-Hans");
            Assert.Equal("已编辑 2 个，已添加 1 个", counts.Describe());
        }
        finally
        {
            CultureInfo.CurrentUICulture = saved;
        }
    }

    [Fact]
    public void RowsWithoutAKnownKeyAreRefused()
    {
        var buffer = Buffer(Seed());
        var added = buffer.InsertRow();
        buffer.SetValue(added, 1, "auto id");

        var operation = Assert.Single(Capture(buffer).Operations);

        Assert.Equal(RewindRefusal.ServerAssignedKey, operation.Refusal);
        Assert.Null(operation.After);
    }

    [Fact]
    public void TableWithoutPrimaryKeyIsRefused()
    {
        var buffer = Buffer(Seed(), key: []);
        buffer.SetValue(0, 1, "x");

        var record = Capture(buffer, key: []);

        Assert.All(record.Operations, o => Assert.Equal(RewindRefusal.NoPrimaryKey, o.Refusal));
        Assert.False(RewindPlanner.Plan(record).CanApply);
    }

    [Fact]
    public void HugeValuesAreNotKept()
    {
        var buffer = Buffer(Seed());
        buffer.SetValue(0, 2, new string('x', RewindCapture.MaxValueLength + 1));

        Assert.Equal(RewindRefusal.ValueTooLarge, Assert.Single(Capture(buffer).Operations).Refusal);
    }

    [Fact]
    public async Task RewindRestoresEveryKindOfChange()
    {
        var session = new InMemoryTableSession(Structure, Seed());
        var record = await SaveAsync(session, buffer =>
        {
            buffer.SetValue(0, 1, "Anne");
            buffer.ToggleDelete([1]);
            var added = buffer.InsertRow();
            buffer.SetValue(added, 0, 9);
            buffer.SetValue(added, 1, "Neu");
        });

        var plan = RewindPlanner.Plan(record);
        Assert.Equal(["Remove the added row", "Restore previous values", "Put the row back"], plan.Steps.Select(s => s.Action));
        await session.SaveChangesAsync(Table, plan.Changes, Token);

        Assert.Equal(Seed().Select(r => string.Join('|', r)).Order(), session.Rows.Select(r => string.Join('|', r)).Order());
    }

    [Fact]
    public async Task RowChangedSinceTheSaveRollsTheRewindBack()
    {
        var session = new InMemoryTableSession(Structure, Seed());
        var record = await SaveAsync(session, buffer => buffer.SetValue(0, 1, "Anne"));
        session.Rows[session.Rows.FindIndex(r => Equals(r[0], 1))][1] = "Someone else";

        await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(Table, RewindPlanner.Plan(record).Changes, Token));

        Assert.Equal("Someone else", session.Rows.First(r => Equals(r[0], 1))[1]);
    }

    [Fact]
    public async Task UndoingARewindRedoesTheSave()
    {
        var session = new InMemoryTableSession(Structure, Seed());
        var record = await SaveAsync(session, buffer =>
        {
            buffer.SetValue(2, 2, "cat@new");
            buffer.ToggleDelete([0]);
        });
        var afterSave = session.Rows.Select(r => string.Join('|', r)).Order().ToArray();

        var rewind = RewindPlanner.Plan(record);
        await session.SaveChangesAsync(Table, rewind.Changes, Token);
        var inverse = rewind.InverseRecord(Now.AddMinutes(1));
        Assert.Equal(record.Id, inverse.Restores);

        await session.SaveChangesAsync(Table, RewindPlanner.Plan(inverse).Changes, Token);

        Assert.Equal(afterSave, session.Rows.Select(r => string.Join('|', r)).Order());
    }

    [Fact]
    public void GuardLeavesFloatsAndLongTextOutOfTheCheck()
    {
        ResultColumn[] columns = [new("id", "TEXT", typeof(object)), new("score", "REAL", typeof(object)), new("bio", "TEXT", typeof(object))];
        var buffer = new TableEditBuffer(new ResultSet(columns, [[1, 1.5, "short"]]), ["id"]);
        buffer.SetValue(0, 1, 2.5);
        buffer.SetValue(0, 2, new string('b', 300));
        var record = RewindCapture.FromBuffer(buffer, ["id"], Guid.NewGuid(), DatabaseEngine.Sqlite, null, Table, Now)!;

        var update = Assert.IsType<RowUpdate>(Assert.Single(RewindPlanner.Plan(record).Steps).Change);

        Assert.Equal(["id"], update.Key.Keys);
        Assert.Equal(1.5, update.Values["score"]);
    }

    [Fact]
    public void PreviewShowsTheGuardedStatement()
    {
        var buffer = Buffer(Seed());
        buffer.SetValue(0, 1, "Anne");

        var preview = Assert.Single(RewindPlanner.Plan(Capture(buffer)).Preview(SqliteDialect.Instance));

        Assert.Equal("UPDATE \"users\" SET \"name\" = 'Ann' WHERE \"id\" = 1 AND \"name\" = 'Anne'", preview);
    }

    [Fact]
    public void CodecRoundTripsEveryValueType()
    {
        var bytes = new byte[] { 0, 1, 255 };
        var guid = Guid.NewGuid();
        object?[] row =
        [
            null, "text", true, 42, 42L, (short)4, (byte)5, (sbyte)-6, (ushort)7, 8u, 9ul, 1.25m, 0.1, 2.5f,
            new DateTime(2024, 1, 2, 3, 4, 5, 678, DateTimeKind.Utc), new DateTimeOffset(2024, 1, 2, 3, 4, 5, TimeSpan.FromHours(2)),
            new DateOnly(2024, 2, 29), new TimeOnly(13, 14, 15), TimeSpan.FromMinutes(90), guid, bytes,
            System.Numerics.BigInteger.Parse("123456789012345678901234567890", System.Globalization.CultureInfo.InvariantCulture),
        ];
        var columns = row.Select((_, i) => "c" + i).ToArray();
        var record = new RewindRecord(Guid.NewGuid(), Guid.NewGuid(), DatabaseEngine.PostgreSql, "db", new ObjectName("public", "t"), Now, columns, ["c3"],
            [new RewindOperation(RewindOperationKind.Update, row, row, ["c1"]), new RewindOperation(RewindOperationKind.Insert, null, null, [], RewindRefusal.ServerAssignedKey)])
        {
            Restores = Guid.NewGuid(),
        };

        var copy = RewindRecordCodec.Deserialize(RewindRecordCodec.Serialize(record));

        Assert.Equal(record.Id, copy.Id);
        Assert.Equal(record.Restores, copy.Restores);
        Assert.Equal(record.Table, copy.Table);
        Assert.Equal(record.Engine, copy.Engine);
        Assert.Equal(record.CapturedAt, copy.CapturedAt);
        Assert.Equal(record.Columns, copy.Columns);
        Assert.Equal(RewindRefusal.ServerAssignedKey, copy.Operations[1].Refusal);
        Assert.Null(copy.Operations[1].Before);
        var restored = copy.Operations[0].Before!;
        for (var i = 0; i < row.Length; i++)
        {
            Assert.Equal(row[i]?.GetType(), restored[i]?.GetType());
            Assert.Equal(row[i], restored[i]);
        }
    }
}
