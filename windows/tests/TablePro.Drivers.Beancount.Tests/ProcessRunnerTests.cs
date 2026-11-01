using System.Diagnostics;

namespace TablePro.Drivers.Beancount.Tests;

/// <summary>Runs real processes through cmd.exe, which every Windows machine has.</summary>
public sealed class ProcessRunnerTests
{
    private static readonly string Cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");

    [Fact]
    public async Task ArgumentsArePassedAsTheyAreAndOutputIsCaptured()
    {
        var output = await SystemProcessRunner.Instance.RunAsync(
            new ProcessSpec(Cmd, ["/d", "/c", "echo %BEANCOUNT_TEST%& echo oops 1>&2& exit /b 3"], new Dictionary<string, string> { ["BEANCOUNT_TEST"] = "hello there" }),
            TestContext.Current.CancellationToken);

        Assert.Equal("hello there", output.StandardOutputText.Trim());
        Assert.Equal("oops", output.StandardError.Trim());
        Assert.Equal(3, output.ExitCode);
    }

    [Fact]
    public async Task StandardInputReachesTheProcess()
    {
        var output = await SystemProcessRunner.Instance.RunAsync(
            new ProcessSpec(Path.Combine(Environment.SystemDirectory, "findstr.exe"), ["^"], StandardInput: "line one\nline two\n"),
            TestContext.Current.CancellationToken);

        Assert.Equal(0, output.ExitCode);
        Assert.Equal(["line one", "line two"], output.StandardOutputText.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    }

    [Fact]
    public async Task MissingExecutableIsABeancountError()
    {
        var error = await Assert.ThrowsAsync<BeancountException>(() =>
            SystemProcessRunner.Instance.RunAsync(new ProcessSpec(@"C:\nowhere\python.exe", []), TestContext.Current.CancellationToken));

        Assert.Contains(@"C:\nowhere\python.exe", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task PythonReadsTheProjectionScriptFromStandardInputAndTheProbeFromItsArguments()
    {
        var locator = new BeancountBackendLocator(SystemProcessRunner.Instance);
        var python = locator.FindOnPath("py") is { } launcher ? BeancountBackend.Python(launcher, "-3")
            : locator.FindOnPath("python") is { } interpreter ? BeancountBackend.Python(interpreter)
            : null;
        Assert.SkipWhen(python is null, "No Python on PATH.");
        var token = TestContext.Current.CancellationToken;

        // A script with quotes, semicolons and non-ASCII text, as the real one has quotes and the ledger path may have accents.
        var script = await SystemProcessRunner.Instance.RunAsync(
            python!.Spec(["-", @"C:\Ledgers\Café ""x"".beancount"], PythonBackend.Environment(runLedgerPlugins: false), "import sys, os; print(sys.argv[1]); print(os.environ['TABLEPRO_BEANCOUNT_RUN_LEDGER_PLUGINS'])\n"),
            token);
        var probe = await SystemProcessRunner.Instance.RunAsync(python.Spec(["-c", BeancountBackendLocator.PythonProbeScript]), token);

        Assert.SkipWhen(script.ExitCode != 0 && script.StandardError.Contains("was not found", StringComparison.Ordinal), "The Python on PATH is the Microsoft Store stub.");
        Assert.Equal(0, script.ExitCode);
        Assert.Equal([@"C:\Ledgers\Café ""x"".beancount", "0"], script.StandardOutputText.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));

        // Either beancount imports, or the error is about the module: a mangled command line would be a SyntaxError instead.
        Assert.True(probe.ExitCode == 0 || probe.StandardError.Contains("beancount", StringComparison.Ordinal), probe.StandardError);
        Assert.DoesNotContain("SyntaxError", probe.StandardError, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CancellationKillsTheWholeTree()
    {
        // cmd starts ping as a child, as py.exe starts python.exe; both must be gone once the run is cancelled.
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
        var stopwatch = Stopwatch.StartNew();
        var before = Process.GetProcessesByName("PING").Select(p => p.Id).ToHashSet();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            SystemProcessRunner.Instance.RunAsync(new ProcessSpec(Cmd, ["/d", "/c", "ping", "-n", "30", "127.0.0.1"]), cancellation.Token));

        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(10));
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (Process.GetProcessesByName("PING").Any(p => !before.Contains(p.Id)) && DateTime.UtcNow < deadline)
        {
            await Task.Delay(50, TestContext.Current.CancellationToken);
        }

        Assert.DoesNotContain(Process.GetProcessesByName("PING"), p => !before.Contains(p.Id));
    }
}
