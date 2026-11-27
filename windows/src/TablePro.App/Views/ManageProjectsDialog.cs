using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// Rename, reorder and delete projects. Every change writes through the core and the list is read again.
internal sealed class ManageProjectsDialog
{
    private readonly Workbench _workbench;
    private readonly ContentDialog _dialog;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 280 };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBox _name = new();
    private readonly Button _rename = new();
    private readonly Button _up = new();
    private readonly Button _down = new();
    private readonly Button _delete = new();
    private readonly TextBlock _deleteTitle = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Flyout _confirm = new();
    private IReadOnlyList<ConnectionProject> _projects = [];
    private bool _busy;

    private ManageProjectsDialog(FrameworkElement owner, Workbench workbench)
    {
        _workbench = workbench;
        AutomationProperties.SetAutomationId(_list, "ManageProjectsList");
        AutomationProperties.SetName(_list, Strings.Get("ManageProjectsList"));
        _list.SelectionChanged += (_, _) => ShowSelection();
        _empty.Text = Strings.Get("ManageProjectsEmpty");
        _empty.Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"];
        _name.Header = Strings.Get("GroupNameHeader");
        AutomationProperties.SetAutomationId(_name, "ManageProjectsNameBox");
        _name.TextChanged += (_, _) =>
        {
            _name.Description = null;
            ShowCommands();
        };
        _name.KeyDown += async (_, args) =>
        {
            if (args.Key == VirtualKey.Enter && _rename.IsEnabled)
            {
                args.Handled = true;
                await RenameAsync().ConfigureAwait(true);
            }
        };
        Command(_rename, "RenameButton", "ManageProjectsRename", RenameAsync);
        Command(_up, "ManageProjectsMoveUp", "ManageProjectsMoveUp", () => StepAsync(up: true));
        Command(_down, "ManageProjectsMoveDown", "ManageProjectsMoveDown", () => StepAsync(up: false));
        _delete.Content = Strings.Get("DeleteButton");
        AutomationProperties.SetAutomationId(_delete, "ManageProjectsDelete");
        _delete.Flyout = _confirm;
        var confirmed = new Button { Content = Strings.Get("DeleteButton"), HorizontalAlignment = HorizontalAlignment.Right };
        AutomationProperties.SetAutomationId(confirmed, "ManageProjectsConfirmDelete");
        confirmed.Click += async (_, _) =>
        {
            _confirm.Hide();
            await DeleteAsync().ConfigureAwait(true);
        };
        _deleteTitle.Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"];
        // Asked beside the button: one ContentDialog is open already, and WinUI opens no second.
        _confirm.Content = new StackPanel
        {
            MaxWidth = 320,
            Spacing = 8,
            Children =
            {
                _deleteTitle,
                new TextBlock { Text = Strings.Get("DeleteProjectMessage"), TextWrapping = TextWrapping.Wrap },
                confirmed,
            },
        };
        _dialog = new ContentDialog
        {
            XamlRoot = owner.XamlRoot,
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Get("ManageProjectsTitle"),
            CloseButtonText = Strings.Get("Close"),
            DefaultButton = ContentDialogButton.Close,
            Content = new StackPanel
            {
                Width = 420,
                Spacing = 12,
                Children =
                {
                    _empty,
                    _list,
                    _name,
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 8,
                        Children = { _rename, _up, _down, _delete },
                    },
                },
            },
        };
    }

    public static async Task RunAsync(FrameworkElement owner, Workbench workbench)
    {
        var manage = new ManageProjectsDialog(owner, workbench);
        await manage.ReloadAsync(null).ConfigureAwait(true);
        await WindowDialogs.ShowAsync(manage._dialog, owner).ConfigureAwait(true);
    }

    private ConnectionProject? Selected => (_list.SelectedItem as ListViewItem)?.Tag as ConnectionProject;

    private static void Command(Button button, string text, string automationId, Func<Task> run)
    {
        button.Content = Strings.Get(text);
        AutomationProperties.SetAutomationId(button, automationId);
        button.Click += async (_, _) => await run().ConfigureAwait(true);
    }

    private async Task ReloadAsync(Guid? select)
    {
        try
        {
            _projects = (await _workbench.Library.GetSnapshotAsync().ConfigureAwait(true)).Projects;
        }
        catch (TableProException exception)
        {
            _name.Description = Strings.Error(exception.Error);
        }

        _list.Items.Clear();
        foreach (var project in _projects)
        {
            var row = new ListViewItem { Content = project.Name, Tag = project };
            _list.Items.Add(row);
            if (project.Id == select)
            {
                _list.SelectedItem = row;
            }
        }

        if (_list.SelectedItem is null && _list.Items.Count > 0)
        {
            _list.SelectedIndex = 0;
        }

        _empty.Visibility = _projects.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _list.Visibility = _projects.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        ShowSelection();
    }

    private void ShowSelection()
    {
        _name.Text = Selected?.Name ?? string.Empty;
        _name.Description = null;
        if (Selected is { } project)
        {
            _deleteTitle.Text = Strings.Format("DeleteProjectTitle", project.Name);
        }

        ShowCommands();
    }

    private void ShowCommands()
    {
        var project = Selected;
        var free = !_busy && project is not null;
        _name.IsEnabled = free;
        _rename.IsEnabled = free && _name.Text.Trim().Length > 0
            && !string.Equals(_name.Text.Trim(), project!.Name, StringComparison.Ordinal);
        _up.IsEnabled = free && LibraryScope.TryStep(_projects, project!.Id, up: true, out _);
        _down.IsEnabled = free && LibraryScope.TryStep(_projects, project!.Id, up: false, out _);
        _delete.IsEnabled = free;
    }

    private Task RenameAsync() =>
        Selected is { } project
            ? ChangeAsync(project.Id, () => _workbench.Library.RenameProjectAsync(project.Id, _name.Text))
            : Task.CompletedTask;

    private Task StepAsync(bool up) =>
        Selected is { } project && LibraryScope.TryStep(_projects, project.Id, up, out var before)
            ? ChangeAsync(project.Id, () => _workbench.Library.MoveProjectsAsync([project.Id], before))
            : Task.CompletedTask;

    private Task DeleteAsync() =>
        Selected is { } project
            ? ChangeAsync(null, () => _workbench.Library.DeleteProjectAsync(project.Id))
            : Task.CompletedTask;

    // A refusal, as a name another project has, shows under the name box and leaves the list as it was.
    private async Task ChangeAsync(Guid? select, Func<Task> change)
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        ShowCommands();
        try
        {
            await change().ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            _busy = false;
            _name.Description = Strings.Error(exception.Error);
            ShowCommands();
            return;
        }

        _busy = false;
        await ReloadAsync(select).ConfigureAwait(true);
        _workbench.NotifyLibraryChanged();
    }
}
