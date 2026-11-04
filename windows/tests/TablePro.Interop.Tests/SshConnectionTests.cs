using TablePro.Testing;

namespace TablePro.Interop.Tests;

public sealed class SshConnectionTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-ssh-").FullName;
    private readonly TableProCore _core;

    public SshConnectionTests()
    {
        _core = TableProCore.Create(new HostConfiguration("ssh-test", _directory), new MemorySecretStore());
    }

    [Theory]
    [InlineData(SshAuthMethod.Password)]
    [InlineData(SshAuthMethod.PrivateKey)]
    [InlineData(SshAuthMethod.Agent)]
    public async Task AWindowsSshLoginTestsConnectsAndQueriesPostgres(SshAuthMethod method)
    {
        Assert.SkipUnless(SshTestEnvironment.Available, "Requires the Windows SSH and PostgreSQL fixture.");
        var cancel = TestContext.Current.CancellationToken;
        var connection = Connection(method);
        var secrets = Secrets();
        var prompts = new TrustHost();

        await _core.TestConnectionAsync(connection, secrets, prompts, cancel);
        var saved = await _core.Library.SaveAsync(connection, secrets);
        await using var session = await _core.ConnectAsync(saved.Id!.Value, prompter: prompts, cancellationToken: cancel);
        var objects = await session.GetObjectsAsync(ObjectScope.DefaultSchema, cancel);
        Assert.Contains(objects, item => item.Name == "ssh_proof");
        await using var editor = await session.OpenEditorAsync(cancel);
        using var run = editor.Run("SELECT answer FROM ssh_proof", cancellationToken: cancel);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var result = run.GetResultSet(0);
        Assert.NotNull(result);
        Assert.Equal("42", result.GetCellText(0, 0));
    }

    [Fact]
    public async Task DecliningAnUnknownHostNeverOpensTheDatabase()
    {
        Assert.SkipUnless(SshTestEnvironment.Available, "Requires the Windows SSH and PostgreSQL fixture.");
        var prompts = new DeclineHost();
        var error = await Assert.ThrowsAsync<TableProException>(() => _core.TestConnectionAsync(
            Connection(SshAuthMethod.Password, 22222), Secrets(), prompts, TestContext.Current.CancellationToken));

        Assert.Equal("ssh.host_key_unknown", error.Code);
        Assert.Equal(1, prompts.Count);
    }

    [Fact]
    public async Task AnEncryptedKeyAsksForItsPassphraseThroughTheManagedCallback()
    {
        Assert.SkipUnless(SshTestEnvironment.Available, "Requires the Windows SSH and PostgreSQL fixture.");
        var connection = Connection(SshAuthMethod.PrivateKey);
        connection = connection with
        {
            Ssh = connection.Ssh! with { KeyPath = SshTestEnvironment.LockedSshKey, KeyHasPassphrase = false },
        };
        var prompts = new UnlockKey();

        await _core.TestConnectionAsync(connection, Secrets(), prompts, TestContext.Current.CancellationToken);

        Assert.True(prompts.AskedForPassphrase);
    }

    [Fact]
    public async Task CancellingWhileTheHostPromptIsOpenCancelsTheCallback()
    {
        Assert.SkipUnless(SshTestEnvironment.Available, "Requires the Windows SSH and PostgreSQL fixture.");
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var prompts = new WaitingHost();
        var connect = _core.TestConnectionAsync(Connection(SshAuthMethod.Password, 22222), Secrets(), prompts, cancel.Token);
        await prompts.Entered.Task.WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);

        await cancel.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => connect);
        await prompts.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
    }

    private static SavedConnection Connection(SshAuthMethod method, int sshPort = 22) =>
        new(null, "SSH PostgreSQL", "postgres", "127.0.0.1", SshTestEnvironment.DatabasePort,
            "tablepro_ssh", "tablepro_ssh", TlsSettings.Disabled,
            Ssh: new SshSettings("127.0.0.1", sshPort, SshTestEnvironment.SshUser, [], method,
                method == SshAuthMethod.PrivateKey ? SshTestEnvironment.SshKey : null));

    private static ConnectionSecrets Secrets() =>
        new(DatabasePassword: SshTestEnvironment.DatabasePassword, SshPassword: SshTestEnvironment.SshPassword);

    public void Dispose()
    {
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private sealed class TrustHost : ICredentialPrompter
    {
        public Task<CredentialAnswer?> PromptAsync(CredentialPrompt prompt, CancellationToken cancellationToken)
        {
            var key = Assert.IsType<PromptPurpose.SshHostKey>(prompt.Purpose);
            Assert.StartsWith("SHA256:", key.Fingerprint, StringComparison.Ordinal);
            Assert.Empty(prompt.Fields);
            return Task.FromResult<CredentialAnswer?>(new CredentialAnswer([]));
        }
    }

    private sealed class DeclineHost : ICredentialPrompter
    {
        public int Count { get; private set; }

        public Task<CredentialAnswer?> PromptAsync(CredentialPrompt prompt, CancellationToken cancellationToken)
        {
            Assert.IsType<PromptPurpose.SshHostKey>(prompt.Purpose);
            Count++;
            return Task.FromResult<CredentialAnswer?>(null);
        }
    }

    private sealed class UnlockKey : ICredentialPrompter
    {
        public bool AskedForPassphrase { get; private set; }

        public Task<CredentialAnswer?> PromptAsync(CredentialPrompt prompt, CancellationToken cancellationToken)
        {
            if (prompt.Purpose is PromptPurpose.SshHostKey)
            {
                return Task.FromResult<CredentialAnswer?>(new CredentialAnswer([]));
            }

            var key = Assert.IsType<PromptPurpose.SshPassphrase>(prompt.Purpose);
            Assert.Equal(SshTestEnvironment.LockedSshKey, key.Path);
            Assert.True(Assert.Single(prompt.Fields).Secret);
            AskedForPassphrase = true;
            return Task.FromResult<CredentialAnswer?>(new CredentialAnswer([SshTestEnvironment.SshPassphrase]));
        }
    }

    private sealed class WaitingHost : ICredentialPrompter
    {
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource Cancelled { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<CredentialAnswer?> PromptAsync(CredentialPrompt prompt, CancellationToken cancellationToken)
        {
            Assert.IsType<PromptPurpose.SshHostKey>(prompt.Purpose);
            Entered.TrySetResult();
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                return null;
            }
            finally
            {
                Cancelled.TrySetResult();
            }
        }
    }
}
