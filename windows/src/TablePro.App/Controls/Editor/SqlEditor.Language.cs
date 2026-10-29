using System.Collections.Immutable;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.App.Helpers;
using TablePro.Core.Editing.MultiCursor;
using TablePro.Core.Sql;
using TablePro.Core.Sql.Analysis;
using Windows.Foundation;
using Windows.System;

namespace TablePro.App.Controls.Editor;

/// <summary>
/// Language features over <see cref="SqlAnalyzer"/>: squiggles for diagnostics, a hover card, go to definition (F12
/// and Ctrl+click), rename by selecting every reference as carets, and stepping through problems (F8).
/// </summary>
/// <remarks>
/// Analysis runs on the thread pool half a second after typing stops, on a snapshot of the text, the caret, the
/// dialect and the catalog; a newer edit cancels it. Until it lands, the last result's squiggles are moved through the
/// edit so they stay on their text. A hover or a command that needs the current text analyzes it on the spot, which
/// costs a few milliseconds on a statement-sized script.
/// </remarks>
public sealed partial class SqlEditor
{
    private const double SquiggleHeight = 2;
    private const double SquiggleStep = 2;
    private const double HoverMaxWidth = 520;
    private const string ErrorGlyph = "\xEA39";
    private const string WarningGlyph = "\xE7BA";

    private static readonly object ErrorTag = new();
    private static readonly object WarningTag = new();

    private readonly List<Polyline> _squiggles = [];
    private readonly Popup _hoverPopup = new() { IsLightDismissEnabled = false };
    private DispatcherQueueTimerHolder? _analysisTimer;
    private DispatcherQueueTimerHolder? _hoverTimer;
    private SqlAnalysis _analysis = SqlAnalysis.Empty;
    private CompletionCatalog _analyzedCatalog = CompletionCatalog.Empty;
    private ImmutableArray<SqlDiagnostic> _diagnostics = [];
    private CancellationTokenSource? _analysisCancellation;
    private Canvas? _squiggleLayer;
    private Rectangle? _linkUnderline;
    private bool _squiggleUpdateQueued;
    private bool _pointerInside;
    private bool _diagnosticsEnabled = true;
    private bool _languageScrollHooked;
    private bool _hoverFromKeyboard;
    private Point _pointer;
    private SqlTextRange _hoverAnchor;

    /// <summary>
    /// F12 or Ctrl+click on a table, a view or one of their columns: the workspace opens the table's structure. An
    /// alias or a common table expression is declared in the text, so the editor jumps there itself.
    /// </summary>
    public event EventHandler<SqlCatalogDefinition>? DefinitionRequested;

    /// <summary>Whether squiggles show. Hover, go to definition and rename work either way.</summary>
    public bool DiagnosticsEnabled
    {
        get => _diagnosticsEnabled;
        set
        {
            if (_diagnosticsEnabled == value)
            {
                return;
            }

            _diagnosticsEnabled = value;
            ShowDiagnostics(value ? _analysis.DiagnosticsMappedTo(_text) : []);
            ScheduleAnalysis();
        }
    }

    private void InitializeLanguage()
    {
        _analysisTimer = new DispatcherQueueTimerHolder(this, TimeSpan.FromMilliseconds(500), RunAnalysis);
        _hoverTimer = new DispatcherQueueTimerHolder(this, TimeSpan.FromMilliseconds(500), ShowHoverAtPointer);
        TextChanged += (_, _) => OnLanguageTextChanged();
        _box.SelectionChanged += (_, _) => OnLanguageSelectionChanged();
        _box.AddHandler(PointerMovedEvent, new PointerEventHandler(OnLanguagePointerMoved), handledEventsToo: true);
        _box.AddHandler(PointerPressedEvent, new PointerEventHandler(OnLanguagePointerPressed), handledEventsToo: true);
        _box.AddHandler(KeyUpEvent, new KeyEventHandler(OnLanguageKeyUp), handledEventsToo: true);
        _box.PointerEntered += (_, _) => _pointerInside = true;
        _box.PointerExited += (_, _) =>
        {
            _pointerInside = false;
            _hoverTimer?.Stop();
            HideLink();
            if (!_hoverFromKeyboard)
            {
                HideHover();
            }
        };
        _box.LostFocus += (_, _) => HideHover();
        _box.SizeChanged += (_, _) => QueueSquiggleUpdate();
        _box.Loaded += (_, _) =>
        {
            // Loaded comes again each time the tab is shown; the scroller is the same one.
            if (!_languageScrollHooked && Scroller is { } scroller)
            {
                _languageScrollHooked = true;
                scroller.ViewChanged += (_, _) =>
                {
                    HideLink();
                    QueueSquiggleUpdate();

                    // A card the keyboard asked for follows its text, since the jump that opened it may scroll.
                    if (_hoverFromKeyboard && _hoverPopup.IsOpen)
                    {
                        PlaceHover();
                    }
                    else
                    {
                        HideHover();
                    }
                };
            }
        };
        ActualThemeChanged += (_, _) => RestyleLanguageVisuals();
    }

    /// <summary>The dialect, the catalog or the setting changed: what was found may no longer hold.</summary>
    private void ScheduleAnalysis() => _analysisTimer?.Restart();

    private void OnLanguageTextChanged()
    {
        HideHover();
        HideLink();
        if (_diagnosticsEnabled)
        {
            // The last result stays on its text, so squiggles do not blink off and on with every keystroke.
            ShowDiagnostics(_analysis.DiagnosticsMappedTo(_text));
        }

        _analysisTimer?.Restart();
    }

    private void OnLanguageSelectionChanged()
    {
        // A string or bracket is quiet only while the caret is inside it; leaving it is worth a fresh look.
        if (_diagnosticsEnabled && IsAnalysisCurrent() && _analysis.CaretChangesResult(Math.Min(_box.Document.Selection.StartPosition, _text.Length)))
        {
            _analysisTimer?.Restart();
        }
    }

    private async void RunAnalysis()
    {
        if (!_diagnosticsEnabled)
        {
            return;
        }

        SyncText();
        if (IsAnalysisCurrent() && !_analysis.CaretChangesResult(SelectionStart))
        {
            return;
        }

        // Past the limit there is nothing to show; hover and go to definition analyze on demand.
        if (_text.Length > SqlAnalyzer.MaximumDiagnosedLength)
        {
            ShowDiagnostics([]);
            return;
        }

        _analysisCancellation?.Cancel();
        using var cancellation = new CancellationTokenSource();
        _analysisCancellation = cancellation;
        var (text, dialect, catalog, caret) = (_text, _dialect, Catalog, SelectionStart);
        SqlAnalysis analysis;
        try
        {
            analysis = await Task.Run(() => SqlAnalyzer.Analyze(text, dialect, catalog, caret, cancellation.Token), cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        finally
        {
            if (ReferenceEquals(_analysisCancellation, cancellation))
            {
                _analysisCancellation = null;
            }
        }

        // A newer pass was asked for while this one ran; its result is the one to show.
        if (!cancellation.IsCancellationRequested)
        {
            Adopt(analysis, catalog);
        }
    }

    private bool IsAnalysisCurrent() =>
        ReferenceEquals(_analysis.Dialect, _dialect) && ReferenceEquals(_analyzedCatalog, Catalog)
        && string.Equals(_analysis.Text, _text, StringComparison.Ordinal);

    /// <summary>An analysis of the text as it is now, made on the spot if the last one is out of date.</summary>
    private SqlAnalysis CurrentAnalysis()
    {
        SyncText();
        if (!IsAnalysisCurrent())
        {
            _analysisCancellation?.Cancel();
            _analysisTimer?.Stop();
            Adopt(SqlAnalyzer.Analyze(_text, _dialect, Catalog, SelectionStart), Catalog);
        }

        return _analysis;
    }

    private void Adopt(SqlAnalysis analysis, CompletionCatalog catalog)
    {
        _analysis = analysis;
        _analyzedCatalog = catalog;
        ShowDiagnostics(_diagnosticsEnabled ? analysis.DiagnosticsMappedTo(_text) : []);
    }

    private void ShowDiagnostics(ImmutableArray<SqlDiagnostic> diagnostics)
    {
        if (diagnostics.IsEmpty && _diagnostics.IsEmpty)
        {
            return;
        }

        _diagnostics = diagnostics;
        QueueSquiggleUpdate();
    }

    private void GoToDefinition()
    {
        var caret = SelectionStart;
        var symbol = CurrentAnalysis().SymbolAt(caret);
        if (symbol?.Definition is { } definition)
        {
            NavigateTo(definition);
            return;
        }

        ShowNote(caret, symbol is null ? Strings.Get("Editor/NoSymbolAtCaret") : Strings.Format("Editor/NoDefinitionFound", symbol.Name));
    }

    private void NavigateTo(SqlDefinition definition)
    {
        switch (definition)
        {
            case SqlTextDefinition text:
                Select(text.Start, text.Length);
                Announce(Strings.Format("Editor/WentTo", _text.Substring(text.Start, Math.Min(text.Length, _text.Length - text.Start))));
                break;
            case SqlCatalogDefinition table:
                DefinitionRequested?.Invoke(this, table);
                break;
        }
    }

    /// <summary>
    /// Selects every reference to the name at the caret as one caret each, so what is typed next renames them all,
    /// with the undo and the Escape of any multi-caret edit.
    /// </summary>
    private void SelectReferences()
    {
        if (IsVimOutsideInsert)
        {
            // Vim's normal mode acts at one caret; the selections would be gone at the next motion.
            ShowNote(SelectionStart, Strings.Get("Editor/RenameNeedsInsertMode"));
            return;
        }

        SyncCaretsWithView();
        var caret = SelectionStart;
        var references = CurrentAnalysis().ReferencesAt(caret);
        if (references.Count == 0)
        {
            ShowNote(caret, Strings.Get("Editor/NoSymbolAtCaret"));
            return;
        }

        var primary = 0;
        var carets = new Caret[references.Count];
        for (var i = 0; i < references.Count; i++)
        {
            var range = references[i];
            carets[i] = new Caret(range.Start, range.End);
            if (range.Touches(caret))
            {
                primary = i;
            }
        }

        HideCompletion();
        HideSuggestion();
        _carets.SetCarets(carets, primary);
        Announce(Strings.Plural("Editor/ReferencesSelected", references.Count));
    }

    private void GoToDiagnostic(bool forward)
    {
        CurrentAnalysis();
        if (SqlAnalysis.Next(_diagnostics, SelectionStart, forward) is not { } diagnostic)
        {
            ShowNote(SelectionStart, Strings.Get("Editor/NoProblems"));
            return;
        }

        Select(diagnostic.Start, 0);
        if (_analysis.HoverAt(diagnostic.Start) is { } hover)
        {
            ShowHover(hover.Range, hover.Diagnostics, hover.Title, hover.Detail, note: null, fromKeyboard: true);
        }

        Announce(diagnostic.Severity == SqlDiagnosticSeverity.Error
            ? Strings.Format("Editor/ErrorAnnouncement", diagnostic.Message)
            : Strings.Format("Editor/WarningAnnouncement", diagnostic.Message));
    }

    private void ShowQuickInfo()
    {
        var caret = SelectionStart;
        if (CurrentAnalysis().HoverAt(caret, atCaret: true) is not { } hover)
        {
            ShowNote(caret, Strings.Get("Editor/NothingAtCaret"));
            return;
        }

        var diagnostics = Shown(hover.Diagnostics);
        ShowHover(hover.Range, diagnostics, hover.Title, hover.Detail, note: null, fromKeyboard: true);
        Announce(string.Join(". ", diagnostics.Select(d => d.Message).Append(hover.Title ?? string.Empty).Where(s => s.Length > 0)));
    }

    /// <summary>The diagnostics a hover may show: none while squiggles are off, so the card never reports what the text does not.</summary>
    private IReadOnlyList<SqlDiagnostic> Shown(IReadOnlyList<SqlDiagnostic> diagnostics) => _diagnosticsEnabled ? diagnostics : [];

    private void OnLanguagePointerMoved(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_box);
        _pointer = point.Position;
        _pointerInside = true;
        if (point.Properties.IsLeftButtonPressed || point.Properties.IsRightButtonPressed)
        {
            _hoverTimer?.Stop();
            HideHover();
            return;
        }

        UpdateLink(e.KeyModifiers == VirtualKeyModifiers.Control);
        if (_hoverPopup.IsOpen && !_hoverFromKeyboard && CharacterAt(_pointer) is { } offset && _hoverAnchor.Contains(offset))
        {
            return;
        }

        // A card the keyboard opened stays until a key or a click; the pointer only replaces it by resting on something else.
        if (!_hoverFromKeyboard)
        {
            HideHover();
        }

        _hoverTimer?.Restart();
    }

    private void OnLanguagePointerPressed(object sender, PointerRoutedEventArgs e)
    {
        _hoverTimer?.Stop();
        HideHover();
        var point = e.GetCurrentPoint(_box);
        if (!point.Properties.IsLeftButtonPressed || e.KeyModifiers != VirtualKeyModifiers.Control || IsOnScrollBar(e.OriginalSource)
            || CharacterAt(point.Position) is not { } offset || CurrentAnalysis().SymbolAt(offset, atCaret: false)?.Definition is not { } definition)
        {
            return;
        }

        HideLink();

        // RichEdit places the caret for this click after the handler returns; navigating afterwards keeps the jump's selection.
        DispatcherQueue.TryEnqueueLogged(() => NavigateTo(definition));
    }

    private void OnLanguageKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Control)
        {
            HideLink();
        }
    }

    /// <summary>Ctrl went down: the name under a resting pointer becomes a link, as Ctrl+hover does.</summary>
    private void OnLanguageControlKeyDown()
    {
        if (_pointerInside)
        {
            UpdateLink(ctrl: true);
        }
    }

    private void ShowHoverAtPointer()
    {
        if (!_pointerInside || _completionPopup.IsOpen || CharacterAt(_pointer) is not { } offset)
        {
            return;
        }

        if (CurrentAnalysis().HoverAt(offset) is not { } hover)
        {
            return;
        }

        var diagnostics = Shown(hover.Diagnostics);
        if (diagnostics.Count == 0 && hover.Title is null)
        {
            return;
        }

        ShowHover(hover.Range, diagnostics, hover.Title, hover.Detail, note: null, fromKeyboard: false);
    }

    /// <summary>The character under a point of the box, or null over blank space past a line's end or below the text.</summary>
    private int? CharacterAt(Point point)
    {
        var document = _box.Document;
        var position = Math.Clamp(document.GetRangeFromPoint(point, PointOptions.ClientCoordinates).StartPosition, 0, _text.Length);

        // The point resolves to the nearest caret position, which is after the character when the pointer is on its right half.
        for (var candidate = position; candidate >= Math.Max(0, position - 1); candidate--)
        {
            if (candidate >= _text.Length || _text[candidate] == '\r')
            {
                continue;
            }

            document.GetRange(candidate, candidate + 1).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
            if (point.X >= rect.X - 0.5 && point.X <= rect.X + rect.Width + 0.5 && point.Y >= rect.Y && point.Y <= rect.Y + Math.Max(rect.Height, LineHeightPixels))
            {
                return candidate;
            }
        }

        return null;
    }

    private void UpdateLink(bool ctrl)
    {
        if (!ctrl || CharacterAt(_pointer) is not { } offset || CurrentAnalysis().SymbolAt(offset, atCaret: false) is not { Definition: not null } symbol)
        {
            HideLink();
            return;
        }

        EnsureSquiggleLayer();
        if (_squiggleLayer is null)
        {
            return;
        }

        if (_linkUnderline is null)
        {
            _linkUnderline = new Rectangle { Height = 1, IsHitTestVisible = false };
            _squiggleLayer.Children.Add(_linkUnderline);
        }

        _linkUnderline.Fill = ThemeResources.Brush(this, "AccentTextFillColorPrimaryBrush");
        var range = symbol.Range;
        _box.Document.GetRange(range.Start, Math.Min(range.End, _text.Length)).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        var origin = _box.TransformToVisual(_squiggleLayer).TransformPoint(new Point(rect.X, rect.Y + Math.Max(rect.Height, LineHeightPixels) - 2));
        Canvas.SetLeft(_linkUnderline, origin.X);
        Canvas.SetTop(_linkUnderline, origin.Y);
        _linkUnderline.Width = Math.Max(1, rect.Width);
        _linkUnderline.Visibility = Visibility.Visible;
    }

    private void HideLink()
    {
        if (_linkUnderline is not null)
        {
            _linkUnderline.Visibility = Visibility.Collapsed;
        }
    }

    private void ShowNote(int offset, string note)
    {
        ShowHover(new SqlTextRange(Math.Min(offset, _text.Length), 0), [], null, null, note, fromKeyboard: true);
        Announce(note);
    }

    /// <summary>The hover card: the diagnostics first, as the reason it opened, then what the name means.</summary>
    private void ShowHover(SqlTextRange anchor, IReadOnlyList<SqlDiagnostic> diagnostics, string? title, string? detail, string? note, bool fromKeyboard)
    {
        var panel = new StackPanel { Spacing = 6, MaxWidth = HoverMaxWidth };
        var code = Application.Current.Resources.TryGetValue("CodeFontFamily", out var font) && font is FontFamily family ? family : null;
        foreach (var diagnostic in diagnostics)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var isError = diagnostic.Severity == SqlDiagnosticSeverity.Error;
            row.Children.Add(new FontIcon
            {
                Glyph = isError ? ErrorGlyph : WarningGlyph,
                FontSize = 14,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 1, 0, 0),
                Foreground = ThemeResources.Brush(this, isError ? "SystemFillColorCriticalBrush" : "SystemFillColorCautionBrush"),
            });
            var message = new TextBlock { Text = diagnostic.Message, TextWrapping = TextWrapping.Wrap, FontSize = 12 };
            Grid.SetColumn(message, 1);
            row.Children.Add(message);
            panel.Children.Add(row);
        }

        if (title is not null)
        {
            var heading = new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
            if (code is not null)
            {
                heading.FontFamily = code;
            }

            panel.Children.Add(heading);
        }

        if (detail is not null)
        {
            var body = new TextBlock
            {
                Text = detail,
                FontSize = 11,
                TextWrapping = TextWrapping.NoWrap,
                Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush"),
            };
            if (code is not null)
            {
                body.FontFamily = code;
            }

            panel.Children.Add(body);
        }

        if (note is not null)
        {
            panel.Children.Add(new TextBlock { Text = note, FontSize = 12, Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush") });
        }

        if (panel.Children.Count == 0)
        {
            return;
        }

        var card = new Border
        {
            Child = panel,
            Padding = new Thickness(10, 8, 10, 8),
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
            Background = ThemeResources.Brush(this, "AcrylicInAppFillColorDefaultBrush"),
            BorderBrush = ThemeResources.Brush(this, "SurfaceStrokeColorFlyoutBrush"),
            Shadow = new ThemeShadow(),
            Translation = new System.Numerics.Vector3(0, 0, 16),
        };
        _hoverPopup.Child = card;
        _hoverPopup.XamlRoot = XamlRoot;
        if (_hoverPopup.Parent is null && Content is Grid grid && !grid.Children.Contains(_hoverPopup))
        {
            grid.Children.Add(_hoverPopup);
        }

        _hoverAnchor = anchor;
        _hoverFromKeyboard = fromKeyboard;
        card.Measure(new Size(HoverMaxWidth + 24, double.PositiveInfinity));
        PlaceHover();
    }

    /// <summary>Puts the card under its text, or above it when it would run past the editor's bottom edge, as tooltips flip.</summary>
    private void PlaceHover()
    {
        if (_hoverPopup.Child is not FrameworkElement card)
        {
            return;
        }

        var start = Math.Min(_hoverAnchor.Start, _text.Length);
        var end = Math.Min(Math.Max(_hoverAnchor.End, start), _text.Length);
        _box.Document.GetRange(start, end).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        var lineHeight = Math.Max(rect.Height, LineHeightPixels);
        var line = _box.TransformToVisual(this).TransformPoint(new Point(rect.X, rect.Y));
        if (line.Y + lineHeight < 0 || line.Y > ActualHeight)
        {
            // The text scrolled out of view; a card pointing at nothing is worse than none.
            HideHover();
            return;
        }

        var height = card.DesiredSize.Height;
        var below = line.Y + lineHeight + 2;
        var above = line.Y - 2 - height;
        _hoverPopup.HorizontalOffset = Math.Max(0, Math.Min(line.X, ActualWidth - card.DesiredSize.Width));
        _hoverPopup.VerticalOffset = below + height > ActualHeight && above >= 0 ? above : below;
        _hoverPopup.IsOpen = true;
    }

    private void HideHover()
    {
        if (_hoverPopup.IsOpen)
        {
            _hoverPopup.IsOpen = false;
        }

        _hoverFromKeyboard = false;
    }

    /// <summary>Tells Narrator what a keyboard command found, since the hover card is not in the focus order.</summary>
    private void Announce(string message)
    {
        if (message.Length > 0 && (FrameworkElementAutomationPeer.FromElement(_box) ?? FrameworkElementAutomationPeer.CreatePeerForElement(_box)) is { } peer)
        {
            peer.RaiseNotificationEvent(
                AutomationNotificationKind.ActionCompleted,
                AutomationNotificationProcessing.ImportantMostRecent,
                message,
                "TablePro.SqlEditor.Language");
        }
    }

    private void QueueSquiggleUpdate()
    {
        if (_squiggleUpdateQueued || DispatcherQueue is null)
        {
            return;
        }

        // Low priority runs after RichEdit has laid out the edit, so the rectangles are measured on the new text.
        _squiggleUpdateQueued = true;
        DispatcherQueue.TryEnqueueLogged(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            _squiggleUpdateQueued = false;
            UpdateSquiggles();
        });
    }

    private void EnsureSquiggleLayer()
    {
        if (_squiggleLayer is not null || Content is not Grid root)
        {
            return;
        }

        _squiggleLayer = new Canvas { IsHitTestVisible = false };
        _squiggleLayer.SizeChanged += (_, args) => _squiggleLayer.Clip = new RectangleGeometry
        {
            Rect = new Rect(0, 0, args.NewSize.Width, args.NewSize.Height),
        };
        Grid.SetRow(_squiggleLayer, 1);
        Grid.SetColumn(_squiggleLayer, 1);
        root.Children.Add(_squiggleLayer);
    }

    /// <summary>Draws the squiggles of the visible lines only, from a pool of shapes, as the caret overlay does.</summary>
    private void UpdateSquiggles()
    {
        if (_squiggleLayer is null && _diagnostics.IsEmpty)
        {
            return;
        }

        EnsureSquiggleLayer();
        var used = 0;
        if (!_diagnostics.IsEmpty && _squiggleLayer is not null)
        {
            // Wrapped lines break the arithmetic of the visible range, so with word wrap every diagnostic is measured.
            var (firstLine, lastLine) = WordWrap ? (0, Math.Max(0, _lineCount - 1)) : VisibleLineRange();
            var visibleStart = _carets.LineSpan(firstLine).Start;
            var visibleEnd = _carets.LineSpan(Math.Min(lastLine + 1, Math.Max(0, _lineCount - 1))).End;
            foreach (var diagnostic in _diagnostics)
            {
                if (diagnostic.Start > visibleEnd)
                {
                    break;
                }

                if (diagnostic.End >= visibleStart)
                {
                    used = DrawSquiggle(diagnostic, used);
                }
            }
        }

        for (var i = used; i < _squiggles.Count; i++)
        {
            _squiggles[i].Visibility = Visibility.Collapsed;
        }
    }

    private int DrawSquiggle(SqlDiagnostic diagnostic, int used)
    {
        var start = Math.Min(diagnostic.Start, _text.Length);
        var end = Math.Min(diagnostic.End, _text.Length);
        var lastLine = _carets.LineOf(end);
        for (var line = _carets.LineOf(start); line <= lastLine; line++)
        {
            var (lineStart, lineEnd) = _carets.LineSpan(line);
            var segmentStart = Math.Max(start, lineStart);
            var segmentEnd = Math.Min(end, lineEnd);
            if (segmentEnd <= segmentStart && line != lastLine)
            {
                continue;
            }

            _box.Document.GetRange(segmentStart, Math.Max(segmentStart, segmentEnd)).GetRect(PointOptions.ClientCoordinates, out var rect, out _);

            // A diagnostic on nothing visible, such as one at the very end, still gets a character's width so it can be seen.
            var width = segmentEnd > segmentStart && rect.Width > 1 ? rect.Width : CharacterWidth(0, 0);
            var origin = _box.TransformToVisual(_squiggleLayer).TransformPoint(new Point(rect.X, rect.Y + Math.Max(rect.Height, LineHeightPixels) - SquiggleHeight - 1));
            var shape = Squiggle(used++, diagnostic.Severity);
            shape.Points = Wave(width);
            Canvas.SetLeft(shape, origin.X);
            Canvas.SetTop(shape, origin.Y);
            shape.Visibility = Visibility.Visible;
        }

        return used;
    }

    private static PointCollection Wave(double width)
    {
        var points = new PointCollection();
        var steps = Math.Max(2, (int)Math.Ceiling(width / SquiggleStep));
        for (var i = 0; i <= steps; i++)
        {
            points.Add(new Point(Math.Min(i * SquiggleStep, width), i % 2 == 0 ? SquiggleHeight : 0));
        }

        return points;
    }

    private Polyline Squiggle(int index, SqlDiagnosticSeverity severity)
    {
        if (index == _squiggles.Count)
        {
            var created = new Polyline { StrokeThickness = 1, IsHitTestVisible = false };
            _squiggles.Add(created);
            _squiggleLayer!.Children.Add(created);
        }

        var shape = _squiggles[index];
        var tag = severity == SqlDiagnosticSeverity.Error ? ErrorTag : WarningTag;
        if (!ReferenceEquals(shape.Tag, tag))
        {
            shape.Tag = tag;
            StyleSquiggle(shape);
        }

        return shape;
    }

    private void StyleSquiggle(Polyline shape) =>
        shape.Stroke = ThemeResources.Brush(this, ReferenceEquals(shape.Tag, ErrorTag) ? "SystemFillColorCriticalBrush" : "SystemFillColorCautionBrush");

    private void RestyleLanguageVisuals()
    {
        foreach (var shape in _squiggles)
        {
            StyleSquiggle(shape);
        }

        HideHover();
        HideLink();
    }
}
