using System.Text;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.Core.Sql;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI;
using Windows.UI.Core;

namespace TablePro.App.Controls.Editor;

public enum RunScope
{
    /// <summary>The selection, or the statement under the caret.</summary>
    Current,
    All,
    Explain,
}

/// <summary>
/// The SQL editor: a RichEditBox colored by the dialect's own lexer, with a line gutter, completion, find and replace,
/// comment toggling and indentation. The built-in undo is off because coloring would fill it; the editor keeps its
/// own stack of text snapshots instead.
/// </summary>
/// <remarks>
/// Text uses '\r' line ends internally, as RichEdit stores paragraphs, so offsets from the lexer and the document agree.
/// </remarks>
public sealed partial class SqlEditor : UserControl
{
    private const double LineHeightPixels = 19;
    private const int MaxHighlightLength = 400_000;
    private const string Indent = "    ";

    private readonly RichEditBox _box;
    private readonly TextBlock _gutter;
    private readonly Canvas _gutterCanvas;
    private readonly TranslateTransform _gutterShift = new();
    private readonly FindBar _findBar;
    private readonly Popup _completionPopup = new() { IsLightDismissEnabled = false };
    private readonly ListView _completionList;
    private readonly DispatcherQueueTimerHolder _highlightTimer;
    private readonly DispatcherQueueTimerHolder _pauseTimer;
    private readonly Popup _suggestionPopup = new() { IsLightDismissEnabled = false };
    private readonly TextBlock _suggestionText = new() { FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.NoWrap };
    private string? _suggestion;
    private int _suggestionCaret = -1;
    private readonly List<(string Text, int Start, int End)> _undo = [];
    private readonly List<(string Text, int Start, int End)> _redo = [];

    private SqlDialect _dialect = PostgreSqlDialect.Instance;
    private string _text = string.Empty;
    private string _highlightedText = "\u0001";
    private int _lineCount = -1;
    private bool _suppress;
    private DateTime _lastSnapshot = DateTime.MinValue;
    private int _completionStart;
    private Palette _palette;

    public SqlEditor()
    {
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        _findBar = new FindBar { Visibility = Visibility.Collapsed };
        _findBar.FindNext += (_, args) => Find(args.Query, args.MatchCase, forward: true);
        _findBar.FindPrevious += (_, args) => Find(args.Query, args.MatchCase, forward: false);
        _findBar.Replace += (_, args) => ReplaceOne(args.Query, args.Replacement, args.MatchCase);
        _findBar.ReplaceAll += (_, args) => ReplaceAll(args.Query, args.Replacement, args.MatchCase);
        _findBar.Closed += (_, _) =>
        {
            _findBar.Visibility = Visibility.Collapsed;
            _box?.Focus(FocusState.Programmatic);
        };
        Grid.SetColumnSpan(_findBar, 2);
        root.Children.Add(_findBar);

        _gutter = new TextBlock
        {
            TextAlignment = TextAlignment.Right,
            LineHeight = LineHeightPixels,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            FontSize = 12,
            IsTextScaleFactorEnabled = false,
            Margin = new Thickness(0, 9, 10, 0),
        };
        _gutterCanvas = new Canvas { Width = 44, RenderTransform = _gutterShift, IsHitTestVisible = false };
        _gutterCanvas.Children.Add(_gutter);
        var gutterHost = new Border { Child = _gutterCanvas, Width = 48, BorderThickness = new Thickness(0, 0, 1, 0) };
        gutterHost.SizeChanged += (_, e) => gutterHost.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };
        Grid.SetRow(gutterHost, 1);
        root.Children.Add(gutterHost);

        _box = new RichEditBox
        {
            AcceptsReturn = true,
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            TextWrapping = TextWrapping.NoWrap,
            ClipboardCopyFormat = RichEditClipboardFormat.PlainText,
            DisabledFormattingAccelerators = DisabledFormattingAccelerators.All,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            FontSize = 13,
            Padding = new Thickness(10, 8, 10, 8),
            SelectionFlyout = null,
        };
        _box.SetValue(ScrollViewer.HorizontalScrollBarVisibilityProperty, ScrollBarVisibility.Auto);
        _box.SetValue(ScrollViewer.VerticalScrollBarVisibilityProperty, ScrollBarVisibility.Auto);
        _box.Document.UndoLimit = 0;
        _box.TextChanged += OnTextChanged;
        _box.SelectionChanged += (_, _) => SelectionChanged?.Invoke(this, EventArgs.Empty);
        _box.Paste += OnPaste;
        _box.PreviewKeyDown += OnPreviewKeyDown;
        _box.CharacterReceived += OnCharacterReceived;
        _box.LostFocus += (_, _) => HideCompletion();
        _box.Loaded += OnBoxLoaded;
        _box.ContextFlyout = BuildContextMenu();
        Grid.SetRow(_box, 1);
        Grid.SetColumn(_box, 1);
        root.Children.Add(_box);

        _completionList = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 280,
            Width = 360,
            IsItemClickEnabled = true,
        };
        _completionList.ItemClick += (_, e) => AcceptCompletion((e.ClickedItem as FrameworkElement)?.Tag ?? (_completionList.SelectedItem as ListViewItem)?.Tag);
        _completionPopup.Child = new Border
        {
            Child = _completionList,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(2),
            Shadow = new ThemeShadow(),
            Translation = new System.Numerics.Vector3(0, 0, 32),
        };

        Content = root;
        _highlightTimer = new DispatcherQueueTimerHolder(this, TimeSpan.FromMilliseconds(80), Highlight);
        _pauseTimer = new DispatcherQueueTimerHolder(this, TimeSpan.FromMilliseconds(900), OnTypingPaused);
        var hint = new TextBlock { Text = "Tab to accept", FontSize = 10, Opacity = 0.6, Margin = new Thickness(0, 4, 0, 0) };
        var suggestionPanel = new StackPanel();
        suggestionPanel.Children.Add(_suggestionText);
        suggestionPanel.Children.Add(hint);
        _suggestionPopup.Child = new Border
        {
            Child = suggestionPanel,
            Padding = new Thickness(8, 4, 8, 4),
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
            Shadow = new ThemeShadow(),
            Translation = new System.Numerics.Vector3(0, 0, 16),
        };
        _box.LostFocus += (_, _) => HideSuggestion();
        ActualThemeChanged += (_, _) => ApplyTheme(gutterHost);
        Loaded += (_, _) => ApplyTheme(gutterHost);
    }

    public event EventHandler<RunScope>? RunRequested;

    public event EventHandler? TextChanged;

    public event EventHandler? SelectionChanged;

    public event EventHandler? SaveRequested;

    public event EventHandler? FormatRequested;

    /// <summary>Typing paused with the caret at the end of a non-empty line: the moment to ask for an AI suggestion.</summary>
    public event EventHandler<(string Before, string After, int Caret)>? PausedAtLineEnd;

    /// <summary>Whether <see cref="PausedAtLineEnd"/> fires; on only when the user turned suggestions on.</summary>
    public bool SuggestionsEnabled { get; set; }

    /// <summary>Shows text to insert at the caret, which Tab accepts, if the caret has not moved since the pause.</summary>
    public void ShowSuggestion(string text, int caret)
    {
        // Tab accepts a suggestion, which outside Vim's insert mode would type into the text.
        if (string.IsNullOrWhiteSpace(text) || caret != SelectionStart || SelectionLength > 0 || _completionPopup.IsOpen || IsVimOutsideInsert)
        {
            return;
        }

        _suggestion = text.Replace("\r\n", "\r", StringComparison.Ordinal).Replace('\n', '\r');
        _suggestionCaret = caret;
        var firstLine = _suggestion.Split('\r')[0];
        _suggestionText.Text = _suggestion.Contains('\r') ? firstLine + " …" : firstLine;
        if (Application.Current.Resources.TryGetValue("CodeFontFamily", out var font) && font is FontFamily family)
        {
            _suggestionText.FontFamily = family;
        }

        if (_suggestionPopup.Child is Border border)
        {
            border.Background = ThemeResources.Brush(this, "AcrylicInAppFillColorDefaultBrush");
            border.BorderBrush = ThemeResources.Brush(this, "SurfaceStrokeColorFlyoutBrush");
        }

        _box.Document.Selection.GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        var origin = _box.TransformToVisual(this).TransformPoint(new Windows.Foundation.Point(rect.Right, rect.Bottom));
        _suggestionPopup.XamlRoot = XamlRoot;
        if (_suggestionPopup.Parent is null && Content is Grid grid && !grid.Children.Contains(_suggestionPopup))
        {
            grid.Children.Add(_suggestionPopup);
        }

        _suggestionPopup.HorizontalOffset = origin.X + 4;
        _suggestionPopup.VerticalOffset = origin.Y + 2;
        _suggestionPopup.IsOpen = true;
    }

    private void HideSuggestion()
    {
        _suggestionPopup.IsOpen = false;
        _suggestion = null;
    }

    private void OnTypingPaused()
    {
        if (!SuggestionsEnabled || SelectionLength > 0 || _completionPopup.IsOpen || IsVimOutsideInsert)
        {
            return;
        }

        SyncText();
        var caret = SelectionStart;
        var lineEnd = _text.IndexOf('\r', caret);
        var restOfLine = lineEnd < 0 ? _text[caret..] : _text[caret..lineEnd];
        var lineStart = caret == 0 ? 0 : _text.LastIndexOf('\r', caret - 1) + 1;
        if (restOfLine.Trim().Length > 0 || _text[lineStart..caret].Trim().Length == 0)
        {
            return;
        }

        PausedAtLineEnd?.Invoke(this, (_text[..caret].Replace('\r', '\n'), _text[caret..].Replace('\r', '\n'), caret));
    }

    public SqlDialect Dialect
    {
        get => _dialect;
        set
        {
            _dialect = value;
            _highlightedText = "\u0001";
            _highlightTimer.Restart();
        }
    }

    /// <summary>What completion offers beyond keywords; the workspace replaces it as the schema loads.</summary>
    public CompletionCatalog Catalog { get; set; } = CompletionCatalog.Empty;

    public bool CompletionEnabled { get; set; } = true;

    /// <summary>The text with '\n' line ends.</summary>
    public string Text
    {
        get
        {
            SyncText();
            return _text.Replace('\r', '\n');
        }

        set => SetTextCore((value ?? string.Empty).Replace("\r\n", "\r", StringComparison.Ordinal).Replace('\n', '\r'), 0, 0, recordUndo: false);
    }

    /// <summary>The text exactly as the document holds it, for offsets that must match the caret.</summary>
    public string RawText
    {
        get
        {
            SyncText();
            return _text;
        }
    }

    public int SelectionStart => Math.Min(_box.Document.Selection.StartPosition, _text.Length);

    public int SelectionLength => Math.Max(0, Math.Min(_box.Document.Selection.EndPosition, _text.Length) - SelectionStart);

    public string SelectedText => SelectionLength > 0 ? _text.Substring(SelectionStart, SelectionLength).Replace('\r', '\n') : string.Empty;

    public new double FontSize
    {
        get => _box.FontSize;
        set
        {
            _box.FontSize = value;
            _gutter.FontSize = Math.Max(9, value - 1);
        }
    }

    public new FontFamily FontFamily
    {
        get => _box.FontFamily;
        set
        {
            _box.FontFamily = value;
            _gutter.FontFamily = value;
        }
    }

    public bool WordWrap
    {
        get => _box.TextWrapping == TextWrapping.Wrap;
        set => _box.TextWrapping = value ? TextWrapping.Wrap : TextWrapping.NoWrap;
    }

    public void FocusEditor() => _box.Focus(FocusState.Programmatic);

    public void Select(int start, int length)
    {
        _box.Document.Selection.SetRange(start, start + length);
        _box.Document.Selection.ScrollIntoView(PointOptions.None);
    }

    /// <summary>Replaces the selection through RichEdit itself, so formatting, scroll and the caret stay put.</summary>
    public void InsertText(string text)
    {
        SyncText();
        var insert = text.Replace("\r\n", "\r", StringComparison.Ordinal).Replace('\n', '\r');
        PushUndo(force: true);
        var selection = _box.Document.Selection;
        selection.SetText(TextSetOptions.None, insert);
        selection.Collapse(false);
        _highlightTimer.Restart();
    }

    /// <summary>Replaces the whole text as one undo step, keeping the caret near where it was.</summary>
    public void ReplaceAllText(string text)
    {
        SyncText();
        var caret = SelectionStart;
        var normalized = text.Replace("\r\n", "\r", StringComparison.Ordinal).Replace('\n', '\r');
        SetTextCore(normalized, Math.Min(caret, normalized.Length), Math.Min(caret, normalized.Length), recordUndo: true);
    }

    public void ShowFind(bool replace)
    {
        _findBar.Visibility = Visibility.Visible;
        _findBar.Open(replace, SelectedText);
    }

    public void Undo()
    {
        SyncText();
        if (_undo.Count == 0)
        {
            return;
        }

        var current = (_text, SelectionStart, SelectionStart + SelectionLength);
        var previous = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        _redo.Add(current);
        SetTextCore(previous.Text, previous.Start, previous.End, recordUndo: false);

        // Typing after an undo inside an open Vim insert group starts a new step instead of joining the undone one.
        _undoGroupSnapshotTaken = false;
    }

    public void Redo()
    {
        if (_redo.Count == 0)
        {
            return;
        }

        var current = (_text, SelectionStart, SelectionStart + SelectionLength);
        var next = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        _undo.Add(current);
        SetTextCore(next.Text, next.Start, next.End, recordUndo: false);
        _undoGroupSnapshotTaken = false;
    }

    public void ToggleComment()
    {
        SyncText();
        var (lineStart, lineEnd) = SelectedLineRange();
        var block = _text[lineStart..lineEnd];
        var lines = block.Split('\r');
        var marker = _dialect.LineComment;
        var allCommented = lines.Where(l => l.Trim().Length > 0).All(l => l.TrimStart().StartsWith(marker, StringComparison.Ordinal));
        for (var i = 0; i < lines.Length; i++)
        {
            if (lines[i].Trim().Length == 0)
            {
                continue;
            }

            if (allCommented)
            {
                var at = lines[i].IndexOf(marker, StringComparison.Ordinal);
                var remove = at + marker.Length < lines[i].Length && lines[i][at + marker.Length] == ' ' ? marker.Length + 1 : marker.Length;
                lines[i] = lines[i].Remove(at, remove);
            }
            else
            {
                var indent = lines[i].Length - lines[i].TrimStart().Length;
                lines[i] = lines[i].Insert(indent, marker + " ");
            }
        }

        var replaced = string.Join('\r', lines);
        SetTextCore(string.Concat(_text.AsSpan(0, lineStart), replaced, _text.AsSpan(lineEnd)), lineStart, lineStart + replaced.Length, recordUndo: true);
    }

    private MenuFlyout BuildContextMenu()
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Item("Run Current", "", () => RunRequested?.Invoke(this, RunScope.Current), VirtualKey.Enter, VirtualKeyModifiers.Control));
        menu.Items.Add(Item("Run All", "", () => RunRequested?.Invoke(this, RunScope.All), VirtualKey.F5, VirtualKeyModifiers.None));
        menu.Items.Add(Item("Explain", "", () => RunRequested?.Invoke(this, RunScope.Explain), VirtualKey.E, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Cut", "", () => _box.Document.Selection.Cut(), VirtualKey.X, VirtualKeyModifiers.Control));
        menu.Items.Add(Item("Copy", "", () => _box.Document.Selection.Copy(), VirtualKey.C, VirtualKeyModifiers.Control));
        menu.Items.Add(Item("Paste", "", PasteAsync, VirtualKey.V, VirtualKeyModifiers.Control));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Undo", "", Undo, VirtualKey.Z, VirtualKeyModifiers.Control));
        menu.Items.Add(Item("Redo", "", Redo, VirtualKey.Y, VirtualKeyModifiers.Control));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Toggle Comment", "", ToggleComment, (VirtualKey)191, VirtualKeyModifiers.Control));
        menu.Items.Add(Item("Format SQL", "", () => FormatRequested?.Invoke(this, EventArgs.Empty), VirtualKey.F, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift));
        menu.Items.Add(Item("Find", "", () => ShowFind(replace: false), VirtualKey.F, VirtualKeyModifiers.Control));
        menu.Items.Add(Item("Replace", "", () => ShowFind(replace: true), VirtualKey.H, VirtualKeyModifiers.Control));
        return menu;

        static MenuFlyoutItem Item(string text, string glyph, Action action, VirtualKey key, VirtualKeyModifiers modifiers)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) => action();

            // The accelerator is shown, not registered: the editor's key handler owns these keys.
            item.KeyboardAcceleratorTextOverride = AcceleratorText(key, modifiers);
            return item;
        }
    }

    private static string AcceleratorText(VirtualKey key, VirtualKeyModifiers modifiers)
    {
        var sb = new StringBuilder();
        if (modifiers.HasFlag(VirtualKeyModifiers.Control))
        {
            sb.Append("Ctrl+");
        }

        if (modifiers.HasFlag(VirtualKeyModifiers.Shift))
        {
            sb.Append("Shift+");
        }

        sb.Append(key switch
        {
            VirtualKey.Enter => "Enter",
            (VirtualKey)191 => "/",
            _ => key.ToString(),
        });
        return sb.ToString();
    }

    private void ApplyTheme(Border gutterHost)
    {
        _palette = new Palette(
            Plain: ThemeResources.Color(this, "SqlPlainColor"),
            Keyword: ThemeResources.Color(this, "SqlKeywordColor"),
            Function: ThemeResources.Color(this, "SqlFunctionColor"),
            String: ThemeResources.Color(this, "SqlStringColor"),
            Number: ThemeResources.Color(this, "SqlNumberColor"),
            Comment: ThemeResources.Color(this, "SqlCommentColor"),
            Identifier: ThemeResources.Color(this, "SqlIdentifierColor"),
            Parameter: ThemeResources.Color(this, "SqlParameterColor"));
        _gutter.Foreground = ThemeResources.Brush(this, "TextFillColorTertiaryBrush");
        gutterHost.BorderBrush = ThemeResources.Brush(this, "DividerStrokeColorDefaultBrush");
        if (_completionPopup.Child is Border popupBorder)
        {
            popupBorder.Background = ThemeResources.Brush(this, "AcrylicInAppFillColorDefaultBrush");
            popupBorder.BorderBrush = ThemeResources.Brush(this, "SurfaceStrokeColorFlyoutBrush");
        }

        _highlightedText = "\u0001";
        Highlight();
    }

    private void OnBoxLoaded(object sender, RoutedEventArgs e)
    {
        if (Application.Current.Resources.TryGetValue("CodeFontFamily", out var font) && font is FontFamily family)
        {
            FontFamily = family;
        }

        ApplyLineSpacing();
        if (FindDescendant<ScrollViewer>(_box) is { } scroller)
        {
            scroller.ViewChanged += (s, _) => _gutterShift.Y = -((ScrollViewer)s!).VerticalOffset;
        }
    }

    private void ApplyLineSpacing()
    {
        // Exact line spacing keeps the gutter's numbers on the document's lines; RichEdit measures it in points.
        var format = _box.Document.GetDefaultParagraphFormat();
        format.SetLineSpacing(LineSpacingRule.Exactly, (float)(LineHeightPixels * 0.75));
        _box.Document.SetDefaultParagraphFormat(format);
    }

    private static T? FindDescendant<T>(DependencyObject root)
        where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T match)
            {
                return match;
            }

            if (FindDescendant<T>(child) is { } nested)
            {
                return nested;
            }
        }

        return null;
    }

    private void SetTextCore(string text, int selectionStart, int selectionEnd, bool recordUndo)
    {
        if (recordUndo)
        {
            PushUndo(force: true);
        }

        _suppress = true;
        try
        {
            _box.Document.SetText(TextSetOptions.None, text);
            ApplyLineSpacing();
            _text = ReadDocument();
            _box.Document.Selection.SetRange(Math.Min(selectionStart, _text.Length), Math.Min(selectionEnd, _text.Length));
        }
        finally
        {
            _suppress = false;
        }

        _highlightedText = "\u0001";
        Highlight();
        UpdateGutter();
        TextChanged?.Invoke(this, EventArgs.Empty);
    }

    private string ReadDocument()
    {
        _box.Document.GetText(TextGetOptions.None, out var text);

        // RichEdit always ends the document with a paragraph mark the user never typed.
        return text.EndsWith('\r') ? text[..^1] : text;
    }

    private void OnTextChanged(object sender, RoutedEventArgs e)
    {
        if (!_suppress && SyncText())
        {
            _highlightTimer.Restart();
            HideSuggestion();
            if (SuggestionsEnabled)
            {
                _pauseTimer.Restart();
            }

            TextChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Brings the cached text up to the document. RichEdit raises TextChanged after the edit, so a key handler can
    /// run before it; every edit syncs first or it would rebuild the document from text missing the last keys.
    /// </summary>
    private bool SyncText()
    {
        var text = ReadDocument();
        if (string.Equals(text, _text, StringComparison.Ordinal))
        {
            return false;
        }

        PushUndo(force: false);
        _text = text;
        UpdateGutter();
        return true;
    }

    private void PushUndo(bool force)
    {
        var now = DateTime.UtcNow;

        // Inside a Vim undo group only the first edit takes a snapshot, so the whole command undoes as one step.
        if (_undoGroupDepth > 0)
        {
            if (_undoGroupSnapshotTaken)
            {
                return;
            }

            _undoGroupSnapshotTaken = true;
            force = true;
        }

        // Typing within half a second joins one undo step, the way most editors group keystrokes.
        if (!force && now - _lastSnapshot < TimeSpan.FromMilliseconds(500) && _undo.Count > 0)
        {
            _lastSnapshot = now;
            return;
        }

        _undo.Add((_text, SelectionStart, SelectionStart + SelectionLength));
        if (_undo.Count > 500)
        {
            _undo.RemoveAt(0);
        }

        _redo.Clear();
        _lastSnapshot = now;
    }

    private void UpdateGutter()
    {
        var lines = 1;
        foreach (var c in _text.AsSpan())
        {
            if (c == '\r')
            {
                lines++;
            }
        }

        if (lines == _lineCount)
        {
            return;
        }

        _lineCount = lines;
        var sb = new StringBuilder(lines * 4);
        for (var i = 1; i <= lines; i++)
        {
            sb.Append(i).Append('\n');
        }

        _gutter.Text = sb.ToString();
        _gutter.Width = 36;
    }

    private void Highlight()
    {
        if (string.Equals(_highlightedText, _text, StringComparison.Ordinal) || _palette.Plain.A == 0)
        {
            return;
        }

        _highlightedText = _text;
        var document = _box.Document;
        _suppress = true;
        try
        {
            document.BatchDisplayUpdates();
            var all = document.GetRange(0, _text.Length);
            all.CharacterFormat.ForegroundColor = _palette.Plain;
            if (_text.Length <= MaxHighlightLength)
            {
                var span = _text.AsSpan();
                var lexer = new SqlLexer(span, _dialect.LexerFeatures);
                while (lexer.TryRead(out var token))
                {
                    var color = ColorFor(token, span);
                    if (color is { } c)
                    {
                        document.GetRange(token.Start, token.End).CharacterFormat.ForegroundColor = c;
                    }
                }
            }

            document.ApplyDisplayUpdates();
        }
        finally
        {
            _suppress = false;
        }
    }

    private Color? ColorFor(SqlToken token, ReadOnlySpan<char> text) => token.Kind switch
    {
        SqlTokenKind.LineComment or SqlTokenKind.BlockComment => _palette.Comment,
        SqlTokenKind.String => _palette.String,
        SqlTokenKind.Number => _palette.Number,
        SqlTokenKind.QuotedIdentifier => _palette.Identifier,
        SqlTokenKind.Parameter => _palette.Parameter,
        SqlTokenKind.Word when _dialect.IsSql && SqlKeywords.IsFunction(token.Slice(text)) && NextIsParen(text, token.End) => _palette.Function,
        SqlTokenKind.Word when _dialect.IsKeyword(token.Slice(text)) => _palette.Keyword,
        _ => null,
    };

    private static bool NextIsParen(ReadOnlySpan<char> text, int index)
    {
        while (index < text.Length && text[index] == ' ')
        {
            index++;
        }

        return index < text.Length && text[index] == '(';
    }

    private async void OnPaste(object sender, TextControlPasteEventArgs e)
    {
        e.Handled = true;
        await PasteCoreAsync();
    }

    private async void PasteAsync() => await PasteCoreAsync();

    private async Task PasteCoreAsync()
    {
        var content = Clipboard.GetContent();
        if (content.Contains(StandardDataFormats.Text))
        {
            // Plain text only: rich paste would bring fonts and colors from wherever it was copied.
            InsertText(await content.GetTextAsync());
        }
    }

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);

        if (_suggestion is { } suggestion)
        {
            var accept = e.Key == VirtualKey.Tab && _suggestionCaret == SelectionStart;
            HideSuggestion();
            if (accept)
            {
                InsertText(suggestion);
                e.Handled = true;
                return;
            }
        }

        if (TryHandleVimEscape(e))
        {
            e.Handled = true;
            return;
        }

        if (_completionPopup.IsOpen && HandleCompletionKey(e.Key))
        {
            e.Handled = true;
            return;
        }

        if (TryHandleVimKey(e))
        {
            e.Handled = true;
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Enter when ctrl && shift:
                RunRequested?.Invoke(this, RunScope.All);
                break;
            case VirtualKey.Enter when ctrl:
                RunRequested?.Invoke(this, RunScope.Current);
                break;
            case VirtualKey.F5:
                RunRequested?.Invoke(this, shift ? RunScope.Current : RunScope.All);
                break;
            case VirtualKey.E when ctrl && shift:
                RunRequested?.Invoke(this, RunScope.Explain);
                break;
            case VirtualKey.Z when ctrl && shift:
            case VirtualKey.Y when ctrl:
                Redo();
                break;
            case VirtualKey.Z when ctrl:
                Undo();
                break;
            case VirtualKey.S when ctrl:
                SaveRequested?.Invoke(this, EventArgs.Empty);
                break;
            case VirtualKey.F when ctrl && shift:
                FormatRequested?.Invoke(this, EventArgs.Empty);
                break;
            case VirtualKey.F when ctrl:
                ShowFind(replace: false);
                break;
            case VirtualKey.H when ctrl:
                ShowFind(replace: true);
                break;
            case VirtualKey.F3:
                Find(_findBar.Query, _findBar.MatchCase, forward: !shift);
                break;
            case (VirtualKey)191 when ctrl:
                ToggleComment();
                break;
            case VirtualKey.Space when ctrl:
                ShowCompletion(force: true);
                break;
            case VirtualKey.D when ctrl && shift:
                DuplicateLine();
                break;
            case VirtualKey.Tab:
                IndentSelection(outdent: shift);
                break;
            case VirtualKey.Enter:
                NewLineWithIndent();
                break;
            case VirtualKey.Escape when _findBar.Visibility == Visibility.Visible:
                _findBar.Visibility = Visibility.Collapsed;
                break;
            default:
                return;
        }

        e.Handled = true;
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        // Outside Vim's insert mode keys are commands, so completion must not open on them.
        if (!CompletionEnabled || IsVimOutsideInsert)
        {
            return;
        }

        var c = e.Character;
        if (c == '.' || (char.IsLetter(c) && WordBeforeCaretLength() >= 1))
        {
            DispatcherQueue.TryEnqueue(() => ShowCompletion(force: false));
        }
        else if (!char.IsLetterOrDigit(c) && c != '_')
        {
            HideCompletion();
        }
    }

    private int WordBeforeCaretLength()
    {
        var caret = SelectionStart;
        var i = caret;
        while (i > 0 && SqlLexer.IsWordPart(_text[i - 1]))
        {
            i--;
        }

        return caret - i;
    }

    private void ShowCompletion(bool force)
    {
        SyncText();
        var caret = SelectionStart;
        var (start, items) = SqlCompletion.Suggest(_text, caret, _dialect, Catalog);
        var prefixLength = caret - start;
        if (items.Count == 0 || (!force && prefixLength < 2 && (start == 0 || _text[start - 1] != '.')))
        {
            HideCompletion();
            return;
        }

        if (items.Count == 1 && string.Equals(items[0].Text, _text[start..caret], StringComparison.OrdinalIgnoreCase))
        {
            HideCompletion();
            return;
        }

        _completionStart = start;
        _completionList.Items.Clear();
        foreach (var item in items)
        {
            _completionList.Items.Add(CompletionRow.Create(item, this));
        }

        _completionList.SelectedIndex = 0;
        _box.Document.Selection.GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        var origin = _box.TransformToVisual(this).TransformPoint(new Windows.Foundation.Point(rect.X, rect.Bottom));
        _completionPopup.XamlRoot = XamlRoot;
        if (_completionPopup.Parent is null && Content is Grid grid && !grid.Children.Contains(_completionPopup))
        {
            grid.Children.Add(_completionPopup);
        }

        _completionPopup.HorizontalOffset = origin.X;
        _completionPopup.VerticalOffset = origin.Y + 4;
        _completionPopup.IsOpen = true;
    }

    private void HideCompletion() => _completionPopup.IsOpen = false;

    private bool HandleCompletionKey(VirtualKey key)
    {
        switch (key)
        {
            case VirtualKey.Down:
                _completionList.SelectedIndex = Math.Min(_completionList.SelectedIndex + 1, _completionList.Items.Count - 1);
                _completionList.ScrollIntoView(_completionList.SelectedItem);
                return true;
            case VirtualKey.Up:
                _completionList.SelectedIndex = Math.Max(_completionList.SelectedIndex - 1, 0);
                _completionList.ScrollIntoView(_completionList.SelectedItem);
                return true;
            case VirtualKey.Enter or VirtualKey.Tab:
                AcceptCompletion((_completionList.SelectedItem as ListViewItem)?.Tag);
                return true;
            case VirtualKey.Escape:
                HideCompletion();
                return true;
            default:
                return false;
        }
    }

    private void AcceptCompletion(object? selected)
    {
        var item = selected as CompletionItem;
        HideCompletion();
        if (item is null)
        {
            return;
        }

        SyncText();
        var caret = SelectionStart;
        _box.Document.Selection.SetRange(Math.Min(_completionStart, caret), caret);
        InsertText(item.Text);
    }

    private (int Start, int End) SelectedLineRange()
    {
        var start = SelectionStart;
        var end = start + SelectionLength;
        var lineStart = start == 0 ? 0 : _text.LastIndexOf('\r', Math.Max(0, start - 1)) + 1;
        if (start > 0 && _text[start - 1] == '\r')
        {
            lineStart = start;
        }

        var searchFrom = end > start && end > 0 && _text[end - 1] == '\r' ? end - 1 : end;
        var lineEnd = _text.IndexOf('\r', Math.Min(searchFrom, _text.Length));
        return (lineStart, lineEnd < 0 ? _text.Length : lineEnd);
    }

    private void IndentSelection(bool outdent)
    {
        SyncText();
        if (SelectionLength == 0 && !outdent)
        {
            InsertText(Indent);
            return;
        }

        var (lineStart, lineEnd) = SelectedLineRange();
        var lines = _text[lineStart..lineEnd].Split('\r');
        for (var i = 0; i < lines.Length; i++)
        {
            if (outdent)
            {
                var remove = 0;
                while (remove < Indent.Length && remove < lines[i].Length && lines[i][remove] == ' ')
                {
                    remove++;
                }

                if (remove == 0 && lines[i].StartsWith('\t'))
                {
                    remove = 1;
                }

                lines[i] = lines[i][remove..];
            }
            else
            {
                lines[i] = Indent + lines[i];
            }
        }

        var replaced = string.Join('\r', lines);
        SetTextCore(string.Concat(_text.AsSpan(0, lineStart), replaced, _text.AsSpan(lineEnd)), lineStart, lineStart + replaced.Length, recordUndo: true);
    }

    private void NewLineWithIndent()
    {
        SyncText();
        var caret = SelectionStart;
        var lineStart = caret == 0 ? 0 : _text.LastIndexOf('\r', caret - 1) + 1;
        var indentLength = 0;
        while (lineStart + indentLength < caret && _text[lineStart + indentLength] is ' ' or '\t')
        {
            indentLength++;
        }

        var indent = _text.Substring(lineStart, indentLength);
        var trimmed = _text[lineStart..caret].TrimEnd();
        if (trimmed.EndsWith('(') || trimmed.EndsWith("BEGIN", StringComparison.OrdinalIgnoreCase))
        {
            indent += Indent;
        }

        InsertText("\r" + indent);
    }

    private void DuplicateLine()
    {
        SyncText();
        var (lineStart, lineEnd) = SelectedLineRange();
        var line = _text[lineStart..lineEnd];
        SetTextCore(_text.Insert(lineEnd, "\r" + line), lineEnd + 1, lineEnd + 1 + line.Length, recordUndo: true);
    }

    private void Find(string query, bool matchCase, bool forward)
    {
        if (string.IsNullOrEmpty(query))
        {
            return;
        }

        var comparison = matchCase ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        var normalized = query.Replace("\r\n", "\r", StringComparison.Ordinal).Replace('\n', '\r');
        int index;
        if (forward)
        {
            var from = Math.Min(SelectionStart + Math.Max(SelectionLength, 0), _text.Length);
            index = _text.IndexOf(normalized, from, comparison);
            if (index < 0)
            {
                index = _text.IndexOf(normalized, 0, comparison);
            }
        }
        else
        {
            var from = Math.Max(0, SelectionStart - 1);
            index = from > 0 ? _text.LastIndexOf(normalized, from, comparison) : -1;
            if (index < 0)
            {
                index = _text.LastIndexOf(normalized, comparison);
            }
        }

        _findBar.SetStatus(index < 0 ? "No results" : $"{CountMatches(normalized, comparison)} matches");
        if (index >= 0)
        {
            Select(index, normalized.Length);
        }
    }

    private int CountMatches(string query, StringComparison comparison)
    {
        var count = 0;
        var at = 0;
        while ((at = _text.IndexOf(query, at, comparison)) >= 0)
        {
            count++;
            at += query.Length;
        }

        return count;
    }

    private void ReplaceOne(string query, string replacement, bool matchCase)
    {
        var comparison = matchCase ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        if (SelectionLength > 0 && string.Equals(_text.Substring(SelectionStart, SelectionLength), query, comparison))
        {
            InsertText(replacement);
        }

        Find(query, matchCase, forward: true);
    }

    private void ReplaceAll(string query, string replacement, bool matchCase)
    {
        if (string.IsNullOrEmpty(query))
        {
            return;
        }

        var comparison = matchCase ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        var count = CountMatches(query, comparison);
        SetTextCore(_text.Replace(query, replacement.Replace('\n', '\r'), comparison), 0, 0, recordUndo: true);
        _findBar.SetStatus($"Replaced {count}");
    }

    private readonly record struct Palette(Color Plain, Color Keyword, Color Function, Color String, Color Number, Color Comment, Color Identifier, Color Parameter);

    /// <summary>Builds a completion entry in code; a bound template would need reflection the trimmed app avoids.</summary>
    private static class CompletionRow
    {
        public static ListViewItem Create(CompletionItem item, FrameworkElement theme)
        {
            var grid = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 2, 0, 2) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(new FontIcon { FontSize = 12, Glyph = Glyph(item.Kind), Foreground = ThemeResources.Brush(theme, "AccentTextFillColorPrimaryBrush") });
            var label = new TextBlock { Text = item.Label, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
            if (Application.Current.Resources.TryGetValue("CodeFontFamily", out var font) && font is FontFamily family)
            {
                label.FontFamily = family;
            }

            Grid.SetColumn(label, 1);
            grid.Children.Add(label);
            var detail = new TextBlock
            {
                Text = item.Detail ?? item.Kind.ToString(),
                FontSize = 11,
                MaxWidth = 150,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = ThemeResources.Brush(theme, "TextFillColorTertiaryBrush"),
            };
            Grid.SetColumn(detail, 2);
            grid.Children.Add(detail);
            return new ListViewItem { Content = grid, Tag = item, MinHeight = 28, Padding = new Thickness(8, 0, 8, 0) };
        }

        private static string Glyph(CompletionKind kind) => kind switch
        {
            CompletionKind.Keyword => "\uE943",
            CompletionKind.Function => "\uE8EF",
            CompletionKind.Schema => "\uE8B7",
            CompletionKind.Table => "\uE80A",
            CompletionKind.View => "\uE890",
            CompletionKind.Column => "\uE8A9",
            _ => "\uE8C8",
        };
    }
}