using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Editor.Model;
using TablePro.Interop;

namespace TablePro.App.Views;

// Where a saved query landed, so the pane can open its folder.
internal sealed record SavedQueryPlace(long Id, long? FolderId);

// A saved query's name, folder and, when editing, its text, asked in a dialog; the core keeps them.
internal static class SaveQueryDialog
{
    // Null when cancelled, or when another dialog holds the window.
    public static async Task<SavedQueryPlace?> SaveAsync(
        FrameworkElement owner,
        SavedQueries store,
        Guid connectionId,
        string connectionName,
        string sql)
    {
        ArgumentNullException.ThrowIfNull(store);
        var draft = new Draft(null, SavedQueryText.AutoName(sql, Strings.Get("SavedQueryUntitled")), sql, null);
        var folders = await FoldersAsync(store, connectionId).ConfigureAwait(true);
        while (true)
        {
            var answer = await ShowAsync(
                    owner,
                    Strings.Get("SaveQueryTitle"),
                    draft,
                    folders,
                    editsSql: false,
                    () => CommitAsync(store, connectionId, connectionName, draft, replace: false))
                .ConfigureAwait(true);
            if (answer == Answer.Saved)
            {
                return draft.Place;
            }

            if (answer == Answer.Cancelled)
            {
                return null;
            }

            // WinUI shows one dialog at a time, so the question comes once the first has closed; Cancel goes back to it.
            if (!await ConfirmReplaceAsync(owner, draft.Name).ConfigureAwait(true))
            {
                continue;
            }

            try
            {
                if (await CommitAsync(store, connectionId, connectionName, draft, replace: true).ConfigureAwait(true))
                {
                    return draft.Place;
                }
            }
            catch (TableProException exception)
            {
                draft.Error = Strings.Error(exception.Error);
            }
        }
    }

    // Writes only what changed, each by the query's id: the name, the text, then the folder.
    public static async Task<SavedQueryPlace?> EditAsync(
        FrameworkElement owner,
        SavedQueries store,
        Guid connectionId,
        string connectionName,
        SavedQuery query)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(query);
        var draft = new Draft(query.Id, query.Name, query.Sql, query.FolderId);
        var folders = await FoldersAsync(store, connectionId).ConfigureAwait(true);
        var answer = await ShowAsync(
                owner,
                Strings.Get("EditSavedQueryTitle"),
                draft,
                folders,
                editsSql: true,
                () => CommitAsync(store, connectionId, connectionName, draft, replace: true))
            .ConfigureAwait(true);
        return answer == Answer.Saved ? draft.Place : null;
    }

    // A refusal from apply shows under the box and keeps the dialog open.
    public static async Task<bool> AskNameAsync(
        FrameworkElement owner,
        string title,
        string name,
        string action,
        Func<string, Task> apply)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(apply);
        var box = NameBox(name, "NameDialogBox");
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = title,
            Content = box,
            PrimaryButtonText = action,
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name),
        };
        box.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(box.Text);
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                await apply(box.Text.Trim()).ConfigureAwait(true);
            }
            catch (TableProException exception)
            {
                args.Cancel = true;
                box.Description = Strings.Error(exception.Error);
            }
            finally
            {
                deferral.Complete();
            }
        };
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    // Enter cancels, as every question that removes something does.
    public static async Task<bool> ConfirmDeleteAsync(FrameworkElement owner, string title, string message)
    {
        ArgumentNullException.ThrowIfNull(owner);
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = Strings.Get("DeleteButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    // False when another query has the name and replace is false; nothing is written then.
    private static async Task<bool> CommitAsync(
        SavedQueries store,
        Guid connectionId,
        string connectionName,
        Draft draft,
        bool replace)
    {
        if (draft.Id is not { } id)
        {
            if (await store.SaveAsync(connectionId, connectionName, draft.Name, draft.Sql, replace).ConfigureAwait(true)
                is not { } added)
            {
                return false;
            }

            // A failed move after this leaves the query saved, so a second try only moves it.
            draft.Id = id = added;
            draft.StoredName = draft.Name;
            draft.StoredSql = draft.Sql;
            if (replace)
            {
                // A replaced query keeps its place unless another folder was picked.
                var held = (await store.GetAsync(connectionId).ConfigureAwait(true)).Queries
                    .FirstOrDefault(query => query.Id == added);
                draft.StoredFolder = held?.FolderId;
                if (!draft.FolderChosen)
                {
                    draft.FolderId = draft.StoredFolder;
                }
            }
        }
        else
        {
            if (!string.Equals(draft.Name, draft.StoredName, StringComparison.Ordinal))
            {
                await store.RenameAsync(id, draft.Name).ConfigureAwait(true);
                draft.StoredName = draft.Name;
            }

            if (!string.Equals(draft.Sql, draft.StoredSql, StringComparison.Ordinal))
            {
                await store.SetSqlAsync(id, draft.Sql).ConfigureAwait(true);
                draft.StoredSql = draft.Sql;
            }
        }

        if (draft.FolderId != draft.StoredFolder)
        {
            await store.MoveAsync(id, draft.FolderId).ConfigureAwait(true);
            draft.StoredFolder = draft.FolderId;
        }

        return true;
    }

    private static async Task<Answer> ShowAsync(
        FrameworkElement owner,
        string title,
        Draft draft,
        IReadOnlyList<SavedQueryFolderChoice> folders,
        bool editsSql,
        Func<Task<bool>> commit)
    {
        var content = new StackPanel { Spacing = 12, MinWidth = 360 };
        var error = new InfoBar
        {
            Severity = InfoBarSeverity.Error,
            IsClosable = false,
            IsOpen = draft.Error is not null,
            Message = draft.Error ?? string.Empty,
            Visibility = draft.Error is null ? Visibility.Collapsed : Visibility.Visible,
        };
        AutomationProperties.SetAutomationId(error, "SaveQueryError");
        content.Children.Add(error);

        var name = NameBox(draft.Name, "SavedQueryNameBox");
        content.Children.Add(name);

        // Only a connection with folders is asked where the query goes.
        ComboBox? folder = null;
        if (folders.Count > 0)
        {
            folder = FolderBox(folders, draft.FolderId);
            folder.SelectionChanged += (_, _) => draft.FolderChosen = true;
            content.Children.Add(folder);
        }

        TextBox? sql = null;
        if (editsSql)
        {
            sql = new TextBox
            {
                Header = Strings.Get("SavedQuerySqlHeader"),
                Text = draft.Sql,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.NoWrap,
                IsSpellCheckEnabled = false,
                FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
                Height = 200,
            };
            ScrollViewer.SetHorizontalScrollBarVisibility(sql, ScrollBarVisibility.Auto);
            ScrollViewer.SetVerticalScrollBarVisibility(sql, ScrollBarVisibility.Auto);
            AutomationProperties.SetAutomationId(sql, "SavedQuerySqlBox");
            AutomationProperties.SetName(sql, Strings.Get("SavedQuerySqlHeader"));
            content.Children.Add(sql);
        }

        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = title,
            Content = content,
            PrimaryButtonText = Strings.Get("SaveQueryAction"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        void Validate() => dialog.IsPrimaryButtonEnabled =
            !string.IsNullOrWhiteSpace(name.Text) && (sql is null || !string.IsNullOrWhiteSpace(sql.Text));
        name.TextChanged += (_, _) => Validate();
        if (sql is not null)
        {
            sql.TextChanged += (_, _) => Validate();
        }

        Validate();
        var taken = false;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            draft.Name = name.Text.Trim();
            if (folder is not null)
            {
                draft.FolderId = (folder.SelectedItem as ComboBoxItem)?.Tag as long?;
            }

            if (sql is not null)
            {
                // A TextBox keeps its line breaks as CR.
                draft.Sql = TextDocument.Normalize(sql.Text).Trim();
            }

            try
            {
                taken = !await commit().ConfigureAwait(true);
                draft.Error = null;
            }
            catch (TableProException exception)
            {
                args.Cancel = true;
                draft.Error = Strings.Error(exception.Error);
                error.Message = draft.Error;
                error.Visibility = Visibility.Visible;
                // Narrator reads an InfoBar when it opens, not when its text changes.
                error.IsOpen = false;
                error.IsOpen = true;
            }
            finally
            {
                deferral.Complete();
            }
        };
        var result = await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
        if (result != ContentDialogResult.Primary)
        {
            return Answer.Cancelled;
        }

        return taken ? Answer.Taken : Answer.Saved;
    }

    private static TextBox NameBox(string name, string automationId)
    {
        var box = new TextBox
        {
            Header = Strings.Get("SavedQueryNameHeader"),
            Text = name,
            SelectionStart = 0,
            SelectionLength = name.Length,
        };
        AutomationProperties.SetAutomationId(box, automationId);
        AutomationProperties.SetName(box, Strings.Get("SavedQueryNameHeader"));
        return box;
    }

    // Each folder by its path, indented under the one above it.
    private static ComboBox FolderBox(IReadOnlyList<SavedQueryFolderChoice> folders, long? selected)
    {
        var box = new ComboBox { Header = Strings.Get("SavedQueryFolderHeader"), HorizontalAlignment = HorizontalAlignment.Stretch };
        box.Items.Add(new ComboBoxItem { Content = Strings.Get("SavedQueryNoFolder") });
        box.SelectedIndex = 0;
        foreach (var choice in folders)
        {
            var item = new ComboBoxItem
            {
                Content = choice.Path,
                Tag = choice.Id,
                Padding = new Thickness(11 + (choice.Depth * 16), 5, 11, 7),
            };
            AutomationProperties.SetName(item, choice.Path);
            box.Items.Add(item);
            if (choice.Id == selected)
            {
                box.SelectedItem = item;
            }
        }

        AutomationProperties.SetAutomationId(box, "SavedQueryFolderBox");
        AutomationProperties.SetName(box, Strings.Get("SavedQueryFolderHeader"));
        return box;
    }

    // A list that cannot be read leaves the picker out; the save itself still says what went wrong.
    private static async Task<IReadOnlyList<SavedQueryFolderChoice>> FoldersAsync(SavedQueries store, Guid connectionId)
    {
        try
        {
            return SavedQueryTree.Folders(await store.GetAsync(connectionId).ConfigureAwait(true));
        }
        catch (TableProException)
        {
            return [];
        }
    }

    private static async Task<bool> ConfirmReplaceAsync(FrameworkElement owner, string name)
    {
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Content = new TextBlock
            {
                Text = Strings.Format("ReplaceSavedQueryMessage", name),
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = Strings.Get("ReplaceButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    private enum Answer
    {
        Cancelled,
        Saved,
        Taken,
    }

    // What the dialog shows again after the replace question, and what the store holds so far.
    private sealed class Draft(long? id, string name, string sql, long? folderId)
    {
        public long? Id { get; set; } = id;

        public string Name { get; set; } = name;

        public string Sql { get; set; } = sql;

        public long? FolderId { get; set; } = folderId;

        // No folder is also the box's start, so only a pick tells a move to the top level from no choice.
        public bool FolderChosen { get; set; }

        public string StoredName { get; set; } = name;

        public string StoredSql { get; set; } = sql;

        // A new query starts at the top level, so it moves only when a folder was picked.
        public long? StoredFolder { get; set; } = id is null ? null : folderId;

        public string? Error { get; set; }

        public SavedQueryPlace? Place => Id is { } saved ? new SavedQueryPlace(saved, FolderId) : null;
    }
}
