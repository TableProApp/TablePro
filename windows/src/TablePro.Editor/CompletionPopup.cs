using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using TablePro.Graphics;
using TablePro.Interop;
using Windows.Foundation;

namespace TablePro.Editor;

// The rows a completion offers. It never takes focus, so the editor keeps the keys, the caret and the IME.
internal sealed class CompletionPopup
{
    public const double RowHeight = 28;

    private const double IconWidth = 20;
    private const double RowPadding = 10;
    private const double ColumnSpacing = 10;

    // Only markup can name theme resources, so the frame and its styles are markup and the rows are made in code.
    private const string Markup = """
        <Border
            xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            MinWidth="280"
            MaxWidth="560"
            Padding="0,4"
            Background="{ThemeResource FlyoutPresenterBackground}"
            BorderBrush="{ThemeResource FlyoutBorderThemeBrush}"
            BorderThickness="{ThemeResource FlyoutBorderThemeThickness}"
            CornerRadius="{ThemeResource OverlayCornerRadius}">
            <Border.Resources>
                <Style x:Key="CompletionDetail" TargetType="TextBlock" BasedOn="{StaticResource CaptionTextBlockStyle}">
                    <Setter Property="Foreground" Value="{ThemeResource TextFillColorSecondaryBrush}" />
                    <Setter Property="VerticalAlignment" Value="Center" />
                </Style>
            </Border.Resources>
            <ListView MaxHeight="238" IsTabStop="False" AllowFocusOnInteraction="False" SelectionMode="Single" />
        </Border>
        """;

    private readonly Popup _popup = new() { IsLightDismissEnabled = false };
    private readonly Border _frame;
    private readonly ListView _list;
    private readonly Style? _detailStyle;
    private readonly List<Row> _rows = [];
    private IReadOnlyList<CompletionItem> _items = [];
    private int _total;
    private bool _filling;

    public CompletionPopup(Panel host)
    {
        _frame = (Border)XamlReader.Load(Markup);
        _list = (ListView)_frame.Child;
        _detailStyle = _frame.Resources.TryGetValue("CompletionDetail", out var style) ? style as Style : null;
        AutomationProperties.SetAutomationId(_list, "CompletionList");
        AutomationProperties.SetName(_list, HostStrings.Get("CompletionListName"));
        _popup.Child = _frame;
        _popup.HorizontalAlignment = HorizontalAlignment.Left;
        _popup.VerticalAlignment = VerticalAlignment.Top;
        host.Children.Add(_popup);
        _list.SelectionChanged += (_, _) =>
        {
            if (!_filling)
            {
                SelectionChanged?.Invoke(this, EventArgs.Empty);
            }
        };
        _list.DoubleTapped += OnDoubleTapped;
    }

    public event EventHandler? SelectionChanged;

    public event EventHandler? Accepted;

    public bool IsOpen => _popup.IsOpen;

    public UIElement List => _list;

    // The word the rows were ranked for.
    public string Word { get; private set; } = string.Empty;

    public CompletionItem? Selected => _list.SelectedIndex is var index and >= 0 && index < _items.Count
        ? _items[index]
        : null;

    public int PageRows => Math.Max(1, (int)(_list.MaxHeight / RowHeight) - 1);

    // The rows are made once and filled again for each word, so typing does not build a list of controls per key.
    public void Show(CompletionPage page, string word, ElementTheme theme)
    {
        Word = word;
        _total = page.Total;
        _items = page.Items;
        _frame.RequestedTheme = theme;
        _filling = true;
        try
        {
            while (_list.Items.Count > _items.Count)
            {
                _list.Items.RemoveAt(_list.Items.Count - 1);
            }
            for (var i = 0; i < _items.Count; i++)
            {
                if (i == _rows.Count)
                {
                    _rows.Add(NewRow());
                }
                Fill(_rows[i], _items[i]);
                if (i == _list.Items.Count)
                {
                    _list.Items.Add(_rows[i].Container);
                }
            }
            _popup.IsOpen = true;
            _list.SelectedIndex = _items.Count > 0 ? 0 : -1;
        }
        finally
        {
            _filling = false;
        }
        if (_items.Count > 0)
        {
            _list.ScrollIntoView(_list.Items[0]);
        }
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Close()
    {
        _popup.IsOpen = false;
        _items = [];
        _total = 0;
        Word = string.Empty;
    }

    // Up and Down stop at the ends, as the macOS list does; a page moves by the rows in view.
    public void Move(int rows)
    {
        if (_items.Count == 0)
        {
            return;
        }
        var index = Math.Clamp(_list.SelectedIndex + rows, 0, _items.Count - 1);
        _list.SelectedIndex = index;
        _list.ScrollIntoView(_list.Items[index]);
    }

    // The label lines up with the word typed, below the caret's line, or above it when only that fits.
    public void Place(Rect wordStart, Rect caret, double viewWidth, double viewHeight)
    {
        // The rows are laid out on the next pass, so the height comes from their count.
        var width = Math.Max(_frame.MinWidth, _frame.ActualWidth);
        var padding = _frame.Padding;
        var border = _frame.BorderThickness;
        var height = Math.Min(_items.Count * RowHeight, _list.MaxHeight)
            + padding.Top + padding.Bottom + border.Top + border.Bottom;
        var inset = RowPadding + IconWidth + ColumnSpacing;
        var x = Math.Clamp(wordStart.X - inset, 0, Math.Max(0, viewWidth - width));
        var below = caret.Bottom + 2;
        var above = caret.Top - height - 2;
        _popup.HorizontalOffset = x;
        _popup.VerticalOffset = below + height <= viewHeight || above < 0 ? below : above;
    }

    // What Narrator reads for the selected row: its name, its kind and its place in the list.
    public string Announcement() => Selected is { } item
        ? HostStrings.Format("CompletionAnnouncement", Name(item), _list.SelectedIndex + 1, _total)
        : string.Empty;

    private static string Name(CompletionItem item) =>
        HostStrings.Format("CompletionRowName", item.Label, Describe(item));

    private static string Describe(CompletionItem item) => item.Kind switch
    {
        CompletionKind.Column => item.DataType ?? HostStrings.Get("CompletionColumn"),
        CompletionKind.Schema => HostStrings.Get("CompletionSchema"),
        CompletionKind.Table => HostStrings.Get("CompletionTable"),
        CompletionKind.View => HostStrings.Get("CompletionView"),
        CompletionKind.MaterializedView => HostStrings.Get("CompletionMaterializedView"),
        CompletionKind.Function => HostStrings.Get("CompletionFunction"),
        _ => HostStrings.Get("CompletionKeyword"),
    };

    // The object tree's symbols for the same kinds.
    private static Symbol Icon(CompletionKind kind) => kind switch
    {
        CompletionKind.Table => Symbol.ViewAll,
        CompletionKind.View or CompletionKind.MaterializedView => Symbol.View,
        CompletionKind.Function => Symbol.Calculator,
        CompletionKind.Schema => Symbol.Folder,
        CompletionKind.Column => Symbol.List,
        _ => Symbol.Font,
    };

    private Row NewRow()
    {
        var icon = new SymbolIcon { VerticalAlignment = VerticalAlignment.Center };
        var label = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var detail = new TextBlock { Style = _detailStyle };
        Grid.SetColumn(label, 1);
        Grid.SetColumn(detail, 2);
        var grid = new Grid { ColumnSpacing = ColumnSpacing, Children = { icon, label, detail } };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(IconWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var container = new ListViewItem
        {
            Content = grid,
            MinHeight = RowHeight,
            Height = RowHeight,
            Padding = new Thickness(RowPadding, 0, 12, 0),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            IsTabStop = false,
            AllowFocusOnInteraction = false,
        };
        return new Row(container, icon, label, detail);
    }

    private static void Fill(Row row, CompletionItem item)
    {
        row.Icon.Symbol = Icon(item.Kind);
        FillLabel(row.Label, item);
        row.Detail.Text = Describe(item);
        AutomationProperties.SetName(row.Container, Name(item));
    }

    // The characters the word matched are semibold, as Windows search marks them.
    private static void FillLabel(TextBlock label, CompletionItem item)
    {
        label.Inlines.Clear();
        var text = item.Label;
        var at = 0;
        foreach (var span in item.Matched)
        {
            var start = Math.Clamp(span.Start, at, text.Length);
            var end = Math.Clamp(span.Start + span.Length, start, text.Length);
            if (start > at)
            {
                label.Inlines.Add(new Run { Text = text[at..start] });
            }
            if (end > start)
            {
                label.Inlines.Add(new Run { Text = text[start..end], FontWeight = FontWeights.SemiBold });
            }
            at = end;
        }
        if (at < text.Length)
        {
            label.Inlines.Add(new Run { Text = text[at..] });
        }
    }

    private void OnDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (Selected is not null)
        {
            e.Handled = true;
            Accepted?.Invoke(this, EventArgs.Empty);
        }
    }

    private sealed record Row(ListViewItem Container, SymbolIcon Icon, TextBlock Label, TextBlock Detail);
}
