using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Helpers;
using TablePro.App.ViewModels;

namespace TablePro.App.Views;

public sealed partial class ServerTabView : UserControl
{
    public ServerTabView(ServerTabViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        viewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ServerTabViewModel.Grid))
            {
                Grid.Source = viewModel.Grid;
            }
            else if (e.PropertyName == nameof(ServerTabViewModel.ShowsUsersEditor))
            {
                ShowUsersEditor();
            }
        };
        Grid.CellContextRequested += (_, e) =>
        {
            var menu = new MenuFlyout();
            GridCommands.AddCopyItems(menu, Grid, viewModel.Context.Session.Dialect, null);
            if (viewModel.Section == ServerSection.Activity && viewModel.SupportsActivity)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                menu.Items.Add(GridCommands.Item(Strings.Get("Server/TerminateSession"),"", async () => await viewModel.TerminateAsync(e.Row)));
            }

            menu.ShowAt(e.Target, e.Position);
        };
        Loaded += async (_, _) =>
        {
            ShowUsersEditor();
            if (viewModel.Grid is null && !viewModel.ShowsUsersEditor)
            {
                await viewModel.RefreshAsync();
            }
        };
    }

    public ServerTabViewModel ViewModel { get; }

    /// <summary>
    /// Swaps the read-only grid for the Users and Roles editor where the engine has one. The view is made once per editor,
    /// which a database switch replaces.
    /// </summary>
    private void ShowUsersEditor()
    {
        var editor = ViewModel.ShowsUsersEditor ? ViewModel.UsersRoles : null;
        if (editor is not null && (UsersHost.Content as UsersRolesView)?.ViewModel != editor)
        {
            UsersHost.Content = new UsersRolesView(editor, ViewModel.Context.Dialogs);
        }

        UsersHost.Visibility = editor is null ? Visibility.Collapsed : Visibility.Visible;
        Grid.Visibility = AutoRefreshSwitch.Visibility = editor is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnSectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (Enum.TryParse<ServerSection>(sender.SelectedItem?.Tag as string, out var section))
        {
            ViewModel.Section = section;
        }
    }
}
