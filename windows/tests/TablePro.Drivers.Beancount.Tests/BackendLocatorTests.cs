namespace TablePro.Drivers.Beancount.Tests;

public sealed class BackendLocatorTests
{
    private static BeancountOptions Options(string? backend = null, string? python = null, string? rledger = null) =>
        new(@"C:\ledger\main.beancount", TimeSpan.FromSeconds(15), backend, python, rledger, RunLedgerPlugins: false);

    /// <summary>A machine whose PATH is two fake directories holding <paramref name="files"/>.</summary>
    private static BeancountBackendLocator Locator(
        IProcessRunner runner,
        string[] files,
        Dictionary<string, string>? variables = null) =>
        new(
            runner,
            name => name == "PATH" ? @"C:\bin;""C:\Program Files\Python""" : variables?.GetValueOrDefault(name),
            path => files.Contains(path, StringComparer.OrdinalIgnoreCase));

    /// <summary>Pythons that import beancount answer the probe; the rest fail it as a missing module does.</summary>
    private static FakeProcessRunner Probe(params string[] withBeancount) =>
        new(spec => withBeancount.Contains(spec.Executable, StringComparer.OrdinalIgnoreCase)
            ? FakeProcessRunner.Ok("3.1.0\n")
            : FakeProcessRunner.Fail("ModuleNotFoundError: No module named 'beancount'"));

    private static Task<BeancountBackend> Find(BeancountBackendLocator locator, BeancountOptions options) =>
        locator.ProjectionBackendAsync(options, TestContext.Current.CancellationToken);

    [Fact]
    public async Task PyLauncherOnPathComesFirstWithDashThree()
    {
        var runner = Probe(@"C:\bin\py.exe");
        var locator = Locator(runner, [@"C:\bin\py.exe", @"C:\Program Files\Python\python.exe", @"C:\bin\rledger.exe"]);

        var backend = await Find(locator, Options());

        Assert.Equal(BeancountBackend.Python(@"C:\bin\py.exe", "-3").ToString(), backend.ToString());
        Assert.Equal(["-3"], backend.PrefixArguments);
        Assert.Equal("Python Beancount 3.1.0", locator.PythonVersion(backend));
        var probe = Assert.Single(runner.Runs);
        Assert.Equal(["-3", "-c", BeancountBackendLocator.PythonProbeScript], probe.Arguments);
    }

    [Fact]
    public async Task PythonWithoutBeancountFallsThroughToTheNextCandidate()
    {
        var runner = Probe(@"C:\Program Files\Python\python.exe");
        var locator = Locator(runner, [@"C:\bin\py.exe", @"C:\Program Files\Python\python.exe"]);

        var backend = await Find(locator, Options());

        Assert.Equal(@"C:\Program Files\Python\python.exe", backend.Executable);
        Assert.Empty(backend.PrefixArguments);
        Assert.Equal(2, runner.Runs.Count);
    }

    [Fact]
    public async Task RledgerOnPathIsTheLastResort()
    {
        var locator = Locator(Probe(), [@"C:\bin\py.exe", @"C:\Program Files\Python\rledger.exe"]);

        var backend = await Find(locator, Options());

        Assert.Equal(BeancountBackendKind.Rledger, backend.Kind);
        Assert.Equal(@"C:\Program Files\Python\rledger.exe", backend.Executable);
    }

    [Fact]
    public async Task NothingFoundNamesWhatToInstall()
    {
        var locator = Locator(Probe(), [@"C:\bin\python.exe", @"C:\bin\rledger.cmd"]);

        var error = await Assert.ThrowsAsync<BeancountException>(() => Find(locator, Options()));

        Assert.Contains("pip install beancount", error.Message, StringComparison.Ordinal);
        Assert.Contains("rledger", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task BackendOptionPicksRledgerEvenWhenPythonWorks()
    {
        var runner = Probe(@"C:\bin\py.exe");
        var locator = Locator(runner, [@"C:\bin\py.exe", @"C:\bin\rledger.exe"]);

        var backend = await Find(locator, Options(backend: "rledger"));

        Assert.Equal(BeancountBackendKind.Rledger, backend.Kind);
        Assert.Equal(@"C:\bin\rledger.exe", backend.Executable);
        Assert.Empty(runner.Runs);
    }

    [Fact]
    public async Task RledgerBackendWithoutRledgerSaysSo()
    {
        var locator = Locator(Probe(@"C:\bin\py.exe"), [@"C:\bin\py.exe"]);

        var error = await Assert.ThrowsAsync<BeancountException>(() => Find(locator, Options(backend: "rledger")));

        Assert.Contains("rledger.exe", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task PythonBackendWithoutBeancountNamesThePackage()
    {
        var locator = Locator(Probe(), [@"C:\bin\py.exe", @"C:\bin\rledger.exe"]);

        var error = await Assert.ThrowsAsync<BeancountException>(() => Find(locator, Options(backend: "Python")));

        Assert.Contains("pip install beancount", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task UnknownBackendIsRefused()
    {
        var locator = Locator(Probe(), []);

        var error = await Assert.ThrowsAsync<BeancountException>(() => Find(locator, Options(backend: "hledger")));

        Assert.Contains("\"hledger\"", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConfiguredPythonPathWinsOverPath()
    {
        var runner = Probe(@"D:\envs\ledger\python.exe");
        var locator = Locator(runner, [@"C:\bin\py.exe", @"D:\envs\ledger\python.exe"]);

        var backend = await Find(locator, Options(python: @"D:\envs\ledger\python.exe"));

        Assert.Equal(@"D:\envs\ledger\python.exe", backend.Executable);
        Assert.Single(runner.Runs);
    }

    [Fact]
    public async Task ConfiguredPythonThatCannotImportBeancountIsAnErrorNotAFallback()
    {
        var locator = Locator(Probe(@"C:\bin\py.exe"), [@"C:\bin\py.exe", @"D:\envs\python.exe"]);

        var error = await Assert.ThrowsAsync<BeancountException>(() => Find(locator, Options(python: @"D:\envs\python.exe")));

        Assert.Contains("cannot import beancount", error.Message, StringComparison.Ordinal);
        Assert.Contains("-m pip install beancount", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConfiguredPathThatDoesNotExistIsNamed()
    {
        var locator = Locator(Probe(), []);

        var python = await Assert.ThrowsAsync<BeancountException>(() => Find(locator, Options(python: @"D:\nope\python.exe")));
        var rledger = await Assert.ThrowsAsync<BeancountException>(() => Find(locator, Options(rledger: @"D:\nope\rledger.exe")));

        Assert.Contains(@"D:\nope\python.exe", python.Message, StringComparison.Ordinal);
        Assert.Contains(@"D:\nope\rledger.exe", rledger.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConfiguredRledgerPathIsUsedWithoutABackendOption()
    {
        var locator = Locator(Probe(@"C:\bin\py.exe"), [@"C:\bin\py.exe", @"E:\tools\rledger.exe"]);

        var backend = await Find(locator, Options(rledger: "\"E:\\tools\\rledger.exe\""));

        Assert.Equal(BeancountBackendKind.Rledger, backend.Kind);
        Assert.Equal(@"E:\tools\rledger.exe", backend.Executable);
    }

    [Fact]
    public async Task EnvironmentVariablesStandInForTheOptions()
    {
        var runner = Probe(@"F:\py\python.exe");
        var locator = Locator(
            runner,
            [@"C:\bin\rledger.exe", @"F:\py\python.exe"],
            new Dictionary<string, string> { [BeancountBackendLocator.PythonVariable] = @"F:\py\python.exe" });

        var backend = await Find(locator, Options());

        Assert.Equal(@"F:\py\python.exe", backend.Executable);
    }

    [Fact]
    public async Task OptionsOverrideEnvironmentVariables()
    {
        var locator = Locator(
            Probe(@"C:\bin\py.exe"),
            [@"C:\bin\py.exe", @"C:\bin\rledger.exe"],
            new Dictionary<string, string> { [BeancountBackendLocator.BackendVariable] = "rledger" });

        var backend = await Find(locator, Options(backend: "python"));

        Assert.Equal(BeancountBackendKind.Python, backend.Kind);
    }

    [Fact]
    public async Task SuccessfulProbeIsRememberedButAFailedOneIsAskedAgain()
    {
        var runner = Probe(@"C:\bin\py.exe");
        var locator = Locator(runner, [@"C:\bin\py.exe"]);

        await Find(locator, Options());
        await Find(locator, Options());

        Assert.Single(runner.Runs);

        var failing = Probe();
        var other = Locator(failing, [@"C:\bin\py.exe"]);
        await Assert.ThrowsAsync<BeancountException>(() => Find(other, Options()));
        await Assert.ThrowsAsync<BeancountException>(() => Find(other, Options()));
        Assert.Equal(2, failing.Runs.Count);
    }

    [Fact]
    public void BqlNeedsRledgerWhicheverBackendProjected()
    {
        var locator = Locator(Probe(), [@"C:\bin\rledger.exe"]);
        var missing = Locator(Probe(), []);

        Assert.Equal(@"C:\bin\rledger.exe", locator.QueryBackend(Options()).Executable);
        var error = Assert.Throws<BeancountException>(() => missing.QueryBackend(Options(backend: "python")));
        Assert.StartsWith("BQL queries need rledger", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void OptionsComeFromTheProfile()
    {
        var request = Samples.Request(
            @"%TEMP%\ledger.beancount",
            new Dictionary<string, string> { ["Backend"] = "rledger", ["python"] = " ", ["rledger"] = @"C:\r.exe", ["beancountRunLedgerPlugins"] = "true" },
            timeoutSeconds: 0);

        var options = BeancountOptions.From(request);

        Assert.Equal(Path.Combine(Environment.GetEnvironmentVariable("TEMP")!, "ledger.beancount"), options.LedgerPath, StringComparer.OrdinalIgnoreCase);
        Assert.Equal("rledger", options.Backend);
        Assert.Null(options.PythonPath);
        Assert.Equal(@"C:\r.exe", options.RledgerPath);
        Assert.True(options.RunLedgerPlugins);
        Assert.Equal(TimeSpan.FromSeconds(1), options.Timeout);
    }
}
