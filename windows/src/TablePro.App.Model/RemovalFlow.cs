using TablePro.Interop;

namespace TablePro.App.Model;

public enum RemovalStep
{
    EnterKey,
    Review,

    // The teams whose seats the person removes on the web, since membership changes only there.
    Seats,
    Done,
}

// One team's teammates the review lists, in the order it listed them.
public sealed record RemovalTeam(string Team, string? Name, IReadOnlyList<ReviewedMember> Members);

// Removing a lost device after its row is gone (core ADR 0056, Removing a device, steps 2 to 4): the recovery key, the
// review of devices to keep and teammates to leave out, the web for the seats of those left out, then the rotation,
// which leaves them out whatever the server still lists. Everything runs on the UI thread.
public sealed class RemovalFlow
{
    private readonly Func<Task<IKeyFlows>> _flows;
    private readonly HashSet<string> _keep = new(StringComparer.Ordinal);
    private readonly HashSet<string> _removing = new(StringComparer.Ordinal);
    private HashSet<string> _submitted = new(StringComparer.Ordinal);
    private bool _closed;

    public RemovalFlow(KeyDevice lost, Func<Task<IKeyFlows>> flows)
    {
        ArgumentNullException.ThrowIfNull(lost);
        ArgumentNullException.ThrowIfNull(flows);
        Lost = lost;
        _flows = flows;
    }

    public event EventHandler? Changed;

    public KeyDevice Lost { get; }

    public RemovalStep Step { get; private set; }

    public bool IsWorking { get; private set; }

    public CoreError? Failure { get; private set; }

    // The rotation started and failed, so another try needs the recovery key again.
    public bool FailedRotation { get; private set; }

    public string RecoveryKey { get; set; } = string.Empty;

    public RemovalReview? Review { get; private set; }

    public bool CanContinue => !IsWorking && Step switch
    {
        RemovalStep.EnterKey => !string.IsNullOrWhiteSpace(RecoveryKey),
        RemovalStep.Review => Review is not null,
        _ => true,
    };

    // A teammate is one account in one team.
    public static string MemberId(ReviewedMember member)
    {
        ArgumentNullException.ThrowIfNull(member);
        return member.Team + "/" + member.Account;
    }

    // Only a device this PC compared words with can keep its keys; every other one joins again by approval.
    public bool CanKeep(ReviewedDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        return device.Device.Compared && !device.Device.IsThisDevice && device.Device.KeyDeviceId != Lost.KeyDeviceId;
    }

    public bool Keeps(ReviewedDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        return _keep.Contains(device.Device.KeyDeviceId);
    }

    public void SetKeep(ReviewedDevice device, bool kept)
    {
        if (Step != RemovalStep.Review || IsWorking || !CanKeep(device))
        {
            return;
        }

        _ = kept ? _keep.Add(device.Device.KeyDeviceId) : _keep.Remove(device.Device.KeyDeviceId);
        Raise();
    }

    public bool Removes(ReviewedMember member) => _removing.Contains(MemberId(member));

    public void SetRemoving(ReviewedMember member, bool removes)
    {
        ArgumentNullException.ThrowIfNull(member);
        if (Step != RemovalStep.Review || IsWorking || member.IsSelf)
        {
            return;
        }

        _ = removes ? _removing.Add(MemberId(member)) : _removing.Remove(MemberId(member));
        Raise();
    }

    public IReadOnlyList<RemovalTeam> Teams
    {
        get
        {
            if (Review is not { } review)
            {
                return [];
            }

            return [.. review.Members
                .GroupBy(member => member.Team, StringComparer.Ordinal)
                .Select(team => new RemovalTeam(team.Key, team.First().TeamName, [.. team]))];
        }
    }

    // The teams whose seats the person removes on the web, for the teammates marked.
    public IReadOnlyList<RemovalTeam> TeamsToVisit =>
        [.. Teams.Where(team => team.Members.Any(member => _submitted.Contains(MemberId(member))))];

    public async Task AdvanceAsync()
    {
        if (!CanContinue)
        {
            return;
        }

        Failure = null;
        switch (Step)
        {
            case RemovalStep.EnterKey:
                await BeginReviewAsync().ConfigureAwait(true);
                break;
            case RemovalStep.Review:
                _submitted = new HashSet<string>(_removing, StringComparer.Ordinal);
                if (_submitted.Count == 0)
                {
                    await FinishAsync().ConfigureAwait(true);
                }
                else
                {
                    Step = RemovalStep.Seats;
                    Raise();
                }

                break;
            case RemovalStep.Seats:
                await FinishAsync().ConfigureAwait(true);
                break;
        }
    }

    // From the seats step, before anything rotated.
    public void BackToReview()
    {
        if (Step != RemovalStep.Seats || IsWorking)
        {
            return;
        }

        Failure = null;
        Step = RemovalStep.Review;
        Raise();
    }

    // The dialog closed: a review the rotation never took is dropped in the core too.
    public async Task DiscardAsync()
    {
        _closed = true;
        RecoveryKey = string.Empty;
        if (Review is { } review && Step != RemovalStep.Done)
        {
            try
            {
                (await _flows().ConfigureAwait(true)).DiscardKeyDraft(review.Review);
            }
            catch (Exception exception) when (KeyErrors.Of(exception) is not null)
            {
                // A service closed meanwhile dropped its drafts with it.
            }
        }
    }

    private async Task BeginReviewAsync()
    {
        var recoveryKey = RecoveryKey.Trim();
        IsWorking = true;
        Raise();
        try
        {
            var flows = await _flows().ConfigureAwait(true);
            var review = await flows.BeginDeviceRemovalAsync(recoveryKey, [Lost.KeyDeviceId]).ConfigureAwait(true);
            if (_closed)
            {
                flows.DiscardKeyDraft(review.Review);
                return;
            }

            RecoveryKey = string.Empty;
            // Another review after a failed rotation keeps the choices made, where it lists them again.
            var again = Review is not null;
            Review = review;
            var keepable = review.Devices.Where(CanKeep).Select(device => device.Device.KeyDeviceId).ToHashSet();
            var kept = again
                ? [.. _keep]
                : review.Devices.Where(device => device.KeepByDefault).Select(device => device.Device.KeyDeviceId).ToList();
            _keep.Clear();
            _keep.UnionWith(kept.Where(keepable.Contains));
            var listed = review.Members.Select(MemberId).ToHashSet();
            if (again)
            {
                _removing.IntersectWith(listed);
            }
            else
            {
                _removing.Clear();
            }

            FailedRotation = false;
            Step = RemovalStep.Review;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            if (!_closed)
            {
                Failure = error;
            }
        }
        finally
        {
            IsWorking = false;
            Raise();
        }
    }

    private async Task FinishAsync()
    {
        if (Review is not { } review)
        {
            return;
        }

        string[] keep = [.. review.Devices.Select(device => device.Device.KeyDeviceId).Where(_keep.Contains)];
        ReviewedMember[] remove = [.. review.Members.Where(member => _submitted.Contains(MemberId(member)))];
        IsWorking = true;
        Raise();
        try
        {
            await (await _flows().ConfigureAwait(true))
                .FinishDeviceRemovalAsync(review.Review, keep, remove)
                .ConfigureAwait(true);
            Step = RemovalStep.Done;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            if (!_closed)
            {
                // The core takes the review as the rotation starts, so another try needs a new one.
                Failure = error;
                FailedRotation = true;
                Step = RemovalStep.EnterKey;
            }
        }
        finally
        {
            IsWorking = false;
            Raise();
        }
    }

    private void Raise() => Changed?.Invoke(this, EventArgs.Empty);
}
