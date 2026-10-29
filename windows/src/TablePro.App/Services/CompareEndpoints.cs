using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.Core.Connections;
using TablePro.Storage.Compare;

namespace TablePro.App.Services;

/// <summary>The other side of a comparison: a session, and whether the compare tab opened it and must close it.</summary>
public sealed class CompareEndpoint(ConnectionSession session, bool owned) : IAsyncDisposable
{
    public ConnectionSession Session { get; } = session;

    public ConnectionProfile Profile => Session.Profile;

    public async ValueTask DisposeAsync()
    {
        if (owned)
        {
            await Session.DisposeAsync();
        }
    }
}

/// <summary>
/// Finds or opens the sessions a compare tab reads from. A connection already open in this or another window is
/// borrowed, so comparing against it costs no second login; any other is connected for the tab alone.
/// </summary>
public sealed class CompareEndpoints(AppHost host, DialogService dialogs)
{
    public IReadOnlyList<ConnectionProfile> Profiles => host.Connections.Connections;

    /// <summary>The saved comparisons, shared by every compare tab in every window.</summary>
    public CompareProfileStore ProfileStore => host.CompareProfiles;

    public async Task<CompareEndpoint?> OpenAsync(ConnectionProfile profile, ConnectionSession current, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(profile);
        ArgumentNullException.ThrowIfNull(current);
        if (profile.Id == current.Profile.Id)
        {
            return new CompareEndpoint(current, owned: false);
        }

        if (host.FindWorkspace(profile.Id) is { } open)
        {
            return new CompareEndpoint(open.ViewModel.Session, owned: false);
        }

        string? password = null;
        if (host.Connector.NeedsPasswordPrompt(profile))
        {
            password = await PromptPasswordAsync(profile);
            if (password is null)
            {
                return null;
            }
        }

        var (session, _) = await host.Connector.ConnectAsync(profile, password, cancellationToken, remember: false);
        await session.RefreshAsync(cancellationToken);
        return new CompareEndpoint(session, owned: true);
    }

    private async Task<string?> PromptPasswordAsync(ConnectionProfile profile)
    {
        var box = new PasswordBox { Header = Strings.Get("Compare/PasswordHeader"), MinWidth = 320 };
        box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = Strings.Format("Compare/PasswordPrompt", profile.Name), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(box);
        var result = await dialogs.ShowAsync(dialogs.Create(Strings.Get("Common/Connect"), panel, Strings.Get("Common/Connect"), Strings.Get("Common/Cancel")));
        return result == ContentDialogResult.Primary ? box.Password : null;
    }
}
