using TablePro.Interop;

namespace TablePro.App.Model;

// The core's end-to-end key calls (core ADR 0056) as the flows make them, so each flow is tested without the core.
public interface IKeyFlows
{
    Task<KeyState> GetKeyStateAsync();

    Task<RecoveryKeyDraft> BeginGenesisAsync();

    Task<GenesisOutcome> FinishGenesisAsync(string draft, IReadOnlyList<string> typed);

    void DiscardKeyDraft(string draft);

    Task<KeysSignOutOutcome> SignOutKeysAsync();

    Task<RotationDraft> BeginReplaceRecoveryKeyAsync(string recoveryKey);

    Task FinishReplaceRecoveryKeyAsync(string draft, IReadOnlyList<string> typed, IReadOnlyList<string> keep);

    Task<IReadOnlyList<KeyNotice>> GetKeyNoticesAsync();

    Task DismissKeyNoticeAsync(string notice);

    Task<string> RequestApprovalAsync();

    Task<IReadOnlyList<ApprovalRequest>> GetApprovalRequestsAsync();

    Task<ApprovalSession> ChooseApprovalRequestAsync(string request);

    Task<ApprovalSession> GetApprovalSessionAsync(string request);

    Task<ApprovalSession> ConfirmApprovalSessionAsync(string request);

    Task ApprovalWordsDifferAsync(string request);

    Task CancelApprovalSessionAsync(string request);

    Task<IReadOnlyList<KeyDevice>> GetAccountDevicesAsync();

    Task RemoveDeviceRowAsync(string device);

    Task<RemovalReview> BeginDeviceRemovalAsync(string recoveryKey, IReadOnlyList<string> lost);

    Task FinishDeviceRemovalAsync(string review, IReadOnlyList<string> keep, IReadOnlyList<ReviewedMember> remove);

    Task RecoverWithRecoveryKeyAsync(string recoveryKey);

    Task<PendingReset?> GetPendingResetAsync();

    Task<RecoveryKeyDraft> BeginResetAsync(ResetKind kind);

    Task<PendingReset> FinishResetProposalAsync(string draft, IReadOnlyList<string> typed);

    Task CancelResetAsync(string reset, string? recoveryKey);

    Task ActivateResetAsync(string reset);

    Task ResumeResetAsync(string reset);
}

public static class KeyErrors
{
    // A call on a service a sign-in change closed meanwhile reads as the change it was.
    public static CoreError Changed { get; } =
        new("sync.changed", ["sync.changed"], "the sign-in changed during the call", null, null);

    // The core's error, or null for an exception the flows do not word.
    public static CoreError? Of(Exception exception) => exception switch
    {
        TableProException core => core.Error,
        ObjectDisposedException => Changed,
        _ => null,
    };
}

// RFC 9470's step-up as the key calls meet it: on a challenge the account steps up once and the call runs again; a
// second challenge goes to the caller, so a server that never takes the step-up cannot keep reopening the sign-in page.
public sealed class StepUpRetry(Func<StepUpChallenge, Task> stepUp)
{
    public async Task<T> RunAsync<T>(Func<Task<T>> call)
    {
        ArgumentNullException.ThrowIfNull(call);
        try
        {
            return await call().ConfigureAwait(true);
        }
        catch (TableProException exception) when (exception.Error.StepUp is { } challenge)
        {
            await stepUp(challenge).ConfigureAwait(true);
            return await call().ConfigureAwait(true);
        }
    }

    public Task RunAsync(Func<Task> call)
    {
        ArgumentNullException.ThrowIfNull(call);
        return RunAsync(async () =>
        {
            await call().ConfigureAwait(true);
            return true;
        });
    }
}

// The recovery key's 14 groups of 4, joined by '-' (core ADR 0056, The recovery key). The core reads what is typed
// back its own way: hyphens and spaces dropped, upper-cased, O as 0 and I and L as 1.
public static class RecoveryKeyText
{
    public static IReadOnlyList<string> Groups(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return text.Split('-', StringSplitOptions.RemoveEmptyEntries);
    }
}
