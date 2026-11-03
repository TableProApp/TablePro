using System.Diagnostics;
using System.Globalization;

namespace TablePro.Interop.Tests;

[Collection(Timing.Name)]
public sealed class ThreadingTests(ITestOutputHelper output)
{
    private const string Million =
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000000) SELECT x FROM c";

    private static readonly TimeSpan CallBudget = TimeSpan.FromMilliseconds(100);

    [Fact]
    public async Task EveryCallReturnsAtOnceAndResumesOnTheUiThread()
    {
        using var ui = new UiThread();
        var directory = Directory.CreateTempSubdirectory("tablepro-interop-").FullName;
        var resumedOff = new List<string>();

        await ui.RunAsync(async () =>
        {
            void OnUi(string step)
            {
                if (!ui.IsCurrent)
                {
                    resumedOff.Add(step);
                }
            }

            using var core = TableProCore.Create(new HostConfiguration("test"), new MemorySecretStore());
            var session = await Timed(
                "open",
                () => core.OpenFileAsync(new FileOpenOptions(Path.Combine(directory, "ui.sqlite"), Create: true)));
            OnUi("open");
            await Timed("schemas", () => session.GetSchemasAsync());
            OnUi("schemas");
            await Timed("objects", () => session.GetObjectsAsync(ObjectScope.DefaultSchema));
            OnUi("objects");
            var editor = await Timed("editor", () => session.OpenEditorAsync());
            OnUi("editor");

            var started = Stopwatch.StartNew();
            using var run = editor.Run(Million, new QueryOptions(RowLimit: 1_000_000));
            var returnedIn = started.Elapsed;
            Assert.True(returnedIn < CallBudget, $"Run held the UI thread for {returnedIn}");
            Assert.False(run.Completion.IsCompleted, "a million rows were read before Run returned");
            await run.Completion;
            OnUi("completion");

            await Timed("close editor", () => editor.DisposeAsync().AsTask());
            await Timed("close session", () => session.DisposeAsync().AsTask());
            OnUi("close");
        });

        Assert.Empty(resumedOff);
        Directory.Delete(directory, recursive: true);
    }

    [Fact]
    public async Task RowsArriveOnTheUiThreadWhileItKeepsResponding()
    {
        using var ui = new UiThread();
        await using var database = await SqliteDatabase.CreateAsync();
        var heartbeats = new List<long>();
        var counts = new List<long>();
        var offUi = 0;
        var clock = Stopwatch.StartNew();
        using var stop = new CancellationTokenSource();
        var ticker = Task.Run(
            async () =>
            {
                while (!stop.IsCancellationRequested)
                {
                    ui.Post(() => heartbeats.Add(clock.ElapsedMilliseconds));
                    await Task.Delay(5, CancellationToken.None);
                }
            },
            CancellationToken.None);

        await ui.RunAsync(async () =>
        {
            using var run = database.Editor.Run(Million, new QueryOptions(RowLimit: 1_000_000));
            await foreach (var queryEvent in run.ReadEventsAsync())
            {
                if (!ui.IsCurrent)
                {
                    offUi++;
                }

                if (queryEvent is QueryEvent.RowsAppended rows)
                {
                    counts.Add(rows.RowCount);
                }
            }
        });
        await stop.CancelAsync();
        await ticker;

        Assert.Equal(0, offUi);
        Assert.NotEmpty(counts);
        Assert.Equal(1_000_000, counts[^1]);
        Assert.Equal(counts.Order(), counts);
        var longestGap = heartbeats.Zip(heartbeats.Skip(1), (before, after) => after - before).Max();
        output.WriteLine(string.Create(
            CultureInfo.InvariantCulture,
            $"{counts.Count} row events on the UI thread; longest gap between heartbeats {longestGap} ms"));
        Assert.True(longestGap < 1_000, $"the UI thread stalled for {longestGap} ms");
    }

    private static async Task<T> Timed<T>(string step, Func<Task<T>> call)
    {
        var started = Stopwatch.StartNew();
        var pending = call();
        var returnedIn = started.Elapsed;
        Assert.True(returnedIn < CallBudget, $"{step} held the calling thread for {returnedIn}");
        return await pending;
    }

    private static async Task Timed(string step, Func<Task> call) =>
        await Timed(step, async () =>
        {
            await call();
            return true;
        });
}
