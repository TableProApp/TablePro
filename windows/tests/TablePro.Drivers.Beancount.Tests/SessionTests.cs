using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Beancount.Tests;

public sealed class SessionTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private static BeancountDriver Driver(FakeProcessRunner runner, BeancountBackendLocator? locator = null) =>
        new(runner, locator ?? Samples.FakePythonLocator(runner), new RledgerCapabilities());

    private static async Task<List<StatementResult>> RunAsync(IQueryChannel channel, params string[] statements)
    {
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(StopOnError: false), Token))
        {
            results.Add(result);
        }

        return results;
    }

    [Fact]
    public async Task ConnectListsTheProjectedTablesAndReportsTheBackend()
    {
        var runner = Samples.PythonRunner();
        await using var session = await Driver(runner).ConnectAsync(Samples.Request(Samples.Ledger), Token);

        var objects = await session.GetObjectsAsync(null, Token);

        Assert.Equal("Python Beancount 3.1.0", session.ServerVersion);
        Assert.Equal(23, objects.Count);
        Assert.All(objects, o => Assert.Equal(ObjectKind.Table, o.Kind));
        Assert.Contains(objects, o => o.Name == new ObjectName(null, "postings"));
        Assert.Empty(await session.GetSchemasAsync(Token));
        Assert.Empty(await session.GetDatabasesAsync(Token));
    }

    [Fact]
    public async Task StructureDefinitionBrowseAndCountReadTheProjection()
    {
        await using var session = await Driver(Samples.PythonRunner()).ConnectAsync(Samples.Request(Samples.Ledger), Token);
        var table = new ObjectName(null, "transactions");

        var structure = await session.GetStructureAsync(table, Token);
        var definition = await session.GetDefinitionAsync(new DatabaseObject(table, ObjectKind.Table), Token);
        var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 2), Token);
        var count = await session.CountAsync(table, BrowseFilter.None, Token);

        Assert.Equal(["id", "date", "flag", "payee", "narration", "source_file", "line", "source_location"], structure.Columns.Select(c => c.Name));
        Assert.True(structure.Columns[0].IsPrimaryKey);
        Assert.False(structure.Columns[1].IsNullable);
        Assert.StartsWith("CREATE TABLE transactions", definition, StringComparison.Ordinal);
        Assert.EndsWith(";", definition, StringComparison.Ordinal);
        Assert.Equal(2, page.RowCount);
        Assert.Equal(3, count);
    }

    [Fact]
    public async Task EditorRunsReadsAndRefusesWrites()
    {
        await using var session = await Driver(Samples.PythonRunner()).ConnectAsync(Samples.Request(Samples.Ledger), Token);
        await using var channel = await session.OpenChannelAsync(Token);

        var results = await RunAsync(
            channel,
            "-- the salary\nSELECT payee FROM transactions WHERE id = 2",
            "PRAGMA table_info(postings)",
            "DELETE FROM transactions",
            "SELECT 1; PRAGMA query_only = OFF",
            "ATTACH DATABASE 'x.db' AS x",
            "WITH t AS (SELECT 1) DELETE FROM transactions");

        Assert.Equal("Employer", results[0].ResultSets[0].Rows[0][0]);
        Assert.True(results[1].Succeeded);
        Assert.Equal(BeancountException.ReadOnlyMessage, results[2].Error);
        Assert.Equal(BeancountException.ReadOnlyMessage, results[3].Error);
        Assert.Equal(BeancountException.ReadOnlyMessage, results[4].Error);

        // It reads as a WITH, so SQLite's query_only is what stops it.
        Assert.False(results[5].Succeeded);
        Assert.Equal(3L, (await RunAsync(channel, "SELECT COUNT(*) FROM transactions"))[0].ResultSets[0].Rows[0][0]);
    }

    [Fact]
    public async Task SavesAreRefused()
    {
        await using var session = await Driver(Samples.PythonRunner()).ConnectAsync(Samples.Request(Samples.Ledger), Token);

        var error = await Assert.ThrowsAsync<NotSupportedException>(() => session.SaveChangesAsync(new ObjectName(null, "transactions"), [new RowDelete(new Dictionary<string, object?> { ["id"] = 1L })], Token));

        Assert.Equal(BeancountException.ReadOnlyMessage, error.Message);
    }

    [Fact]
    public async Task EditingAnIncludedFileRebuildsBeforeTheNextRead()
    {
        using var temp = new TempDirectory();
        var ledger = temp.CopySamples();
        var payee = "Employer";
        var runner = Samples.PythonRunner(() => Samples.PythonOutput.Replace("\"Employer\"", $"\"{payee}\"", StringComparison.Ordinal));
        await using var session = await Driver(runner).ConnectAsync(Samples.Request(ledger), Token);
        await using var channel = await session.OpenChannelAsync(Token);
        Assert.Equal("Employer", (await RunAsync(channel, "SELECT payee FROM transactions WHERE id = 2"))[0].ResultSets[0].Rows[0][0]);
        var projections = runner.Runs.Count(r => r.StandardInput is not null);

        // Unchanged files are not projected again.
        await session.CountAsync(new ObjectName(null, "transactions"), BrowseFilter.None, Token);
        Assert.Equal(projections, runner.Runs.Count(r => r.StandardInput is not null));

        payee = "New Employer";
        File.AppendAllText(Path.Combine(temp.Path, "transactions", "2026-01.beancount"), "\n; edited\n");

        Assert.Equal("New Employer", (await RunAsync(channel, "SELECT payee FROM transactions WHERE id = 2"))[0].ResultSets[0].Rows[0][0]);
        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "transactions"), BrowseFilter.None, [], 0, 100), Token);
        Assert.Equal("New Employer", page.Rows[1][3]);
        Assert.Equal(projections + 1, runner.Runs.Count(r => r.StandardInput is not null));
    }

    [Fact]
    public async Task NewFileMatchingAGlobIncludeRebuilds()
    {
        using var temp = new TempDirectory();
        var ledger = temp.CopySamples();
        var runner = Samples.PythonRunner();
        await using var session = await Driver(runner).ConnectAsync(Samples.Request(ledger), Token);

        temp.Write(@"transactions\2026-02.beancount", "2026-02-01 open Assets:Savings USD\n");
        var objects = await session.GetObjectsAsync(null, Token);

        Assert.NotEmpty(objects);
        Assert.Equal(2, runner.Runs.Count(r => r.StandardInput is not null));
        await using var channel = await session.OpenChannelAsync(Token);
        Assert.Equal(4L, (await RunAsync(channel, "SELECT COUNT(*) FROM source_files"))[0].ResultSets[0].Rows[0][0]);
    }

    [Fact]
    public async Task LedgerThatStopsLoadingReportsTheBackendErrorToTheEditor()
    {
        using var temp = new TempDirectory();
        var ledger = temp.CopySamples();
        var broken = false;
        var runner = new FakeProcessRunner(spec => spec.Arguments.Contains("-c")
            ? FakeProcessRunner.Ok("3.1.0")
            : broken ? FakeProcessRunner.Fail("main.beancount:30: syntax error") : FakeProcessRunner.Ok(Samples.PythonOutput));
        await using var session = await Driver(runner).ConnectAsync(Samples.Request(ledger), Token);
        await using var channel = await session.OpenChannelAsync(Token);

        broken = true;
        File.AppendAllText(ledger, "\n2026-13-01 oops\n");

        var result = (await RunAsync(channel, "SELECT 1"))[0];
        Assert.Equal("main.beancount:30: syntax error", result.Error);
        await Assert.ThrowsAsync<BeancountException>(() => session.GetObjectsAsync(null, Token));
    }

    [Fact]
    public async Task BqlStatementsGoToRledger()
    {
        var runner = new FakeProcessRunner(spec => spec.Executable.EndsWith("rledger.exe", StringComparison.Ordinal)
            ? spec.Arguments is ["query", "--help"]
                ? FakeProcessRunner.Ok("--no-cache")
                : FakeProcessRunner.Ok("""{"columns":["account","total"],"rows":[["Assets:Checking",{"positions":[{"number":"2450.00","currency":"USD"}]}]]}""")
            : spec.Arguments.Contains("-c") ? FakeProcessRunner.Ok("3.1.0") : FakeProcessRunner.Ok(Samples.PythonOutput));
        var locator = new BeancountBackendLocator(runner, name => name == "PATH" ? @"C:\fake" : null, path => path is @"C:\fake\py.exe" or @"C:\fake\rledger.exe");
        await using var session = await Driver(runner, locator).ConnectAsync(Samples.Request(Samples.Ledger), Token);
        await using var channel = await session.OpenChannelAsync(Token);

        var result = (await RunAsync(channel, "BQL: SELECT account, sum(position) GROUP BY account"))[0];

        Assert.True(result.Succeeded, result.Error);
        Assert.Equal(["account", "total"], result.ResultSets[0].Columns.Select(c => c.Name));
        Assert.Equal<object?>(["Assets:Checking", "2450.00 USD"], result.ResultSets[0].Rows[0]);
        var query = runner.Runs.Last();
        Assert.Equal(["query", "-f", "json", "--no-errors", "--no-cache", Samples.Ledger, "SELECT account, sum(position) GROUP BY account"], query.Arguments);
    }

    [Fact]
    public async Task BqlWithoutRledgerExplainsWhatIsMissing()
    {
        await using var session = await Driver(Samples.PythonRunner()).ConnectAsync(Samples.Request(Samples.Ledger), Token);
        await using var channel = await session.OpenChannelAsync(Token);

        var result = (await RunAsync(channel, "bql balances"))[0];

        Assert.StartsWith("BQL queries need rledger", result.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task MissingLedgerFileIsNamed()
    {
        var error = await Assert.ThrowsAsync<BeancountException>(() => Driver(Samples.PythonRunner()).ConnectAsync(Samples.Request(@"C:\nowhere\missing.beancount"), Token));

        Assert.Equal(@"Failed to open Beancount ledger: File does not exist at C:\nowhere\missing.beancount", error.Message);
    }

    [Fact]
    public async Task ConnectWithNoBackendNamesWhatToInstall()
    {
        var runner = new FakeProcessRunner(_ => FakeProcessRunner.Fail("no"));
        var locator = new BeancountBackendLocator(runner, _ => null, _ => false);

        var error = await Assert.ThrowsAsync<BeancountException>(() => Driver(runner, locator).ConnectAsync(Samples.Request(Samples.Ledger), Token));

        Assert.Contains("pip install beancount", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConnectTimeoutComesFromTheProfile()
    {
        var runner = new FakeProcessRunner(async (spec, ct) =>
        {
            if (spec.Arguments.Contains("-c"))
            {
                return FakeProcessRunner.Ok("3.1.0");
            }

            await Task.Delay(Timeout.Infinite, ct);
            return FakeProcessRunner.Ok("{}");
        });

        var error = await Assert.ThrowsAsync<BeancountException>(() => Driver(runner).ConnectAsync(Samples.Request(Samples.Ledger, timeoutSeconds: 1), Token));

        Assert.Equal("Failed to open Beancount ledger: Connection timed out after 1 seconds", error.Message);
    }
}
