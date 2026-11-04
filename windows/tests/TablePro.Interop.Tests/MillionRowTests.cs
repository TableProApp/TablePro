using System.Diagnostics;
using System.Globalization;

namespace TablePro.Interop.Tests;

[Collection(Timing.Name)]
public sealed class MillionRowTests(ITestOutputHelper output)
{
    private const int Rows = 1_000_000;

    private const string Million =
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000000) " +
        "SELECT x, 'row ' || x, x * 0.5 FROM c";

    [Fact]
    public async Task AMillionRowsStreamInAndEveryWindowReadsBack()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        var streaming = Stopwatch.StartNew();
        using var run = database.Editor.Run(
            Million,
            new QueryOptions(RowLimit: Rows),
            TestContext.Current.CancellationToken);
        var outcome = await run.Completion;
        streaming.Stop();

        Assert.IsType<QueryOutcome.Completed>(outcome);
        using var set = run.GetResultSet(0)!;
        Assert.Equal(Rows, set.RowCount);

        using var cursor = set.OpenCursor();
        var middle = cursor.Fetch(500_000, 50, 0, 3, 100);
        Assert.Equal(50, middle.RowCount);
        Assert.Equal(Rows, middle.TotalRows);
        Assert.Equal("500001", middle.GetText(0, 0));
        Assert.Equal("row 500001", middle.GetText(0, 1));
        Assert.Equal("250000.5", middle.GetText(0, 2));
        Assert.Equal(250000.5, BitConverter.Int64BitsToDouble(middle.GetRaw(0, 2)));
        Assert.Equal(ValueKind.Float, middle.GetKind(0, 2));

        var last = cursor.Fetch(Rows - 10, 50, 0, 3, 100);
        Assert.Equal(10, last.RowCount);
        Assert.Equal("1000000", last.GetText(9, 0));
        Assert.Equal(Rows, last.GetRaw(9, 0));

        var scrolling = Stopwatch.StartNew();
        long checksum = 0;
        for (var first = 0L; first < Rows; first += 50)
        {
            var window = cursor.Fetch(first, 50, 0, 3, 100);
            for (var row = 0; row < window.RowCount; row++)
            {
                checksum += window.GetRaw(row, 0);
                _ = window.GetText(row, 1);
            }
        }

        scrolling.Stop();

        Assert.Equal((long)Rows * (Rows + 1) / 2, checksum);
        output.WriteLine(string.Create(
            CultureInfo.InvariantCulture,
            $"{Rows:N0} rows streamed in {streaming.Elapsed.TotalSeconds:F2} s; " +
            $"{Rows / 50:N0} windows of 50 x 3 read and decoded in {scrolling.Elapsed.TotalSeconds:F2} s"));
    }
}

[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class Timing
{
    public const string Name = "Timing";
}
