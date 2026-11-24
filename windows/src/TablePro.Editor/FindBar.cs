using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.Editor.Model;
using TablePro.Graphics;
using Windows.System;
using Windows.UI.Core;

namespace TablePro.Editor;

// As the find widgets of VS Code and Visual Studio: a chevron at the start shows the replace row.
internal sealed partial class FindBar : UserControl
{
    private const string ExpandGlyph = "";
    private const string CollapseGlyph = "";

    private readonly Border _frame = new()
    {
        Padding = new Thickness(6),
        CornerRadius = new CornerRadius(6),
        BorderThickness = new Thickness(1),
    };
    private readonly TextBox _box = Box("Find", "FindBox");
    private readonly TextBox _replaceBox = Box("Replace", "ReplaceBox");
    private readonly FontIcon _replaceGlyph = new() { Glyph = ExpandGlyph, FontSize = 12 };
    private readonly ToggleButton _replaceToggle = new()
    {
        Padding = new Thickness(4, 0, 4, 0),
        MinWidth = 0,
        VerticalAlignment = VerticalAlignment.Stretch,
    };
    private readonly ToggleButton _matchCase = Toggle("Aa", "Match case");
    private readonly ToggleButton _wholeWord = Toggle("ab", "Match whole word");
    private readonly ToggleButton _regex = Toggle(".*", "Use regular expression");
    private readonly StackPanel _replaceRow = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = 4,
        Visibility = Visibility.Collapsed,
    };
    private readonly TextBlock _count = new() { VerticalAlignment = VerticalAlignment.Center, MinWidth = 64, Margin = new Thickness(8, 0, 4, 0) };

    public FindBar()
    {
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Top;
        Margin = new Thickness(0, 4, 20, 0);
        ApplyTheme();
        ActualThemeChanged += (_, _) => ApplyTheme();
        Visibility = Visibility.Collapsed;

        _replaceToggle.Content = _replaceGlyph;
        Describe(_replaceToggle, "Toggle Replace (Ctrl+H)", "FindReplaceToggle");
        AutomationProperties.SetAutomationId(_regex, "FindRegexToggle");

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        row.Children.Add(_box);
        row.Children.Add(_matchCase);
        row.Children.Add(_wholeWord);
        row.Children.Add(_regex);
        row.Children.Add(_count);
        row.Children.Add(Button("", "Previous match (Shift+F3)", () => NextRequested?.Invoke(this, true)));
        row.Children.Add(Button("", "Next match (F3)", () => NextRequested?.Invoke(this, false)));
        row.Children.Add(Button("", "Close (Esc)", () => CloseRequested?.Invoke(this, EventArgs.Empty)));
        _replaceRow.Children.Add(_replaceBox);
        _replaceRow.Children.Add(TextButton("Replace", "Replace (Enter)", "ReplaceButton",
            () => ReplaceRequested?.Invoke(this, EventArgs.Empty)));
        _replaceRow.Children.Add(TextButton("Replace all", "Replace all (Ctrl+Alt+Enter)", "ReplaceAllButton",
            () => ReplaceAllRequested?.Invoke(this, EventArgs.Empty)));

        var rows = new StackPanel { Spacing = 4 };
        rows.Children.Add(row);
        rows.Children.Add(_replaceRow);
        var layout = new Grid { ColumnSpacing = 4 };
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.Children.Add(_replaceToggle);
        Grid.SetColumn(rows, 1);
        layout.Children.Add(rows);
        _frame.Child = layout;
        Content = _frame;

        _box.TextChanged += (_, _) => QueryChanged?.Invoke(this, EventArgs.Empty);
        _matchCase.Click += (_, _) => QueryChanged?.Invoke(this, EventArgs.Empty);
        _wholeWord.Click += (_, _) => QueryChanged?.Invoke(this, EventArgs.Empty);
        _regex.Click += (_, _) => QueryChanged?.Invoke(this, EventArgs.Empty);
        _replaceToggle.Click += (_, _) => ShowReplace(_replaceToggle.IsChecked == true);
        _box.KeyDown += OnBoxKeyDown;
        _replaceBox.KeyDown += OnReplaceBoxKeyDown;
        PreviewKeyDown += OnBarPreviewKeyDown;
        KeyDown += OnBarKeyDown;
    }

    public event EventHandler? QueryChanged;

    public event EventHandler<bool>? NextRequested;

    public event EventHandler? ReplaceRequested;

    public event EventHandler? ReplaceAllRequested;

    public event EventHandler? CloseRequested;

    public bool IsOpen => Visibility == Visibility.Visible;

    public bool IsReplaceShown => _replaceRow.Visibility == Visibility.Visible;

    public SearchQuery Query =>
        new(_box.Text, _matchCase.IsChecked == true, _wholeWord.IsChecked == true, _regex.IsChecked == true);

    public string ReplaceText => _replaceBox.Text;

    // With the replace row, focus goes where typing is still needed: the find box while it is empty.
    public void Open(string? text, bool replace)
    {
        Visibility = Visibility.Visible;
        if (!string.IsNullOrEmpty(text) && !text.Contains('\n'))
        {
            _box.Text = _regex.IsChecked == true ? TextSearch.EscapePattern(text) : text;
        }
        ShowReplace(replace);
        FocusBox(replace && _box.Text.Length > 0 ? _replaceBox : _box);
    }

    public void Close() => Visibility = Visibility.Collapsed;

    public void ShowCount(int current, int total, bool more)
    {
        if (total == 0)
        {
            _count.Text = NothingFound();
            return;
        }
        var count = more ? $"{total}+" : total.ToString(System.Globalization.CultureInfo.CurrentCulture);
        _count.Text = current > 0 ? $"{current} of {count}" : count;
    }

    public void ShowReplaced(int count) => _count.Text = count == 0 ? NothingFound() : $"{count} replaced";

    private string NothingFound() =>
        _box.Text.Length == 0 ? string.Empty : TextSearch.IsValid(Query) ? "No results" : "Invalid pattern";

    private void ShowReplace(bool shown)
    {
        _replaceToggle.IsChecked = shown;
        _replaceGlyph.Glyph = shown ? CollapseGlyph : ExpandGlyph;
        _replaceRow.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is VirtualKey.Enter or VirtualKey.F3)
        {
            NextRequested?.Invoke(this, Down(VirtualKey.Shift));
            e.Handled = true;
        }
    }

    private void OnReplaceBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Enter:
                ReplaceRequested?.Invoke(this, EventArgs.Empty);
                e.Handled = true;
                break;
            case VirtualKey.F3:
                NextRequested?.Invoke(this, Down(VirtualKey.Shift));
                e.Handled = true;
                break;
        }
    }

    // Escape from either box or any button in the bar.
    private void OnBarKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape)
        {
            CloseRequested?.Invoke(this, EventArgs.Empty);
            e.Handled = true;
        }
    }

    // Before the boxes see the key, so these chords work from any control in the bar.
    private void OnBarPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!Down(VirtualKey.Control) || Down(VirtualKey.Shift))
        {
            return;
        }
        var alt = Down(VirtualKey.Menu);
        switch (e.Key)
        {
            case VirtualKey.Enter when alt && IsReplaceShown:
                ReplaceAllRequested?.Invoke(this, EventArgs.Empty);
                e.Handled = true;
                break;
            case VirtualKey.H when !alt:
                ShowReplace(true);
                FocusBox(_box.Text.Length > 0 ? _replaceBox : _box);
                e.Handled = true;
                break;
            case VirtualKey.F when !alt:
                FocusBox(_box);
                e.Handled = true;
                break;
        }
    }

    // The app's theme is set on its root, and a lookup from code sees the system's, so the bar asks for its own theme.
    private void ApplyTheme()
    {
        var dark = ActualTheme == ElementTheme.Dark;
        _frame.Background = new SolidColorBrush(ThemeColors.Theme(
            "SolidBackgroundFillColorTertiary",
            ActualTheme,
            ThemeColors.FromArgb(dark ? 0xFF282828u : 0xFFF9F9F9u)));
        _frame.BorderBrush = new SolidColorBrush(ThemeColors.Theme(
            "SurfaceStrokeColorFlyout",
            ActualTheme,
            ThemeColors.FromArgb(dark ? 0x33000000u : 0x0F000000u)));
    }

    private static void FocusBox(TextBox box)
    {
        box.Focus(FocusState.Keyboard);
        box.SelectAll();
    }

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private static void Describe(FrameworkElement element, string tip, string? automationId = null)
    {
        ToolTipService.SetToolTip(element, tip);
        AutomationProperties.SetName(element, tip);
        if (automationId is not null)
        {
            AutomationProperties.SetAutomationId(element, automationId);
        }
    }

    private static TextBox Box(string placeholder, string automationId)
    {
        var box = new TextBox { PlaceholderText = placeholder, Width = 220 };
        AutomationProperties.SetName(box, placeholder);
        AutomationProperties.SetAutomationId(box, automationId);
        return box;
    }

    private static ToggleButton Toggle(string label, string tip)
    {
        var toggle = new ToggleButton { Content = label, Padding = new Thickness(8, 4, 8, 4) };
        Describe(toggle, tip);
        return toggle;
    }

    private static Button Button(string glyph, string tip, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 12 },
            Padding = new Thickness(8, 6, 8, 6),
        };
        Describe(button, tip);
        button.Click += (_, _) => action();
        return button;
    }

    private static Button TextButton(string text, string tip, string automationId, Action action)
    {
        var button = new Button { Content = text, Padding = new Thickness(8, 4, 8, 4) };
        ToolTipService.SetToolTip(button, tip);
        AutomationProperties.SetAutomationId(button, automationId);
        button.Click += (_, _) => action();
        return button;
    }
}
