using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.Editor.Model;
using Windows.System;

namespace TablePro.Editor;

// Ctrl+F: a find box over the top right of the editor, built from stock controls. Replace is a later slice.
internal sealed partial class FindBar : UserControl
{
    private readonly Border _frame = new()
    {
        Padding = new Thickness(6),
        CornerRadius = new CornerRadius(6),
        BorderThickness = new Thickness(1),
    };
    private readonly TextBox _box = new() { PlaceholderText = "Find", Width = 220 };
    private readonly ToggleButton _matchCase = Toggle("Aa", "Match case");
    private readonly ToggleButton _wholeWord = Toggle("ab", "Match whole word");
    private readonly TextBlock _count = new() { VerticalAlignment = VerticalAlignment.Center, MinWidth = 64, Margin = new Thickness(8, 0, 4, 0) };

    public FindBar()
    {
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Top;
        Margin = new Thickness(0, 4, 20, 0);
        SetResource(Border.BackgroundProperty, "SolidBackgroundFillColorTertiaryBrush");
        SetResource(Border.BorderBrushProperty, "SurfaceStrokeColorFlyoutBrush");
        Visibility = Visibility.Collapsed;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        row.Children.Add(_box);
        row.Children.Add(_matchCase);
        row.Children.Add(_wholeWord);
        row.Children.Add(_count);
        row.Children.Add(Button("", "Previous match (Shift+F3)", () => NextRequested?.Invoke(this, true)));
        row.Children.Add(Button("", "Next match (F3)", () => NextRequested?.Invoke(this, false)));
        row.Children.Add(Button("", "Close (Esc)", () => CloseRequested?.Invoke(this, EventArgs.Empty)));
        _frame.Child = row;
        Content = _frame;
        _box.TextChanged += (_, _) => QueryChanged?.Invoke(this, EventArgs.Empty);
        _matchCase.Click += (_, _) => QueryChanged?.Invoke(this, EventArgs.Empty);
        _wholeWord.Click += (_, _) => QueryChanged?.Invoke(this, EventArgs.Empty);
        _box.KeyDown += OnBoxKeyDown;
    }

    public event EventHandler? QueryChanged;

    public event EventHandler<bool>? NextRequested;

    public event EventHandler? CloseRequested;

    public bool IsOpen => Visibility == Visibility.Visible;

    public SearchQuery Query => new(_box.Text, _matchCase.IsChecked == true, _wholeWord.IsChecked == true);

    public void Open(string? text)
    {
        Visibility = Visibility.Visible;
        if (!string.IsNullOrEmpty(text) && !text.Contains('\n'))
        {
            _box.Text = text;
        }
        _box.Focus(FocusState.Keyboard);
        _box.SelectAll();
    }

    public void Close() => Visibility = Visibility.Collapsed;

    public void ShowCount(int current, int total) =>
        _count.Text = total == 0 ? (_box.Text.Length == 0 ? string.Empty : "No results") : $"{current} of {total}";

    private void OnBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Enter:
            case VirtualKey.F3:
                NextRequested?.Invoke(this, shift);
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                CloseRequested?.Invoke(this, EventArgs.Empty);
                e.Handled = true;
                break;
        }
    }

    private void SetResource(DependencyProperty property, string key)
    {
        if (Application.Current?.Resources.TryGetValue(key, out var value) == true && value is Brush brush)
        {
            _frame.SetValue(property, brush);
        }
    }

    private static ToggleButton Toggle(string label, string tip)
    {
        var toggle = new ToggleButton { Content = label, Padding = new Thickness(8, 4, 8, 4) };
        ToolTipService.SetToolTip(toggle, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, tip);
        return toggle;
    }

    private static Button Button(string glyph, string tip, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 12 },
            Padding = new Thickness(8, 6, 8, 6),
        };
        ToolTipService.SetToolTip(button, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tip);
        button.Click += (_, _) => action();
        return button;
    }
}
