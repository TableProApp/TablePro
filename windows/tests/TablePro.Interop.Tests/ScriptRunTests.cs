using Native = TablePro.Interop.Native;

namespace TablePro.Interop.Tests;

// Drives the core's run_script over the generated bindings against a real
// SQLite file. A high-level wrapper is the Windows app's work (W-38).
public sealed class ScriptRunTests
{
    private sealed class NoWake : Native.RunListener
    {
        public void EventsPending()
        {
        }
    }

    private static Native.ScriptBatch Batch(string sql) => new(sql, 1, 0, false);

    private static async Task<List<Native.ScriptRunEvent>> RunAsync(
        SqliteDatabase db,
        IEnumerable<string> statements,
        Native.BatchErrorPolicyTag policy)
    {
        var batches = statements.Select(Batch).ToArray();
        var run = db.Editor.NativeEditor.RunScript(batches, policy, new Native.RunSettings(null, null, null), new NoWake());
        await run.Outcome();
        var events = run.DrainEvents().ToList();
        run.Dispose();
        return events;
    }

    [Fact]
    public async Task AScriptRunsEachBatchKeepsItsRowsAndReportsOnePerBatch()
    {
        await using var db = await SqliteDatabase.CreateAsync();

        var run = db.Editor.NativeEditor.RunScript(
            [Batch("SELECT id FROM people ORDER BY id"), Batch("SELECT name FROM people ORDER BY id")],
            Native.BatchErrorPolicyTag.StopScript,
            new Native.RunSettings(null, null, null),
            new NoWake());
        await run.Outcome();
        var events = run.DrainEvents().ToList();

        var batches = events.OfType<Native.ScriptRunEvent.Batch>().ToList();
        Assert.Equal(2, batches.Count);
        Assert.IsType<Native.ScriptRunEvent.Finished>(events[^1]);
        for (var index = 0; index < batches.Count; index++)
        {
            var batch = batches[index];
            Assert.Equal((uint)index, batch.BatchIndex);
            Assert.Equal(Native.VerdictTag.Completed, batch.Verdict);
            var set = Assert.IsType<Native.ScriptEntryInfo.ResultSet>(Assert.Single(batch.Entries));
            Assert.Equal((uint)index, set.SetIndex);
            Assert.Equal(3ul, set.Retained);
        }

        using var ids = new ResultSet(run.ResultSet(0)!, 0);
        Assert.Equal(3, ids.RowCount);
        Assert.Equal("1", ids.GetCellText(0, 0));
        run.Dispose();
    }

    [Fact]
    public async Task StopScriptHaltsAfterAFailure()
    {
        await using var db = await SqliteDatabase.CreateAsync();

        var events = await RunAsync(
            db,
            ["SELECT 1", "SELECT missing FROM nope", "SELECT 2"],
            Native.BatchErrorPolicyTag.StopScript);

        // The failing batch halts the script: only two batches report, the
        // third never runs. A failed statement is Failed; Stopped is for a
        // cancel, a timeout or a lost session.
        var batches = events.OfType<Native.ScriptRunEvent.Batch>().ToList();
        Assert.Equal(2, batches.Count);
        Assert.Equal(Native.VerdictTag.Completed, batches[0].Verdict);
        Assert.Equal(Native.VerdictTag.Failed, batches[1].Verdict);
        Assert.IsType<Native.ScriptEntryInfo.Failed>(Assert.Single(batches[1].Entries));
        Assert.IsType<Native.ScriptRunEvent.Finished>(events[^1]);
    }

    [Fact]
    public async Task ContinueRunsEveryBatchPastAFailure()
    {
        await using var db = await SqliteDatabase.CreateAsync();

        var events = await RunAsync(
            db,
            ["SELECT 1", "SELECT missing FROM nope", "SELECT 2"],
            Native.BatchErrorPolicyTag.ContinueNextBatch);

        var batches = events.OfType<Native.ScriptRunEvent.Batch>().ToList();
        Assert.Equal(3, batches.Count);
        Assert.Equal(Native.VerdictTag.Completed, batches[0].Verdict);
        Assert.Equal(Native.VerdictTag.Failed, batches[1].Verdict);
        Assert.Equal(Native.VerdictTag.Completed, batches[2].Verdict);
        Assert.IsType<Native.ScriptRunEvent.Finished>(events[^1]);
    }
}
