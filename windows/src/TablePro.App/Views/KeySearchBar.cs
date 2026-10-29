using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.App.ViewModels;
using TablePro.Core.Drivers;
using Windows.System;

namespace TablePro.App.Views;

/// <summary>
/// The search above a key-value database's list of keys, the macOS key pattern bar: a glob such as <c>user:*</c>
/// applied on Enter, a key type applied when picked, both matched on the server.
/// </summary>
internal sealed partial class KeySearchBar : Grid
{
    private readonly TableTabViewModel _viewModel;
    private readonly KeyBrowseInfo _browse;
    private readonly TextBox _pattern = new() { PlaceholderText = Strings.Get("Table/KeyPatternPlaceholder"), MaxWidth = 360, MinWidth = 220 };
    private readonly ComboBox _type = new() { MinWidth = 140, MaxWidth = 180 };
    private readonly Button _clear = new() { Content = Strings.Get("Common/Clear") };
    private bool _syncing;

    public KeySearchBar(TableTabViewModel viewModel, KeyBrowseInfo browse)
    {
        _viewModel = viewModel;
        _browse = browse;
        ColumnSpacing = 8;
        Padding = new Thickness(12, 0, 12, 6);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        AutomationProperties.SetName(_pattern, Strings.Get("Table/KeyPatternPlaceholder"));
        AutomationProperties.SetName(_type, Strings.Get("Common/Type"));
        _type.Items.Add(Strings.Get("Table/KeyTypeAll"));
        foreach (var type in browse.Types)
        {
            _type.Items.Add(type);
        }

        SetColumn(_type, 1);
        SetColumn(_clear, 2);
        Children.Add(_pattern);
        Children.Add(_type);
        Children.Add(_clear);

        Sync();
        _pattern.KeyDown += OnPatternKeyDown;
        _type.SelectionChanged += async (_, _) =>
        {
            if (_syncing)
            {
                return;
            }

            _viewModel.KeyType = _type.SelectedIndex > 0 ? _browse.Types[_type.SelectedIndex - 1] : null;
            _viewModel.KeyPattern = NullIfBlank(_pattern.Text);
            await _viewModel.ApplyKeySearchCommand.ExecuteAsync(null);
        };
        _clear.Click += async (_, _) => await _viewModel.ClearKeySearchCommand.ExecuteAsync(null);

        // The tab's view model outlives the view, so the bar listens only while it is shown.
        Loaded += (_, _) =>
        {
            _viewModel.PropertyChanged += OnViewModelPropertyChanged;
            Sync();
        };
        Unloaded += (_, _) => _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
    }

    private async void OnPatternKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
        {
            return;
        }

        e.Handled = true;
        _viewModel.KeyPattern = NullIfBlank(_pattern.Text);
        await _viewModel.ApplyKeySearchCommand.ExecuteAsync(null);
    }

    // A namespace picked in the sidebar sets the pattern from outside; the box shows what the list is searched by.
    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TableTabViewModel.KeyPattern) or nameof(TableTabViewModel.KeyType))
        {
            Sync();
        }
    }

    private void Sync()
    {
        _syncing = true;
        _pattern.Text = _viewModel.KeyPattern ?? string.Empty;
        var index = _viewModel.KeyType is { } type ? IndexOf(type) : -1;
        _type.SelectedIndex = index < 0 ? 0 : index + 1;
        _clear.Visibility = _viewModel.HasKeySearch ? Visibility.Visible : Visibility.Collapsed;
        _syncing = false;
    }

    private int IndexOf(string type)
    {
        for (var i = 0; i < _browse.Types.Count; i++)
        {
            if (string.Equals(_browse.Types[i], type, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }

        return -1;
    }

    private static string? NullIfBlank(string text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
}
