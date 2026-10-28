using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.App.Services;

/// <summary>A session to copy into, and whether this copy opened it and so closes it afterwards.</summary>
public sealed class CopyTargetLease(IDatabaseSession session, IAsyncDisposable? owned) : IAsyncDisposable
{
    public IDatabaseSession Session { get; } = session;

    public ValueTask DisposeAsync() => owned?.DisposeAsync() ?? ValueTask.CompletedTask;
}

/// <summary>
/// The connections a copy can write to and how to reach one: an open window's session is borrowed, any other saved
/// connection is opened for the copy and closed after it. The copy dialog gets this instead of the app host.
/// </summary>
public sealed class CopyTargets(
    IReadOnlyList<ConnectionProfile> profiles,
    Func<ConnectionProfile, DialogService, CancellationToken, Task<CopyTargetLease?>> open,
    Action<ConnectionProfile>? copied = null)
{
    /// <summary>The connections offered, the one the copy starts from first.</summary>
    public IReadOnlyList<ConnectionProfile> Profiles { get; } = profiles;

    /// <summary>Connects, asking for a password the user has not saved; null when the user cancels that prompt.</summary>
    public Task<CopyTargetLease?> OpenAsync(ConnectionProfile profile, DialogService dialogs, CancellationToken cancellationToken) =>
        open(profile, dialogs, cancellationToken);

    /// <summary>Tells the target's window, if one is open, that its schema changed.</summary>
    public void Copied(ConnectionProfile profile) => copied?.Invoke(profile);

    /// <summary>Every SQL connection the app knows, through the host's store, open windows and connector.</summary>
    public static CopyTargets From(AppHost host, WorkspaceContext current)
    {
        ArgumentNullException.ThrowIfNull(host);
        ArgumentNullException.ThrowIfNull(current);
        var origin = current.Session.Profile;
        var others = host.Connections.Connections
            .Where(p => p.Id != origin.Id && p.Descriptor.IsSql && !p.IsReadOnly && host.Connector.Drivers.Supports(p.Engine))
            .OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase);
        return new CopyTargets(
            [origin, .. others],
            async (profile, dialogs, cancellationToken) =>
            {
                if (profile.Id == origin.Id)
                {
                    return new CopyTargetLease(current.Session.Database, null);
                }

                if (host.FindWorkspace(profile.Id) is { } window)
                {
                    return new CopyTargetLease(window.ViewModel.Session.Database, null);
                }

                var password = host.Connector.SavedPassword(profile);
                if (password is null && host.Connector.NeedsPasswordPrompt(profile))
                {
                    password = await dialogs.PromptPassphraseAsync($"Connect to {profile.Name}", "Enter the password to copy into this connection.", confirm: false, "Connect");
                    if (password is null)
                    {
                        return null;
                    }
                }

                var (session, _) = await host.Connector.ConnectAsync(profile, password, cancellationToken, remember: false);
                return new CopyTargetLease(session.Database, session);
            },
            profile =>
            {
                if (profile.Id == origin.Id)
                {
                    current.NotifySchemaChanged();
                }
                else
                {
                    host.FindWorkspace(profile.Id)?.ViewModel.Context.NotifySchemaChanged();
                }
            });
    }
}
