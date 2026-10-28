using System.Globalization;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.Storage.Library.History;

namespace TablePro.App.Views.SqlFiles;

/// <summary>
/// A file's versions on the left and the selected one on the right, either as its changes against the version it
/// follows or as its full text, with Restore and Open in Editor. Everything it shows comes from a
/// <see cref="VersionHistoryBrowser"/>, so the view holds no history logic of its own.
/// </summary>
internal sealed partial class VersionHistoryView : UserControl
{
    private readonly VersionHistoryBrowser _browser;
    private readonly DialogService _dialogs;
    private readonly Action<string> _openInEditor;
    private readonly Action _restored;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly StackPanel _notices = new() { Spacing = 8 };
    private readonly TextBlock _title = new() { Style = StyleOf("SubtitleTextBlockStyle"), TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock _subtitle = new() { Style = StyleOf("CaptionTextBlockStyle"), TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly SelectorBar _mode = new();
    private readonly ComboBox _layout = new() { MinWidth = 140 };
    private readonly Button _restore = new() { Content = "Restore", Style = StyleOf("AccentButtonStyle") };
    private readonly Button _open = new() { Content = "Open in Editor" };
    private readonly ContentControl _body = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private bool _populating;

    public VersionHistoryView(VersionHistoryBrowser browser, DialogService dialogs, Action<string> openInEditor, Action restored)
    {
        _browser = browser;
        _dialogs = dialogs;
        _openInEditor = openInEditor;
        _restored = restored;

        _mode.Items.Add(new SelectorBarItem { Text = "Changes", IsSelected = true });
        _mode.Items.Add(new SelectorBarItem { Text = "Content" });
        _mode.SelectionChanged += (_, _) => ShowDetail();
        _layout.Items.Add("Unified");
        _layout.Items.Add("Side by side");
        _layout.SelectedIndex = 0;
        _layout.SelectionChanged += (_, _) => ShowDetail();
        AutomationProperties.SetName(_layout, "Diff layout");

        _list.SelectionChanged += async (_, _) =>
        {
            if (!_populating && _list.SelectedItem is ListViewItem { Tag: VersionEntry entry })
            {
                await _browser.SelectAsync(entry.Reference);
            }
        };
        _restore.Click += async (_, _) => await RestoreAsync();
        _open.Click += (_, _) =>
        {
            if (_browser.Detail is { } detail)
            {
                _openInEditor(detail.Content);
            }
        };
        _browser.Changed += (_, _) => DispatcherQueue.TryEnqueue(Render);

        Content = Layout();
        Loaded += async (_, _) => await _browser.LoadAsync();
    }

    /// <summary>Reads the list again, as after the file changed on disk.</summary>
    public Task RefreshAsync() => _browser.LoadAsync();

    private static Style StyleOf(string key) => (Style)Application.Current.Resources[key];

    private Grid Layout()
    {
        var left = new Grid { RowSpacing = 8, Padding = new Thickness(12) };
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.Children.Add(_list);
        Grid.SetRow(_notices, 1);
        left.Children.Add(_notices);

        var header = new Grid { ColumnSpacing = 8, Padding = new Thickness(16, 12, 16, 8) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { Spacing = 2 };
        titles.Children.Add(_title);
        titles.Children.Add(_subtitle);
        header.Children.Add(titles);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(_open);
        actions.Children.Add(_restore);
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);

        var modeRow = new Grid { Padding = new Thickness(12, 0, 16, 4) };
        modeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        modeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        modeRow.Children.Add(_mode);
        Grid.SetColumn(_layout, 1);
        _layout.VerticalAlignment = VerticalAlignment.Center;
        modeRow.Children.Add(_layout);

        var right = new Grid();
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        right.Children.Add(header);
        Grid.SetRow(modeRow, 1);
        right.Children.Add(modeRow);
        var card = new Border
        {
            Margin = new Thickness(16, 4, 16, 16),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            Child = _body,
        };
        Grid.SetRow(card, 2);
        right.Children.Add(card);

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(320) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(left);
        var divider = new Border { Width = 1, HorizontalAlignment = HorizontalAlignment.Right, Background = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"] };
        root.Children.Add(divider);
        Grid.SetColumn(right, 1);
        root.Children.Add(right);
        return root;
    }

    private void Render()
    {
        _populating = true;
        try
        {
            _list.Items.Clear();
            switch (_browser.ListState)
            {
                case VersionListState.Loading:
                    _list.Items.Add(Placeholder("Loading versions…"));
                    break;
                case VersionListState.Failed:
                    _list.Items.Add(Placeholder(_browser.ListError ?? "The versions could not be read."));
                    break;
                default:
                    foreach (var entry in _browser.Page.Entries)
                    {
                        var item = Row(entry);
                        _list.Items.Add(item);
                        if (entry.Reference == _browser.Selection)
                        {
                            _list.SelectedItem = item;
                        }
                    }

                    break;
            }
        }
        finally
        {
            _populating = false;
        }

        _notices.Children.Clear();
        foreach (var notice in _browser.Page.Notices)
        {
            _notices.Children.Add(new InfoBar { Message = notice.Text, IsOpen = true, IsClosable = false, Severity = notice is GitHistoryUnavailableNotice ? InfoBarSeverity.Warning : InfoBarSeverity.Informational });
        }

        _restore.IsEnabled = _browser.CanRestoreSelection;
        _open.IsEnabled = _browser.Detail is not null;
        ShowDetail();
    }

    private void ShowDetail()
    {
        var entry = _browser.SelectedEntry;
        _title.Text = entry is null ? string.Empty : Title(entry);
        _subtitle.Text = entry is null ? string.Empty : Subtitle(entry);
        _layout.Visibility = _mode.SelectedItem == _mode.Items[0] ? Visibility.Visible : Visibility.Collapsed;

        switch (_browser.DetailState)
        {
            case VersionDetailState.Empty:
                _body.Content = Message(_browser.ListState == VersionListState.Failed ? string.Empty : "Select a version.");
                return;
            case VersionDetailState.Loading:
                _body.Content = new ProgressRing { IsActive = true, Width = 32, Height = 32, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
                return;
            case VersionDetailState.Failed:
                _body.Content = Message(_browser.DetailError ?? "This version could not be read.");
                return;
        }

        var detail = _browser.Detail!;
        if (_mode.SelectedItem != _mode.Items[0])
        {
            _body.Content = Scroll(Code(detail.Content));
            return;
        }

        _body.Content = detail.Comparison?.Outcome switch
        {
            null => Message("This is the only version, so there is nothing to compare it with."),
            IdenticalVersions => Message("No changes from " + Title(Other(detail)) + "."),
            TooLargeToCompare => Message(FormattableString.Invariant($"This file is longer than {VersionComparison.MaximumLineCount} lines, so its changes are not shown. Switch to Content to read it.")),
            DifferingVersions differs => _layout.SelectedIndex == 1 ? SideBySide(differs.Pairs) : Unified(differs.Pairs),
            _ => Message(string.Empty),
        };
    }

    private static VersionEntry Other(VersionHistoryDetail detail) =>
        detail.Comparison!.Older.Reference == detail.Entry.Reference ? detail.Comparison.Newer : detail.Comparison.Older;

    private UIElement Unified(IReadOnlyList<DiffPair> pairs)
    {
        var lines = LineDiff.Unified(pairs);
        var width = Math.Max(3, lines.Count.ToString(CultureInfo.InvariantCulture).Length);
        var text = new StringBuilder();
        var added = new TextHighlighter { Background = ThemeResources.Brush(this, "SystemFillColorSuccessBackgroundBrush") };
        var removed = new TextHighlighter { Background = ThemeResources.Brush(this, "SystemFillColorCriticalBackgroundBrush") };
        foreach (var line in lines)
        {
            var start = text.Length;
            var sign = line.Kind switch
            {
                UnifiedLineKind.Added => '+',
                UnifiedLineKind.Removed => '-',
                _ => ' ',
            };
            text.Append(Number(line.BeforeLineNumber, width)).Append(' ').Append(Number(line.AfterLineNumber, width)).Append("  ").Append(sign).Append(' ').Append(line.Text);
            if (line.Kind != UnifiedLineKind.Context)
            {
                (line.Kind == UnifiedLineKind.Added ? added : removed).Ranges.Add(new TextRange { StartIndex = start, Length = text.Length - start });
            }

            text.Append('\n');
        }

        var block = Code(text.ToString());
        block.TextHighlighters.Add(added);
        block.TextHighlighters.Add(removed);
        return Scroll(block);
    }

    private UIElement SideBySide(IReadOnlyList<DiffPair> pairs)
    {
        var before = new StringBuilder();
        var after = new StringBuilder();
        var removed = new TextHighlighter { Background = ThemeResources.Brush(this, "SystemFillColorCriticalBackgroundBrush") };
        var added = new TextHighlighter { Background = ThemeResources.Brush(this, "SystemFillColorSuccessBackgroundBrush") };
        foreach (var pair in pairs)
        {
            Append(before, pair.Before, pair.Kind is DiffKind.Removed or DiffKind.Changed ? removed : null);
            Append(after, pair.After, pair.Kind is DiffKind.Added or DiffKind.Changed ? added : null);
        }

        var left = Code(before.ToString());
        left.TextHighlighters.Add(removed);
        var right = Code(after.ToString());
        right.TextHighlighters.Add(added);
        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var leftScroll = new ScrollViewer { Content = left, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var rightScroll = new ScrollViewer { Content = right, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
        grid.Children.Add(leftScroll);
        Grid.SetColumn(rightScroll, 1);
        grid.Children.Add(rightScroll);

        // One vertical scroll for both sides keeps each row beside its counterpart.
        return new ScrollViewer { Content = grid, Padding = new Thickness(12), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

        static void Append(StringBuilder builder, string? line, TextHighlighter? highlight)
        {
            var start = builder.Length;
            builder.Append(line ?? string.Empty);
            if (highlight is not null)
            {
                highlight.Ranges.Add(new TextRange { StartIndex = start, Length = Math.Max(1, builder.Length - start) });
            }

            builder.Append('\n');
        }
    }

    private static string Number(int? number, int width) =>
        number is { } n ? n.ToString(CultureInfo.InvariantCulture).PadLeft(width) : new string(' ', width);

    private static RichTextBlock Code(string text)
    {
        var block = new RichTextBlock
        {
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.NoWrap,
            FontSize = 12,
            FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"],
        };
        var paragraph = new Paragraph();
        paragraph.Inlines.Add(new Run { Text = text });
        block.Blocks.Add(paragraph);
        return block;
    }

    private static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content,
        Padding = new Thickness(12),
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollMode = ScrollMode.Auto,
    };

    private static TextBlock Message(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(24),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };

    private static ListViewItem Placeholder(string text) => new()
    {
        Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] },
        IsHitTestVisible = false,
    };

    private static string Title(VersionEntry entry) => entry.Reference switch
    {
        CurrentVersion => "Current version",
        GitRevisionVersion => string.IsNullOrWhiteSpace(entry.Summary) ? "Commit " + entry.Reference.ShortRevision : entry.Summary!,
        _ => entry.Summary ?? "Saved version",
    };

    private static string Subtitle(VersionEntry entry)
    {
        var parts = new List<string>();
        if (entry.Date is { } date)
        {
            parts.Add(date.ToLocalTime().ToString("g", CultureInfo.CurrentCulture));
        }

        if (entry.Author is { Length: > 0 } author)
        {
            parts.Add(author);
        }

        if (entry.Reference.ShortRevision is { } revision)
        {
            parts.Add(revision);
        }

        if (entry.HasUncommittedChanges)
        {
            parts.Add("Uncommitted changes");
        }

        return string.Join(" · ", parts);
    }

    private static ListViewItem Row(VersionEntry entry)
    {
        var panel = new StackPanel { Spacing = 2, Padding = new Thickness(0, 6, 0, 6) };
        var top = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var glyph = entry.Reference switch
        {
            CurrentVersion => "",
            GitRevisionVersion => "",
            _ => "",
        };
        top.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, Foreground = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"] });
        top.Children.Add(new TextBlock { Text = Title(entry), Style = StyleOf("BodyStrongTextBlockStyle"), TextTrimming = TextTrimming.CharacterEllipsis });
        panel.Children.Add(top);
        panel.Children.Add(new TextBlock
        {
            Text = Subtitle(entry),
            Style = StyleOf("CaptionTextBlockStyle"),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var item = new ListViewItem { Content = panel, Tag = entry };
        AutomationProperties.SetName(item, Title(entry) + ", " + Subtitle(entry));
        return item;
    }

    private async Task RestoreAsync()
    {
        if (_browser.SelectedEntry is not { IsCurrent: false } entry)
        {
            return;
        }

        var (outcome, error) = await _browser.RestoreAsync(entry, () => _dialogs.ConfirmAsync(
            "Replace the current text?",
            "The file has changes that are not in any saved version or commit. Restoring replaces them; they are kept as a saved version first.",
            "Restore",
            destructive: true));
        switch (outcome)
        {
            case VersionRestoreOutcome.Restored:
                _restored();
                break;
            case VersionRestoreOutcome.Failed:
                await _dialogs.ShowErrorAsync("Couldn't Restore", error ?? "The version could not be restored.");
                break;
        }
    }
}
