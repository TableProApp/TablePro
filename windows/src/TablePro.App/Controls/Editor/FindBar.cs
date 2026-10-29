using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace TablePro.App.Controls.Editor;

public sealed class FindEventArgs(string query, string replacement, bool matchCase) : EventArgs
{
    public string Query { get; } = query;

    public string Replacement { get; } = replacement;

    public bool MatchCase { get; } = matchCase;
}

/// <summary>The editor's find and replace strip, laid out like the Fluent find bars in Windows apps.</summary>
internal sealed partial class FindBar : UserControl
{
    private readonly TextBox _query = new() { PlaceholderText = Strings.Get("Editor/FindPlaceholder"), Width = 240, IsSpellCheckEnabled = false };
    private readonly TextBox _replacement = new() { PlaceholderText = Strings.Get("Editor/ReplacePlaceholder"), Width = 240, IsSpellCheckEnabled = false };
    private readonly ToggleButton _matchCase = new() { Content = new FontIcon { Glyph = "", FontSize = 14 }, Padding = new Thickness(8, 6, 8, 6) };
    private readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
    private readonly StackPanel _replaceRow;

    public FindBar()
    {
        ToolTipService.SetToolTip(_matchCase, Strings.Get("Editor/MatchCase"));
        _query.KeyDown += OnQueryKeyDown;
        _replacement.KeyDown += OnQueryKeyDown;
        _status.Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"];

        var findRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        findRow.Children.Add(_query);
        findRow.Children.Add(_matchCase);
        findRow.Children.Add(IconButton("", Strings.Get("Editor/PreviousMatch"), () => FindPrevious?.Invoke(this, Args())));
        findRow.Children.Add(IconButton("", Strings.Get("Editor/NextMatch"), () => FindNext?.Invoke(this, Args())));
        findRow.Children.Add(_status);

        _replaceRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        _replaceRow.Children.Add(_replacement);
        _replaceRow.Children.Add(new Button { Content = Strings.Get("Editor/ReplaceButton"), Command = new Relay(() => Replace?.Invoke(this, Args())) });
        _replaceRow.Children.Add(new Button { Content = Strings.Get("Editor/ReplaceAllButton"), Command = new Relay(() => ReplaceAll?.Invoke(this, Args())) });

        var rows = new StackPanel { Spacing = 6 };
        rows.Children.Add(findRow);
        rows.Children.Add(_replaceRow);

        var layout = new Grid { Padding = new Thickness(10, 8, 6, 8), ColumnSpacing = 8 };
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.Children.Add(rows);
        var close = IconButton("", Strings.Get("Editor/CloseFind"), () => Closed?.Invoke(this, EventArgs.Empty));
        close.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(close, 1);
        layout.Children.Add(close);

        Content = new Border
        {
            Child = layout,
            Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["LayerFillColorAltBrush"],
            BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(0, 0, 0, 1),
        };
    }

    public event EventHandler<FindEventArgs>? FindNext;

    public event EventHandler<FindEventArgs>? FindPrevious;

    public event EventHandler<FindEventArgs>? Replace;

    public event EventHandler<FindEventArgs>? ReplaceAll;

    public event EventHandler? Closed;

    public string Query => _query.Text;

    public bool MatchCase => _matchCase.IsChecked == true;

    public void Open(bool replace, string seed)
    {
        _replaceRow.Visibility = replace ? Visibility.Visible : Visibility.Collapsed;
        if (!string.IsNullOrEmpty(seed) && !seed.Contains('\n', StringComparison.Ordinal))
        {
            _query.Text = seed;
        }

        _query.Focus(FocusState.Programmatic);
        _query.SelectAll();
    }

    public void SetStatus(string text) => _status.Text = text;

    private FindEventArgs Args() => new(_query.Text, _replacement.Text, MatchCase);

    private void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Enter when ReferenceEquals(sender, _replacement):
                Replace?.Invoke(this, Args());
                e.Handled = true;
                break;
            case VirtualKey.Enter or VirtualKey.F3:
                (shift ? FindPrevious : FindNext)?.Invoke(this, Args());
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                Closed?.Invoke(this, EventArgs.Empty);
                e.Handled = true;
                break;
        }
    }

    private static Button IconButton(string glyph, string tooltip, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 12 },
            Padding = new Thickness(8, 7, 8, 7),
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Command = new Relay(action),
        };
        ToolTipService.SetToolTip(button, tooltip);
        return button;
    }

    private sealed partial class Relay(Action action) : System.Windows.Input.ICommand
    {
        public event EventHandler? CanExecuteChanged
        {
            add { }
            remove { }
        }

        public bool CanExecute(object? parameter) => true;

        public void Execute(object? parameter) => action();
    }
}
