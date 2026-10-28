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
        };
        Grid.CellContextRequested += (_, e) =>
        {
            var menu = new MenuFlyout();
            GridCommands.AddCopyItems(menu, Grid, viewModel.Context.Session.Dialect, null);
            if (viewModel.Section == ServerSection.Activity && viewModel.SupportsActivity)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                menu.Items.Add(GridCommands.Item("Terminate Session", "", async () => await viewModel.TerminateAsync(e.Row)));
            }

            menu.ShowAt(e.Target, e.Position);
        };
        Loaded += async (_, _) =>
        {
            if (viewModel.Grid is null)
            {
                await viewModel.RefreshAsync();
            }
        };
    }

    public ServerTabViewModel ViewModel { get; }

    private void OnSectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (Enum.TryParse<ServerSection>(sender.SelectedItem?.Tag as string, out var section))
        {
            ViewModel.Section = section;
        }
    }
}
