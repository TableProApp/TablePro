using Microsoft.Data.Sqlite;

namespace TablePro.Drivers.Beancount.Tests;

public sealed class ProjectionTests
{
    private static async Task<BeancountProjection> BuildAsync(IBeancountProjectionSource source, string? ledger = null)
    {
        var projector = new BeancountProjector(ledger ?? Samples.Ledger, TimeSpan.FromSeconds(30), _ => Task.FromResult(source));
        return await projector.BuildAsync(TestContext.Current.CancellationToken);
    }

    [Fact]
    public async Task PythonOutputProjectsIntoTheMacOSTables()
    {
        var runner = Samples.PythonRunner();
        var source = new PythonBackend(BeancountBackend.Python(@"C:\fake\py.exe", "-3"), runner, runLedgerPlugins: false, "Python Beancount 3.1.0");

        using var projection = await BuildAsync(source);

        var tables = ProjectionQueries.Rows(projection, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").Select(r => (string)r[0]!);
        Assert.Equal(
            [
                "accounts", "balance_assertions", "balances", "closes", "commodities", "custom", "custom_values", "diagnostics",
                "directive_metadata", "directives", "documents", "events", "notes", "pads", "posting_metadata", "postings", "prices",
                "queries", "source_files", "transaction_links", "transaction_metadata", "transaction_tags", "transactions",
            ],
            tables);
        Assert.Equal("Python Beancount 3.1.0", projection.BackendVersion);

        Assert.Equal(3L, ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM transactions"));
        Assert.Equal(
            ["Employer", "January salary", "C:/ledger/transactions/2026-01.beancount:5"],
            ProjectionQueries.Rows(projection, "SELECT payee, narration, source_location FROM transactions WHERE id = 2")[0]);
        Assert.Equal(6L, ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM postings"));
        Assert.Equal(
            ["50.00", "USD", "1.08", "EUR"],
            ProjectionQueries.Rows(projection, "SELECT amount, commodity, price_number, price_currency FROM postings WHERE id = 5")[0]);
        Assert.Equal("!", ProjectionQueries.Scalar(projection, "SELECT flag FROM postings WHERE id = 6"));
        Assert.Equal("payroll", ProjectionQueries.Scalar(projection, "SELECT tag FROM transaction_tags WHERE transaction_id = 2"));
        Assert.Equal("jan-2026", ProjectionQueries.Scalar(projection, "SELECT link FROM transaction_links WHERE transaction_id = 2"));
        Assert.Equal("INV-1", ProjectionQueries.Scalar(projection, "SELECT value FROM transaction_metadata WHERE key = 'invoice'"));
        Assert.Equal(
            [["audited", "TRUE"], ["receipt", "R-17"]],
            ProjectionQueries.Rows(projection, "SELECT key, value FROM posting_metadata WHERE posting_id = 5 ORDER BY id"));

        Assert.Equal(5L, ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM accounts"));
        Assert.Equal("USD", ProjectionQueries.Scalar(projection, "SELECT currencies FROM accounts WHERE name = 'Assets:Checking'"));
        Assert.Equal("STRICT", ProjectionQueries.Scalar(projection, "SELECT booking FROM accounts WHERE name = 'Expenses:Old'"));
        Assert.Equal(["2026-06-30", "Expenses:Old"], ProjectionQueries.Rows(projection, "SELECT date, account FROM closes")[0]);
        Assert.Equal(["EUR", "1.08", "USD"], ProjectionQueries.Rows(projection, "SELECT commodity, amount, currency FROM prices")[0]);
        Assert.Equal("2450.00", ProjectionQueries.Scalar(projection, "SELECT amount FROM balances WHERE account = 'Assets:Checking'"));
        Assert.Equal("USD", ProjectionQueries.Scalar(projection, "SELECT commodity FROM commodities"));
        Assert.Equal("C:/ledger/docs/statement.pdf", ProjectionQueries.Scalar(projection, "SELECT path FROM documents"));
        Assert.Equal(["location", "Bucharest"], ProjectionQueries.Rows(projection, "SELECT type, description FROM events")[0]);
        Assert.Equal(["Assets:Checking", "Equity:Opening"], ProjectionQueries.Rows(projection, "SELECT account, source_account FROM pads")[0]);
        Assert.Equal("security", ProjectionQueries.Scalar(projection, "SELECT phase FROM diagnostics"));
        Assert.Equal(3L, ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM directives"));
        Assert.Equal(
            [["owner", "radu"], ["weight", "2"]],
            ProjectionQueries.Rows(projection, "SELECT key, value FROM directive_metadata WHERE directive_id = 2 ORDER BY id"));
    }

    [Fact]
    public async Task SourceReadersFillWhatThePythonBackendLeavesOut()
    {
        var source = new PythonBackend(BeancountBackend.Python("python.exe"), Samples.PythonRunner(), runLedgerPlugins: false, "Python Beancount");

        using var projection = await BuildAsync(source);

        // The tolerance comes from the source; the difference is what was booked before the date minus what was asserted.
        Assert.Equal(
            [["2026-01-02", "500.00", null, "0", "USD"], ["2026-02-01", "2450.00", "0.01", "0", "USD"]],
            ProjectionQueries.Rows(projection, "SELECT date, amount, tolerance, difference_amount, difference_currency FROM balance_assertions ORDER BY id"));

        var main = Path.Combine(Samples.Directory, "main.beancount");
        Assert.Equal(["food", main, 14L, main + ":14"], ProjectionQueries.Rows(projection, "SELECT name, source_file, line, source_location FROM queries")[0]);
        Assert.Equal(["budget", 12L], ProjectionQueries.Rows(projection, "SELECT type, line FROM custom")[0]);
        Assert.Equal(
            [[0L, "account", "Expenses:Food", null, null], [1L, "amount", "400.00 USD", "400.00", "USD"], [2L, "boolean", "TRUE", null, null], [3L, "string", "monthly", null, null]],
            ProjectionQueries.Rows(projection, "SELECT position, value_type, value, number, currency FROM custom_values ORDER BY position"));
        Assert.Equal(3L, ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM source_files"));
        Assert.Equal("Opened online", ProjectionQueries.Scalar(projection, "SELECT comment FROM notes"));
    }

    [Fact]
    public async Task PythonRunsTheScriptFromStandardInputWithPluginsOff()
    {
        var runner = Samples.PythonRunner();
        var source = new PythonBackend(BeancountBackend.Python(@"C:\fake\py.exe", "-3"), runner, runLedgerPlugins: false, "Python Beancount");

        using var projection = await BuildAsync(source);

        var run = Assert.Single(runner.Runs);
        Assert.Equal(@"C:\fake\py.exe", run.Executable);
        Assert.Equal(["-3", "-", Samples.Ledger], run.Arguments);
        Assert.Equal(PythonProjectionScript.Source, run.StandardInput);
        Assert.Equal("0", run.Environment!["TABLEPRO_BEANCOUNT_RUN_LEDGER_PLUGINS"]);
        Assert.Equal("1", run.Environment["PYTHONUTF8"]);
    }

    [Fact]
    public async Task PythonErrorsAreTheLedgerErrors()
    {
        var runner = new FakeProcessRunner(_ => FakeProcessRunner.Fail("main.beancount:3: Invalid token"));
        var source = new PythonBackend(BeancountBackend.Python("python.exe"), runner, runLedgerPlugins: true, "Python Beancount");

        var error = await Assert.ThrowsAsync<BeancountException>(() => BuildAsync(source));

        Assert.Equal("main.beancount:3: Invalid token", error.Message);
        Assert.Equal("1", Assert.Single(runner.Runs).Environment!["TABLEPRO_BEANCOUNT_RUN_LEDGER_PLUGINS"]);
    }

    [Fact]
    public async Task PostingForAMissingTransactionFailsTheBuild()
    {
        var runner = new FakeProcessRunner(_ => FakeProcessRunner.Ok("""
            {"transactions":[],"postings":[{"transaction_id":7,"date":"2026-01-01","account":"Assets:Cash"}]}
            """));
        var source = new PythonBackend(BeancountBackend.Python("python.exe"), runner, runLedgerPlugins: false, "Python Beancount");

        var error = await Assert.ThrowsAsync<BeancountException>(() => BuildAsync(source));

        Assert.Contains("missing transaction ID 7", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ProjectionIsReadOnly()
    {
        var source = new PythonBackend(BeancountBackend.Python("python.exe"), Samples.PythonRunner(), runLedgerPlugins: false, "Python Beancount");
        using var projection = await BuildAsync(source);

        using var connection = new SqliteConnection(projection.ConnectionString);
        connection.Open();
        using (var pragma = connection.CreateCommand())
        {
            pragma.CommandText = "PRAGMA query_only = ON";
            pragma.ExecuteNonQuery();
        }

        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM transactions";
        Assert.Throws<SqliteException>(() => command.ExecuteNonQuery());
    }

    [Fact]
    public async Task RetiredProjectionOutlivesItsLeases()
    {
        var source = new PythonBackend(BeancountBackend.Python("python.exe"), Samples.PythonRunner(), runLedgerPlugins: false, "Python Beancount");
        var projection = await BuildAsync(source);

        projection.AddLease();
        projection.Retire();
        Assert.Equal(3L, ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM transactions"));

        projection.ReleaseLease();
        var error = Assert.Throws<SqliteException>(() => ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM transactions"));
        Assert.Contains("no such table", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RledgerOutputProjectsWithColumnFallbacks()
    {
        var runner = RledgerResponses.Runner();
        var source = new RledgerBackend(BeancountBackend.Rledger(@"C:\tools\rledger.exe"), runner, new RledgerCapabilities());

        using var projection = await BuildAsync(source);

        Assert.Equal("rledger 0.23.1", projection.BackendVersion);
        Assert.Equal(2L, ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM transactions"));
        Assert.Equal(
            [["invoice", "INV-1"]],
            ProjectionQueries.Rows(projection, "SELECT key, value FROM transaction_metadata ORDER BY id"));
        Assert.Equal("payroll", ProjectionQueries.Scalar(projection, "SELECT tag FROM transaction_tags"));
        Assert.Equal(4L, ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM postings"));
        Assert.Equal("receipt", ProjectionQueries.Scalar(projection, "SELECT key FROM posting_metadata"));
        Assert.Equal(["Assets:Checking", "Equity:Opening"], ProjectionQueries.Rows(projection, "SELECT account, source_account FROM pads")[0]);
        Assert.Equal([null], ProjectionQueries.Rows(projection, "SELECT booking FROM accounts WHERE name = 'Assets:Checking'")[0]);
        Assert.Equal("2450.00", ProjectionQueries.Scalar(projection, "SELECT amount FROM balances WHERE account = 'Assets:Checking'"));
        Assert.Equal(["0.01", "-500"], ProjectionQueries.Rows(projection, "SELECT tolerance, difference_amount FROM balance_assertions WHERE date = '2026-02-01'")[0]);
        Assert.Equal(["E2001", 3L, "error"], ProjectionQueries.Rows(projection, "SELECT code, line, severity FROM diagnostics")[0]);
        Assert.Equal(["custom", "radu"], ProjectionQueries.Rows(projection, "SELECT d.type, m.value FROM directives d JOIN directive_metadata m ON m.directive_id = d.id")[0]);
        Assert.Equal("Opened online", ProjectionQueries.Scalar(projection, "SELECT comment FROM notes"));
        Assert.Equal(0L, ProjectionQueries.Scalar(projection, "SELECT COUNT(*) FROM events"));

        var queries = runner.Runs.Where(r => r.Arguments[0] == "query" && r.Arguments.Count > 2).ToList();
        Assert.All(queries, r => Assert.Equal(["query", "-f", "json", "--no-errors", "--no-cache", Samples.Ledger], r.Arguments.Take(6)));
    }

    [Fact]
    public async Task RledgerColumnLevelIsLearnedOncePerExecutable()
    {
        var capabilities = new RledgerCapabilities();
        var runner = RledgerResponses.Runner();
        var source = new RledgerBackend(BeancountBackend.Rledger(@"C:\tools\rledger.exe"), runner, capabilities);

        using (await BuildAsync(source))
        {
        }

        var firstHelp = runner.Runs.Count(r => r.Arguments is ["query", "--help"]);
        using (await BuildAsync(source))
        {
        }

        Assert.Equal(PostingsColumnLevel.Source, capabilities.PostingsLevels[@"C:\tools\rledger.exe"]);
        Assert.Equal(EntriesMetadataColumn.Meta, capabilities.MetadataColumns[@"C:\tools\rledger.exe"]);
        Assert.Equal(1, firstHelp);
        Assert.Equal(1, runner.Runs.Count(r => r.Arguments is ["query", "--help"]));
        Assert.Equal(1, runner.Runs.Count(r => r.Arguments.Count > 0 && r.Arguments[^1].StartsWith("SELECT id, date, flag, payee, narration, account, number, currency, cost_number, cost_currency, posting_flag", StringComparison.Ordinal)));
    }

    [Fact]
    public async Task BuildThatOutrunsTheTimeoutFailsAndStopsTheBackend()
    {
        var cancelled = new TaskCompletionSource();
        var runner = new FakeProcessRunner(async (_, ct) =>
        {
            await using (ct.Register(() => cancelled.TrySetResult()))
            {
                await Task.Delay(Timeout.Infinite, ct);
            }

            return FakeProcessRunner.Ok("{}");
        });
        var source = new PythonBackend(BeancountBackend.Python("python.exe"), runner, runLedgerPlugins: false, "Python Beancount");
        var projector = new BeancountProjector(Samples.Ledger, TimeSpan.FromMilliseconds(200), _ => Task.FromResult<IBeancountProjectionSource>(source));

        var error = await Assert.ThrowsAsync<BeancountException>(() => projector.BuildAsync(TestContext.Current.CancellationToken));

        Assert.StartsWith("Failed to open Beancount ledger: Connection timed out", error.Message, StringComparison.Ordinal);
        Assert.True(cancelled.Task.IsCompleted);
    }

    [Fact]
    public async Task CallerCancellationIsNotATimeout()
    {
        var runner = new FakeProcessRunner(async (_, ct) =>
        {
            await Task.Delay(Timeout.Infinite, ct);
            return FakeProcessRunner.Ok("{}");
        });
        var source = new PythonBackend(BeancountBackend.Python("python.exe"), runner, runLedgerPlugins: false, "Python Beancount");
        var projector = new BeancountProjector(Samples.Ledger, TimeSpan.FromSeconds(30), _ => Task.FromResult<IBeancountProjectionSource>(source));
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => projector.BuildAsync(cancellation.Token));
    }

    [Fact]
    public async Task LedgerThatKeepsChangingDuringTheBuildIsRefused()
    {
        using var temp = new TempDirectory();
        var ledger = temp.CopySamples();
        var counter = 0;
        var runner = new FakeProcessRunner(_ =>
        {
            File.AppendAllText(ledger, $"\n; edit {++counter}\n");
            return FakeProcessRunner.Ok(Samples.PythonOutput);
        });
        var source = new PythonBackend(BeancountBackend.Python("python.exe"), runner, runLedgerPlugins: false, "Python Beancount");

        var error = await Assert.ThrowsAsync<BeancountException>(() => BuildAsync(source, ledger));

        Assert.Contains("changed while building", error.Message, StringComparison.Ordinal);
        Assert.Equal(2, counter);
    }
}
