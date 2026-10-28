using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.App.ViewModels;
using Windows.System;

namespace TablePro.App.Views;

public sealed partial class SearchTabView : UserControl
{
    public SearchTabView(SearchTabViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        Loaded += (_, _) => QueryBox.Focus(FocusState.Programmatic);
    }

    /// <summary>A hit asks the workspace to open its table filtered to the searched text.</summary>
    public event EventHandler<SearchHit>? HitOpened;

    public SearchTabViewModel ViewModel { get; }

    private async void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            await ViewModel.SearchAsync();
        }
    }

    private void OnHitClicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is SearchHit hit)
        {
            HitOpened?.Invoke(this, hit);
        }
    }
}
