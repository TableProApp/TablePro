using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public interface ICredentialPrompter
{
    Task<CredentialAnswer?> PromptAsync(CredentialPrompt prompt, CancellationToken cancellationToken);
}

public sealed record CredentialPrompt(
    PromptPurpose Purpose,
    string Target,
    IReadOnlyList<PromptField> Fields,
    bool OfferRemember);

public sealed record PromptField(string Label, bool Secret);

public abstract record PromptPurpose
{
    private PromptPurpose() { }

    public sealed record DatabasePassword(PromptReason Reason) : PromptPurpose;
    public sealed record SshPassword(PromptReason Reason) : PromptPurpose;
    public sealed record SshPassphrase(string Path, PromptReason Reason) : PromptPurpose;
    public sealed record SshKeyboardInteractive(string Name, string Instructions) : PromptPurpose;
    public sealed record SshHostKey(string Host, string Algorithm, string Fingerprint) : PromptPurpose;
    public sealed record SshConfirmation(string Text) : PromptPurpose;
}

public enum PromptReason
{
    NotStored,
    KeyringLocked,
    KeyringUnavailable,
    Rejected,
}

public sealed record CredentialAnswer(IReadOnlyList<string> Values, bool Remember = false);

// A session keeps the callback for reconnects; closing it cancels any question still on screen.
internal sealed class CredentialPrompterAdapter(ICredentialPrompter prompter) : Native.HostPrompter, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _gate = new();
    private bool _disposed;

    public void Cancel()
    {
        lock (_gate)
        {
            if (!_disposed)
            {
                _lifetime.Cancel();
            }
        }
    }

    public Native.PromptAnswer Prompt(Native.PromptRequest prompt)
    {
        try
        {
            var token = _lifetime.Token;
            token.ThrowIfCancellationRequested();
            var answer = prompter.PromptAsync(new CredentialPrompt(
                Purpose(prompt.Purpose),
                prompt.Target,
                [.. prompt.Fields.Select(field => new PromptField(field.Label, field.Secret))],
                prompt.OfferRemember), token).WaitAsync(token).GetAwaiter().GetResult();
            token.ThrowIfCancellationRequested();
            return answer is null
                ? new Native.PromptAnswer.Cancelled()
                : new Native.PromptAnswer.Submitted([.. answer.Values], prompt.OfferRemember && answer.Remember);
        }
        catch (Exception)
        {
            // No managed exception may cross the callback boundary or count as permission to trust a host.
            return new Native.PromptAnswer.Cancelled();
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (!_disposed)
            {
                _lifetime.Cancel();
                _lifetime.Dispose();
                _disposed = true;
            }
        }
    }

    private static PromptPurpose Purpose(Native.PromptPurposeTag purpose) => purpose switch
    {
        Native.PromptPurposeTag.DatabasePassword value => new PromptPurpose.DatabasePassword(Reason(value.Reason)),
        Native.PromptPurposeTag.SshPassword value => new PromptPurpose.SshPassword(Reason(value.Reason)),
        Native.PromptPurposeTag.SshPassphrase value => new PromptPurpose.SshPassphrase(value.Path, Reason(value.Reason)),
        Native.PromptPurposeTag.SshKeyboardInteractive value => new PromptPurpose.SshKeyboardInteractive(value.Name, value.Instructions),
        Native.PromptPurposeTag.SshHostKey value => new PromptPurpose.SshHostKey(value.Host, value.Algorithm, value.Fingerprint),
        Native.PromptPurposeTag.SshConfirmation value => new PromptPurpose.SshConfirmation(value.Text),
        _ => throw new ArgumentOutOfRangeException(nameof(purpose)),
    };

    private static PromptReason Reason(Native.PromptReasonTag reason) => reason switch
    {
        Native.PromptReasonTag.NotStored => PromptReason.NotStored,
        Native.PromptReasonTag.KeyringLocked => PromptReason.KeyringLocked,
        Native.PromptReasonTag.KeyringUnavailable => PromptReason.KeyringUnavailable,
        Native.PromptReasonTag.Rejected => PromptReason.Rejected,
        _ => throw new ArgumentOutOfRangeException(nameof(reason)),
    };
}
