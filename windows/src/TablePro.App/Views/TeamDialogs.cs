using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// Team Library's and the team keys' dialogs (docs/decisions/0031-team-library-and-team-keys.md), one ContentDialog
// each, as the macOS app's team sheets ask. Each closes once another sign-in holds the account.
internal static class TeamDialogs
{
    private static readonly FontFamily Monospace = new("Cascadia Mono, Consolas, Courier New");

    // The team picked, under the sign-in shown when the dialog opened; null when the person cancelled.
    public static async Task<TeamDestination?> ConfirmPublishAsync(
        FrameworkElement owner,
        Workbench workbench,
        int queries)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        var library = workbench.TeamLibrary;
        var teams = library.WritableTeams;
        if (teams.Count == 0)
        {
            return null;
        }

        // Taken before the dialog waits: a publish under another sign-in never goes.
        var destinations = teams.Select(team => library.Destination(team.TeamId)).ToList();
        var dialog = KeyDialogs.Dialog(owner, "TeamPublishDialog");
        dialog.Title = Strings.Get("TeamPublishTitle");
        dialog.PrimaryButtonText = Strings.Get("TeamPublishButton");
        dialog.CloseButtonText = Strings.Get("Cancel");
        var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
        var message = KeyDialogs.Paragraph(string.Empty);
        var picker = new ComboBox { Header = Strings.Get("TeamPublishTeam"), HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(picker, "TeamPublishTeam");
        foreach (var team in teams)
        {
            picker.Items.Add(TeamText.Team(team.Name));
        }

        void Describe() => message.Text = Strings.Plural(
            "TeamPublishMessage",
            queries,
            queries,
            TeamText.Team(teams[Math.Max(0, picker.SelectedIndex)].Name));
        picker.SelectedIndex = 0;
        picker.SelectionChanged += (_, _) => Describe();
        Describe();
        if (teams.Count > 1)
        {
            body.Children.Add(picker);
        }

        body.Children.Add(message);
        body.Children.Add(KeyDialogs.Paragraph(Strings.Get("TeamPublishExplain")));
        dialog.Content = body;
        using var guard = new KeyDialogs.SessionGuard(workbench, dialog);
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary
            ? destinations[Math.Max(0, picker.SelectedIndex)]
            : null;
    }

    // One conflict at a time until none is left or the person decides later; a choice a pull overtook shows the new
    // version with why.
    public static async Task ResolveConflictsAsync(FrameworkElement owner, Workbench workbench)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        var library = workbench.TeamLibrary;
        // A dialog already closing keeps its answer when the sign-in changes, so each answer is checked against it.
        var session = workbench.SignInSession;
        while (workbench.SignInSession == session && library.Conflicts.FirstOrDefault() is { } conflict)
        {
            var dialog = KeyDialogs.Dialog(owner, "TeamConflictDialog");
            dialog.Title = TeamText.ConflictTitle(conflict);
            dialog.PrimaryButtonText = Strings.Get("TeamKeepMine");
            dialog.SecondaryButtonText = Strings.Get("TeamKeepTheirs");
            dialog.CloseButtonText = Strings.Get("TeamDecideLater");
            dialog.DefaultButton = ContentDialogButton.Close;
            dialog.Content = ConflictBody(library, conflict);
            ContentDialogResult answer;
            using (new KeyDialogs.SessionGuard(workbench, dialog))
            {
                answer = await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
            }

            var keep = answer switch
            {
                ContentDialogResult.Primary => ConflictChoice.KeepMine,
                ContentDialogResult.Secondary => ConflictChoice.KeepTheirs,
                _ => (ConflictChoice?)null,
            };
            if (keep is not { } choice || workbench.SignInSession != session)
            {
                return;
            }

            await library.ResolveAsync(conflict, choice).ConfigureAwait(true);
            if (library.ConflictFailure is { } failure && failure.Record == conflict.Record
                && !library.Conflicts.Any(left => left.Record == conflict.Record))
            {
                // Refused, and no newer version to show: the bar in the pane says why.
                return;
            }
        }
    }

    private static ScrollViewer ConflictBody(TeamLibraryModel library, TeamConflict conflict)
    {
        var body = new StackPanel { Spacing = 12, MaxWidth = 560 };
        body.Children.Add(KeyDialogs.Paragraph(TeamText.ConflictMessage(conflict, library.TeamName(conflict.Record.Scope))));
        if (library.ConflictFailure is { } failure && failure.Record == conflict.Record)
        {
            KeyDialogs.AddFailure(body, failure.Error);
        }

        if (library.Writer(conflict.Record) is { Length: > 0 } writer)
        {
            body.Children.Add(Caption(Strings.Format("TeamChangedBy", writer)));
        }

        var fields = new Grid { ColumnSpacing = 16, RowSpacing = 8 };
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        AddRow(fields, 0, KeyDialogs.Heading(Strings.Get("TeamConflictField")),
            KeyDialogs.Heading(Strings.Get("TeamConflictMine")), KeyDialogs.Heading(Strings.Get("TeamConflictTheirs")));
        var row = 1;
        foreach (var field in conflict.Fields)
        {
            AddRow(
                fields,
                row++,
                new TextBlock { Text = TeamText.Field(field), TextWrapping = TextWrapping.Wrap },
                Value(conflict.Mine, field),
                Value(conflict.Theirs, field));
        }

        body.Children.Add(fields);
        if (library.Conflicts.Count > 1)
        {
            body.Children.Add(Caption(Strings.Plural("TeamConflictsLeft", library.Conflicts.Count - 1, library.Conflicts.Count - 1)));
        }

        return new ScrollViewer { Content = body, MaxHeight = 480, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private static void AddRow(Grid grid, int row, FrameworkElement field, FrameworkElement mine, FrameworkElement theirs)
    {
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        foreach (var (cell, column) in new[] { (field, 0), (mine, 1), (theirs, 2) })
        {
            Grid.SetRow(cell, row);
            Grid.SetColumn(cell, column);
            grid.Children.Add(cell);
        }
    }

    // A side that deleted the record holds no field.
    private static TextBlock Value(string? side, string field)
    {
        var text = side is null ? Strings.Get("TeamValueDeleted") : TeamText.Value(TeamConflicts.Value(side, field));
        var block = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 8,
            TextTrimming = TextTrimming.CharacterEllipsis,
            IsTextSelectionEnabled = true,
        };
        if (field == "query")
        {
            block.FontFamily = Monospace;
        }

        return block;
    }

    // Null when nothing went or the person kept them; else why the discard failed.
    public static async Task<CoreError?> DiscardUnsentAsync(FrameworkElement parent, Workbench workbench)
    {
        ArgumentNullException.ThrowIfNull(parent);
        ArgumentNullException.ThrowIfNull(workbench);
        var library = workbench.TeamLibrary;
        // Taken before the dialog waits: a dialog already closing keeps its answer when the sign-in changes.
        var session = workbench.SignInSession;
        if (library.Unsent.Count == 0 || library.Owner is not { } owner)
        {
            return null;
        }

        var dialog = KeyDialogs.Dialog(parent, "TeamDiscardDialog");
        dialog.Title = Strings.Get("TeamDiscardTitle");
        var body = new StackPanel { Spacing = 8, MaxWidth = 480 };
        body.Children.Add(KeyDialogs.Paragraph(Strings.Get("TeamDiscardMessage")));
        foreach (var edit in library.Unsent)
        {
            body.Children.Add(KeyDialogs.Paragraph(TeamText.Unsent(edit)));
        }

        dialog.Content = new ScrollViewer { Content = body, MaxHeight = 360 };
        dialog.PrimaryButtonText = Strings.Get("TeamDiscardButton");
        dialog.CloseButtonText = Strings.Get("Cancel");
        dialog.DefaultButton = ContentDialogButton.Close;
        using (new KeyDialogs.SessionGuard(workbench, dialog))
        {
            if (await WindowDialogs.ShowAsync(dialog, parent).ConfigureAwait(true) != ContentDialogResult.Primary
                || workbench.SignInSession != session)
            {
                return null;
            }
        }

        return await library.DiscardAsync(null, owner).ConfigureAwait(true);
    }

    // Sign out's question while Team Library edits are not uploaded (the macOS app's AccountSignOutPrompt).
    public static async Task<TeamSignOutAnswer> SignOutUnsentAsync(FrameworkElement owner, TeamSignOutQuestion question)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(question);
        var dialog = KeyDialogs.Dialog(owner, "TeamSignOutDialog");
        dialog.Title = Strings.Get("TeamSignOutTitle");
        dialog.Content = KeyDialogs.Paragraph(Strings.Sentences(
            question.UploadFailure is { } code ? Strings.Format("TeamSignOutUploadFailed", SyncText.Code(code)) : null,
            question.Names is { } names
                ? Strings.Format("TeamSignOutUnsent", Strings.ListAnd(names))
                : Strings.Get("TeamSignOutUnlisted")));
        dialog.PrimaryButtonText = Strings.Get("TeamSignOutUpload");
        dialog.SecondaryButtonText = Strings.Get("TeamSignOutDiscard");
        dialog.CloseButtonText = Strings.Get("Cancel");
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) switch
        {
            ContentDialogResult.Primary => TeamSignOutAnswer.Upload,
            ContentDialogResult.Secondary => TeamSignOutAnswer.Discard,
            _ => TeamSignOutAnswer.Cancel,
        };
    }

    // This account's words, which an owner or admin compares to confirm it.
    public static async Task OwnWordsAsync(FrameworkElement owner, Workbench workbench)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        var dialog = KeyDialogs.Dialog(owner, "TeamOwnWordsDialog");
        dialog.Title = Strings.Get("TeamOwnWordsTitle");
        dialog.CloseButtonText = Strings.Get("TeamDone");
        dialog.DefaultButton = ContentDialogButton.Close;
        var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
        body.Children.Add(KeyDialogs.Paragraph(Strings.Get("TeamOwnWordsMessage")));
        var words = new StackPanel();
        words.Children.Add(KeyDialogs.Working(Strings.Get("TeamLoadingWords")));
        body.Children.Add(words);
        dialog.Content = body;
        using var guard = new KeyDialogs.SessionGuard(workbench, dialog);
        var shown = WindowDialogs.ShowAsync(dialog, owner);
        await ShowWordsAsync(words, async () => await (await guard.TeamAsync().ConfigureAwait(true))
            .GetOwnFingerprintAsync().ConfigureAwait(true)).ConfigureAwait(true);
        await shown.ConfigureAwait(true);
    }

    // Confirming wraps the team key to the member; only words that match theirs are confirmed.
    public static async Task ConfirmMemberAsync(
        FrameworkElement owner,
        Workbench workbench,
        TeamKeysModel model,
        MemberKeys member)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        ArgumentNullException.ThrowIfNull(model);
        ArgumentNullException.ThrowIfNull(member);
        var name = TeamText.MemberName(member);
        var dialog = KeyDialogs.Dialog(owner, "TeamConfirmMemberDialog");
        dialog.Title = Strings.Format("TeamConfirmTitle", name);
        dialog.PrimaryButtonText = Strings.Get("TeamConfirmButton");
        dialog.SecondaryButtonText = Strings.Get("TeamWordsDontMatch");
        dialog.CloseButtonText = Strings.Get("Cancel");
        dialog.IsPrimaryButtonEnabled = false;
        dialog.IsSecondaryButtonEnabled = false;
        var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
        body.Children.Add(KeyDialogs.Paragraph(Strings.Format("TeamConfirmMessage", name)));
        var words = new StackPanel();
        words.Children.Add(KeyDialogs.Working(Strings.Get("TeamLoadingWords")));
        body.Children.Add(words);
        dialog.Content = body;
        ContentDialogResult answer;
        using (var guard = new KeyDialogs.SessionGuard(workbench, dialog))
        {
            var shown = WindowDialogs.ShowAsync(dialog, owner);
            if (await ShowWordsAsync(words, async () => await (await guard.TeamAsync().ConfigureAwait(true))
                    .GetAccountFingerprintAsync(member.Account).ConfigureAwait(true)).ConfigureAwait(true))
            {
                dialog.IsPrimaryButtonEnabled = true;
                dialog.IsSecondaryButtonEnabled = true;
            }

            answer = await shown.ConfigureAwait(true);
        }

        switch (answer)
        {
            case ContentDialogResult.Primary:
                await model.ConfirmAsync(member).ConfigureAwait(true);
                break;
            case ContentDialogResult.Secondary:
                await MismatchAsync(owner, name).ConfigureAwait(true);
                break;
            default:
                break;
        }
    }

    private static async Task MismatchAsync(FrameworkElement owner, string name)
    {
        var dialog = KeyDialogs.Dialog(owner, "TeamMismatchDialog");
        dialog.Title = Strings.Format("TeamMismatchTitle", name);
        dialog.Content = KeyDialogs.Paragraph(Strings.Get("TeamMismatchMessage"));
        dialog.CloseButtonText = Strings.Get("TeamClose");
        dialog.DefaultButton = ContentDialogButton.Close;
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
    }

    // A member's new keys: this computer pins them once the words match, or without comparing when the person says so.
    public static async Task KeyChangeAsync(
        FrameworkElement owner,
        Workbench workbench,
        TeamKeysModel model,
        MemberKeys member)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        ArgumentNullException.ThrowIfNull(model);
        ArgumentNullException.ThrowIfNull(member);
        var name = TeamText.MemberName(member);
        var dialog = KeyDialogs.Dialog(owner, "TeamKeyChangeDialog");
        dialog.Title = Strings.Format("TeamKeyChangeTitle", name);
        dialog.CloseButtonText = Strings.Get("Cancel");
        var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
        body.Children.Add(KeyDialogs.Working(Strings.Get("TeamLoadingWords")));
        dialog.Content = body;
        KeyChange? change = null;
        ContentDialogResult answer;
        using (var guard = new KeyDialogs.SessionGuard(workbench, dialog))
        {
            var shown = WindowDialogs.ShowAsync(dialog, owner);
            try
            {
                change = await (await guard.TeamAsync().ConfigureAwait(true))
                    .GetKeyChangeAsync(member.Account).ConfigureAwait(true);
                body.Children.Clear();
                if (change is null)
                {
                    body.Children.Add(KeyDialogs.Paragraph(Strings.Get("TeamKeyChangeSettled")));
                    dialog.CloseButtonText = Strings.Get("TeamClose");
                }
                else
                {
                    body.Children.Add(KeyDialogs.Paragraph(Strings.Format("TeamKeyChangeMessage", name)));
                    body.Children.Add(KeyDialogs.Heading(Strings.Get("TeamNewWords")));
                    body.Children.Add(KeyDialogs.Words(change.Offered.Words));
                    body.Children.Add(KeyDialogs.Heading(Strings.Get("TeamPreviousWords")));
                    body.Children.Add(KeyDialogs.Words(change.Pinned.Words));
                    if (model.CanWrapCurrentVersion)
                    {
                        body.Children.Add(Caption(Strings.Get("TeamKeyChangeShares")));
                    }

                    dialog.PrimaryButtonText = Strings.Get("TeamWordsMatch");
                    dialog.SecondaryButtonText = Strings.Get("TeamAcceptWithoutComparing");
                }
            }
            catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
            {
                body.Children.Clear();
                KeyDialogs.AddFailure(body, error);
            }

            answer = await shown.ConfigureAwait(true);
        }

        if (change is null || answer is not (ContentDialogResult.Primary or ContentDialogResult.Secondary))
        {
            return;
        }

        await model.AcceptKeyChangeAsync(member, change.OfferedIdentityKey, answer == ContentDialogResult.Primary)
            .ConfigureAwait(true);
    }

    // A restart this computer holds (core ADR 0064): there is no accept without comparing the signer's words.
    public static async Task HeldRestartAsync(FrameworkElement owner, Workbench workbench, TeamKeysModel model)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        ArgumentNullException.ThrowIfNull(model);
        var dialog = KeyDialogs.Dialog(owner, "TeamHeldRestartDialog");
        dialog.Title = Strings.Get("TeamHeldRestartTitle");
        dialog.CloseButtonText = Strings.Get("TeamNotNow");
        var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
        body.Children.Add(KeyDialogs.Working(Strings.Get("TeamLoadingWords")));
        dialog.Content = body;
        HeldRestart? held = null;
        ContentDialogResult answer;
        using (var guard = new KeyDialogs.SessionGuard(workbench, dialog))
        {
            var shown = WindowDialogs.ShowAsync(dialog, owner);
            try
            {
                held = await (await guard.TeamAsync().ConfigureAwait(true))
                    .GetHeldTeamRestartAsync(model.Team.Id).ConfigureAwait(true);
                body.Children.Clear();
                if (held is null)
                {
                    body.Children.Add(KeyDialogs.Paragraph(Strings.Get("TeamHeldRestartGone")));
                    dialog.CloseButtonText = Strings.Get("TeamClose");
                }
                else
                {
                    var signer = model.Member(held.Signer);
                    if (signer is null)
                    {
                        body.Children.Add(new InfoBar
                        {
                            Severity = InfoBarSeverity.Warning,
                            Message = Strings.Get("TeamNotice_RestartHeldStranger"),
                            IsClosable = false,
                            IsOpen = true,
                        });
                    }
                    else
                    {
                        body.Children.Add(KeyDialogs.Paragraph(Strings.Format(
                            "TeamNotice_RestartHeld",
                            TeamText.MemberName(signer))));
                    }

                    body.Children.Add(KeyDialogs.Paragraph(Strings.Format(
                        "TeamHeldRestartMessage",
                        signer is null ? Strings.Get("TeamTheOwner") : TeamText.MemberName(signer),
                        TeamText.Team(model.Team.Name))));
                    body.Children.Add(KeyDialogs.Words(held.Words.Words));
                    dialog.PrimaryButtonText = Strings.Get("TeamWordsMatch");
                }
            }
            catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
            {
                body.Children.Clear();
                KeyDialogs.AddFailure(body, error);
            }

            answer = await shown.ConfigureAwait(true);
        }

        if (held is not null && answer == ContentDialogResult.Primary)
        {
            await model.AcceptRestartAsync(held.SignerIdentityKey).ConfigureAwait(true);
        }
    }

    // An owner starts the key over to the members whose words they compared; the rest are confirmed later.
    public static async Task RestartAsync(FrameworkElement owner, Workbench workbench, TeamKeysModel model)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        ArgumentNullException.ThrowIfNull(model);
        var dialog = KeyDialogs.Dialog(owner, "TeamRestartDialog");
        dialog.Title = Strings.Get("TeamRestartTitle");
        dialog.PrimaryButtonText = Strings.Get("TeamRestartButton");
        dialog.CloseButtonText = Strings.Get("Cancel");
        dialog.DefaultButton = ContentDialogButton.Close;
        var body = new StackPanel { Spacing = 12, MaxWidth = 520 };
        body.Children.Add(KeyDialogs.Paragraph(Strings.Format("TeamRestartMessage", TeamText.Team(model.Team.Name))));
        var candidates = model.RestartCandidates;
        var included = new HashSet<string>(StringComparer.Ordinal);
        var loads = new List<(MemberKeys Member, StackPanel Words, CheckBox Match)>();
        if (candidates.Count == 0)
        {
            body.Children.Add(KeyDialogs.Paragraph(Strings.Get("TeamRestartNoCandidates")));
        }
        else
        {
            body.Children.Add(KeyDialogs.Paragraph(Strings.Get("TeamRestartCompare")));
            foreach (var member in candidates)
            {
                var name = TeamText.MemberName(member);
                var row = new StackPanel { Spacing = 4 };
                row.Children.Add(KeyDialogs.Heading(name));
                row.Children.Add(Caption(TeamText.Role(member.Role)));
                var words = new StackPanel();
                words.Children.Add(KeyDialogs.Working(Strings.Get("TeamLoadingWords")));
                row.Children.Add(words);
                var match = new CheckBox { Content = Strings.Get("TeamWordsMatch"), IsEnabled = false };
                AutomationProperties.SetName(match, Strings.Format("TeamWordsMatchName", name));
                AutomationProperties.SetAutomationId(match, "TeamRestartMatch");
                var account = member.Account;
                match.Checked += (_, _) => included.Add(account);
                match.Unchecked += (_, _) => included.Remove(account);
                row.Children.Add(match);
                body.Children.Add(row);
                loads.Add((member, words, match));
            }
        }

        if (model.RestartWaitsForKeyChange is { Count: > 0 } waiting)
        {
            body.Children.Add(Caption(Strings.Format(
                "TeamRestartWaiting",
                Strings.ListAnd([.. waiting.Select(TeamText.MemberName)]))));
        }

        dialog.Content = new ScrollViewer { Content = body, MaxHeight = 480, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        ContentDialogResult answer;
        using (var guard = new KeyDialogs.SessionGuard(workbench, dialog))
        {
            var shown = WindowDialogs.ShowAsync(dialog, owner);
            foreach (var (member, words, match) in loads)
            {
                var account = member.Account;
                match.IsEnabled = await ShowWordsAsync(words, async () => await (await guard.TeamAsync().ConfigureAwait(true))
                    .GetAccountFingerprintAsync(account).ConfigureAwait(true)).ConfigureAwait(true);
            }

            answer = await shown.ConfigureAwait(true);
        }

        if (answer == ContentDialogResult.Primary)
        {
            await model.RestartAsync([.. included]).ConfigureAwait(true);
        }
    }

    // True once the words show; the failure in their place otherwise.
    private static async Task<bool> ShowWordsAsync(StackPanel host, Func<Task<KeyFingerprint>> read)
    {
        try
        {
            var fingerprint = await read().ConfigureAwait(true);
            host.Children.Clear();
            host.Children.Add(KeyDialogs.Words(fingerprint.Words));
            return true;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            host.Children.Clear();
            KeyDialogs.AddFailure(host, error);
            return false;
        }
    }

    private static TextBlock Caption(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };
}
