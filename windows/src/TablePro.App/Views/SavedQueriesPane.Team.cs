using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// The pane's Team Library section (docs/decisions/0031-team-library-and-team-keys.md): each team's queries, read only,
// opened in a new query tab, and the publish of every saved query on this computer to a team the account writes to.
// Team connections are not read here yet, so a team's queries open in this connection's tab.
public sealed partial class SavedQueriesPane
{
    private TeamPublishOutcome? _outcome;
    private string? _teamFailure;

    // Which teams the person folded, kept across each read.
    private readonly HashSet<string> _foldedTeams = new(StringComparer.Ordinal);

    private void FollowTeamLibrary()
    {
        if (_workbench is not { } workbench)
        {
            return;
        }

        Loaded += (_, _) =>
        {
            workbench.TeamLibraryChanged -= OnTeamLibraryChanged;
            workbench.TeamLibraryChanged += OnTeamLibraryChanged;
            ShowTeams();
            workbench.RefreshTeamLibrary();
        };
        Unloaded += (_, _) => workbench.TeamLibraryChanged -= OnTeamLibraryChanged;
        // A publish's outcome stays until closed; the bar below it then shows what still waits.
        TeamBar.Closed += (_, args) =>
        {
            if (args.Reason == InfoBarCloseReason.CloseButton)
            {
                _outcome = null;
                _teamFailure = null;
                ShowTeams();
            }
        };
    }

    private void OnTeamLibraryChanged(object? sender, EventArgs e) => ShowTeams();

    private void ShowTeams()
    {
        if (_workbench is not { } workbench || !workbench.TeamLibraryAvailable)
        {
            TeamSection.Visibility = Visibility.Collapsed;
            return;
        }

        var library = workbench.TeamLibrary;
        TeamSection.Visibility = library.Teams.Count > 0 || library.LoadFailure is not null
            ? Visibility.Visible
            : Visibility.Collapsed;
        PublishButton.Visibility = library.WritableTeams.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        PublishButton.IsEnabled = _store is not null && !library.IsPublishing;
        ShowTeamBar(library);
        TeamsHost.Children.Clear();
        foreach (var team in library.Teams)
        {
            TeamsHost.Children.Add(TeamExpander(team));
        }
    }

    // What the last publish met first, then what waits on the person: conflicts, edits not uploaded, a failed read.
    private void ShowTeamBar(TeamLibraryModel library)
    {
        (string Message, InfoBarSeverity Severity, Button? Action)? bar = null;
        if (library.IsPublishing)
        {
            bar = (Strings.Get("TeamPublishing"), InfoBarSeverity.Informational, null);
        }
        else if (_teamFailure is { } failure)
        {
            bar = (failure, InfoBarSeverity.Error, null);
        }
        else if (_outcome is { } outcome)
        {
            bar = (TeamText.Outcome(outcome), Severity(outcome), outcome is TeamPublishOutcome.Conflicts ? ResolveButton() : null);
        }
        else if (library.Conflicts.Count > 0)
        {
            bar = (Strings.Plural("TeamConflictsWaiting", library.Conflicts.Count, library.Conflicts.Count),
                InfoBarSeverity.Warning,
                ResolveButton());
        }
        else if (library.ConflictFailure is { } conflict)
        {
            bar = (Strings.Error(conflict.Error), InfoBarSeverity.Error, null);
        }
        else if (library.Unsent.Count > 0)
        {
            bar = (Strings.Sentences(
                    Strings.Plural("TeamUnsentNotice", library.Unsent.Count, library.Unsent.Count),
                    Strings.List(library.Unsent.Select(TeamText.Unsent))),
                InfoBarSeverity.Informational,
                TeamButton("TeamDiscardUnsent", "TeamDiscardEllipsis", DiscardAsync));
        }
        else if (library.LoadFailure is { } load)
        {
            bar = (Strings.Format("TeamLibraryReadFailedMessage", Strings.Error(load)), InfoBarSeverity.Error, null);
        }

        if (bar is not { } shown)
        {
            TeamBar.IsOpen = false;
            TeamBar.Visibility = Visibility.Collapsed;
            return;
        }

        TeamBar.Visibility = Visibility.Visible;
        TeamBar.IsClosable = !library.IsPublishing && (_teamFailure is not null || _outcome is not null);
        TeamBar.Severity = shown.Severity;
        TeamBar.ActionButton = shown.Action;
        if (TeamBar.IsOpen && TeamBar.Message == shown.Message)
        {
            return;
        }

        TeamBar.Message = shown.Message;
        // Narrator reads an InfoBar when it opens, not when its text changes.
        TeamBar.IsOpen = false;
        TeamBar.IsOpen = true;
    }

    private static InfoBarSeverity Severity(TeamPublishOutcome outcome) => outcome switch
    {
        TeamPublishOutcome.Published or TeamPublishOutcome.Unchanged => InfoBarSeverity.Success,
        TeamPublishOutcome.Conflicts or TeamPublishOutcome.Queued => InfoBarSeverity.Warning,
        _ => InfoBarSeverity.Error,
    };

    private Button ResolveButton() => TeamButton("TeamResolveConflicts", "TeamResolveButton", ResolveAsync);

    private static Button TeamButton(string automationId, string text, Func<Task> run)
    {
        var button = new Button { Content = Strings.Get(text) };
        AutomationProperties.SetAutomationId(button, automationId);
        button.Click += async (_, _) => await run().ConfigureAwait(true);
        return button;
    }

    private Expander TeamExpander(TeamView team)
    {
        var name = TeamText.Team(team.Name);
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single };
        AutomationProperties.SetAutomationId(list, "TeamQueries");
        AutomationProperties.SetName(list, Strings.Format("TeamQueriesName", name));
        foreach (var query in team.Queries)
        {
            list.Items.Add(QueryRow(team, query));
        }

        list.DoubleTapped += (_, e) =>
        {
            if (list.SelectedItem is ListViewItem { Tag: TeamQuery query })
            {
                e.Handled = true;
                OpenRequested?.Invoke(this, query.Sql);
            }
        };
        list.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter && list.SelectedItem is ListViewItem { Tag: TeamQuery query })
            {
                e.Handled = true;
                OpenRequested?.Invoke(this, query.Sql);
            }
        };
        var content = new StackPanel();
        if (team.Queries.Count == 0)
        {
            content.Children.Add(new TextBlock
            {
                Text = Strings.Get("TeamNoQueries"),
                Margin = new Thickness(12, 4, 12, 4),
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            });
        }
        else
        {
            content.Children.Add(list);
        }

        var expander = new Expander
        {
            Header = name,
            Content = content,
            IsExpanded = !_foldedTeams.Contains(team.TeamId),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(8, 0, 8, 0),
        };
        AutomationProperties.SetAutomationId(expander, "TeamLibraryTeam");
        var id = team.TeamId;
        expander.Expanding += (_, _) => _foldedTeams.Remove(id);
        expander.Collapsed += (_, _) => _foldedTeams.Add(id);
        return expander;
    }

    private ListViewItem QueryRow(TeamView team, TeamQuery query)
    {
        var folder = query.FolderId is { } id ? team.Folders.FirstOrDefault(each => each.Id == id)?.Name : null;
        var detail = Strings.List(new[] { folder, TeamText.Changed(query.UpdatedBy, query.UpdatedAt) }
            .Where(part => !string.IsNullOrEmpty(part))
            .OfType<string>());
        var row = new StackPanel { Padding = new Thickness(0, 4, 0, 4), Spacing = 2 };
        row.Children.Add(new TextBlock
        {
            Text = query.Name,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
        });
        if (detail.Length > 0)
        {
            row.Children.Add(new TextBlock
            {
                Text = detail,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
            });
        }

        var item = new ListViewItem { Content = row, Tag = query };
        AutomationProperties.SetName(item, detail.Length == 0 ? query.Name : string.Concat(query.Name, ", ", detail));
        item.ContextRequested += (sender, args) =>
        {
            args.Handled = true;
            var menu = TeamQueryMenu(query);
            if (args.TryGetPosition(sender, out var point))
            {
                menu.ShowAt(sender, new FlyoutShowOptions { Position = point });
            }
            else
            {
                menu.ShowAt((FrameworkElement)sender);
            }
        };
        return item;
    }

    // Read only: a team query is opened or copied here, and changed by publishing again.
    private MenuFlyout TeamQueryMenu(TeamQuery query)
    {
        var open = MenuItem("SavedQueryMenuOpen", Symbol.Add);
        open.Click += (_, _) => OpenRequested?.Invoke(this, query.Sql);
        var copy = MenuItem("SavedQueryMenuCopy", Symbol.Copy);
        copy.Click += (_, _) => WorkspaceView.CopyText(query.Sql);
        var menu = new MenuFlyout();
        menu.Items.Add(open);
        menu.Items.Add(copy);
        return menu;
    }

    private async void OnPublishToTeam(object sender, RoutedEventArgs e) => await PublishAsync().ConfigureAwait(true);

    // Every saved query and folder on this computer, of every connection, goes to the team picked.
    private async Task PublishAsync()
    {
        if (_store is not { } store || _workbench is not { } workbench || workbench.TeamLibrary.IsPublishing)
        {
            return;
        }

        _teamFailure = null;
        _outcome = null;
        SavedQueryContents contents;
        try
        {
            contents = await store.GetAllAsync().ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            _teamFailure = Strings.Error(exception.Error);
            ShowTeams();
            return;
        }

        if (await TeamDialogs.ConfirmPublishAsync(this, workbench, contents.Queries.Count).ConfigureAwait(true)
            is not { } destination)
        {
            ShowTeams();
            return;
        }

        var (folders, queries) = TeamItems.Edits(contents);
        _outcome = await workbench.TeamLibrary.PublishSavedQueriesAsync(destination, folders, queries).ConfigureAwait(true);
        if (_outcome is TeamPublishOutcome.Failed failed)
        {
            CrashLog.Note("team publish", failed.Code);
        }

        ShowTeams();
        if (_outcome is TeamPublishOutcome.Conflicts)
        {
            await ResolveAsync().ConfigureAwait(true);
        }
    }

    private async Task ResolveAsync()
    {
        if (_workbench is not { } workbench)
        {
            return;
        }

        _outcome = null;
        await TeamDialogs.ResolveConflictsAsync(this, workbench).ConfigureAwait(true);
        ShowTeams();
    }

    private async Task DiscardAsync()
    {
        if (_workbench is not { } workbench)
        {
            return;
        }

        _outcome = null;
        _teamFailure = await TeamDialogs.DiscardUnsentAsync(this, workbench).ConfigureAwait(true) is { } failure
            ? Strings.Error(failure)
            : null;
        ShowTeams();
    }
}
