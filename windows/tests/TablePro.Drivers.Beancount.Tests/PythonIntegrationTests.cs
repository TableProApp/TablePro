using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Beancount.Tests;

/// <summary>Runs the real Python Beancount backend over the sample ledger when TABLEPRO_BEANCOUNT_PYTHON names a Python that has it.</summary>
public sealed class PythonIntegrationTests
{
    private static string Python()
    {
        var python = Environment.GetEnvironmentVariable(BeancountBackendLocator.PythonVariable);
        Assert.SkipWhen(string.IsNullOrWhiteSpace(python), $"Set {BeancountBackendLocator.PythonVariable} to a Python with beancount installed to run the integration tests.");
        return python!;
    }

    private static async Task<IDatabaseSession> ConnectAsync(string ledger, string python) =>
        await new BeancountDriver().ConnectAsync(
            Samples.Request(ledger, new Dictionary<string, string> { ["backend"] = "python", ["python"] = python }, timeoutSeconds: 120),
            TestContext.Current.CancellationToken);

    private static async Task<ResultSet> QueryAsync(IDatabaseSession session, string sql)
    {
        await using var channel = await session.OpenChannelAsync(TestContext.Current.CancellationToken);
        await foreach (var result in channel.ExecuteAsync([sql], new ExecuteOptions(), TestContext.Current.CancellationToken))
        {
            Assert.True(result.Succeeded, result.Error);
            return result.ResultSets[0];
        }

        throw new InvalidOperationException("No result.");
    }

    [Fact]
    public async Task SampleLedgerProjects()
    {
        var python = Python();
        await using var session = await ConnectAsync(Samples.Ledger, python);

        Assert.StartsWith("Python Beancount", session.ServerVersion, StringComparison.Ordinal);
        Assert.Contains(await session.GetObjectsAsync(null, TestContext.Current.CancellationToken), o => o.Name == new ObjectName(null, "postings"));

        var salary = await QueryAsync(session, "SELECT t.payee, p.amount FROM transactions t JOIN postings p ON p.transaction_id = t.id WHERE p.account = 'Income:Salary'");
        Assert.Equal<object?>(["Employer", "-2000.00"], salary.Rows[0]);

        var balance = await QueryAsync(session, "SELECT amount FROM balances WHERE account = 'Assets:Checking'");
        Assert.Equal("2450.00", balance.Rows[0][0]);

        var assertion = await QueryAsync(session, "SELECT tolerance, difference_amount FROM balance_assertions WHERE date = '2026-02-01'");
        Assert.Equal<object?>(["0.01", "0"], assertion.Rows[0]);

        var custom = await QueryAsync(session, "SELECT COUNT(*) FROM custom_values");
        Assert.Equal(4L, custom.Rows[0][0]);

        var tags = await QueryAsync(session, "SELECT tag FROM transaction_tags");
        Assert.Equal("payroll", tags.Rows[0][0]);
    }

    [Fact]
    public async Task EditedLedgerIsProjectedAgain()
    {
        var python = Python();
        using var temp = new TempDirectory();
        var ledger = temp.CopySamples();
        await using var session = await ConnectAsync(ledger, python);

        File.AppendAllText(Path.Combine(temp.Path, "transactions", "2026-01.beancount"), """

            2026-01-20 * "Cafe" "Coffee"
              Expenses:Food        4.50 USD
              Assets:Checking

            """);

        var count = await QueryAsync(session, "SELECT COUNT(*) FROM transactions WHERE payee = 'Cafe'");
        Assert.Equal(1L, count.Rows[0][0]);
    }

    [Fact]
    public async Task LedgerErrorsReachTheUser()
    {
        var python = Python();
        using var temp = new TempDirectory();
        var ledger = temp.Write("main.beancount", "2026-01-01 open Assets:Cash\n2026-01-02 * \"x\"\n  Assets:Missing 1 USD\n  Assets:Cash\n");

        var error = await Assert.ThrowsAsync<BeancountException>(() => ConnectAsync(ledger, python));

        Assert.Contains("Assets:Missing", error.Message, StringComparison.Ordinal);
    }
}
