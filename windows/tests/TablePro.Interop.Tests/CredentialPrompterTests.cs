using Native = TablePro.Interop.Native;

namespace TablePro.Interop.Tests;

public sealed class CredentialPrompterTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task EndingTheLoginRejectsALateTrustAnswerEvenWhenTheDialogIgnoresCancellation(bool dispose)
    {
        var host = new PendingDialog();
        using var adapter = new CredentialPrompterAdapter(host);
        var pending = Task.Run(() => adapter.Prompt(HostKey()), TestContext.Current.CancellationToken);
        var token = await host.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        if (dispose)
        {
            adapter.Dispose();
        }
        else
        {
            adapter.Cancel();
        }

        Assert.IsType<Native.PromptAnswer.Cancelled>(
            await pending.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));
        Assert.True(token.IsCancellationRequested);
        host.Answer.SetResult(new CredentialAnswer([]));
        Assert.IsType<Native.PromptAnswer.Cancelled>(adapter.Prompt(HostKey()));
        Assert.Equal(1, host.Calls);
        adapter.Cancel();
    }

    [Fact]
    public void ADialogExceptionNeverCountsAsTrustAndDoesNotCrossTheNativeBoundary()
    {
        using var adapter = new CredentialPrompterAdapter(new BrokenDialog());

        Assert.IsType<Native.PromptAnswer.Cancelled>(adapter.Prompt(HostKey()));
    }

    private static Native.PromptRequest HostKey() =>
        new(new Native.PromptPurposeTag.SshHostKey("db.example.com", "ED25519", "SHA256:example"),
            "user@db.example.com", [], false);

    private sealed class PendingDialog : ICredentialPrompter
    {
        public TaskCompletionSource<CancellationToken> Entered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource<CredentialAnswer?> Answer { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public int Calls { get; private set; }

        public Task<CredentialAnswer?> PromptAsync(CredentialPrompt prompt, CancellationToken cancellationToken)
        {
            Calls++;
            Entered.TrySetResult(cancellationToken);
            return Answer.Task;
        }
    }

    private sealed class BrokenDialog : ICredentialPrompter
    {
        public Task<CredentialAnswer?> PromptAsync(CredentialPrompt prompt, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("The window closed before the dialog opened.");
    }
}
