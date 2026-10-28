using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.App.Helpers;
using TablePro.Core.Editing.MultiCursor;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;

namespace TablePro.App.Controls.Editor;

/// <summary>
/// Multiple carets: the model in TablePro.Core.Editing.MultiCursor drives the edits, RichEdit shows the primary caret
/// as its own selection, and the other carets and selections are drawn over the text.
/// </summary>
/// <remarks>
/// RichEdit has one selection, so with several carets the editor takes every key that moves or edits and runs it at
/// each caret through the model. What RichEdit still does by itself, typing a character, a dead key or an input
/// method's text, lands at the primary caret; <see cref="TryRepeatAtCarets"/> takes it back and makes it at every caret
/// as one undo step. A click, a find or any whole-text edit returns to one caret, as Escape does.
/// </remarks>
public sealed partial class SqlEditor
{
    private const double CaretWidth = 2;
    private const double SelectionOpacity = 0.35;

    private static readonly object CaretTag = new();
    private static readonly object SelectionTag = new();

    private readonly MultiCursorModel _carets;
    private readonly List<Rectangle> _caretShapes = [];
    private Canvas? _caretLayer;
    private int _applyingCarets;
    private bool _caretSyncQueued;
    private bool _composing;
    private bool _boxSelecting;
    private (int Line, int Column) _boxAnchor;

    /// <summary>How many carets the editor has: more than one after Ctrl+D, Ctrl+Shift+L, Ctrl+Alt+Up or Down, Alt+click or Alt+Shift+drag.</summary>
    public int CaretCount => _carets.Count;

    private bool HasExtraCarets => _carets.HasMultipleCarets;

    private void InitializeCarets()
    {
        _carets.Changed += (_, _) => OnCaretsChanged();
        _box.SelectionChanged += (_, _) => QueueCaretSync();
        _box.AddHandler(PointerPressedEvent, new PointerEventHandler(OnCaretPointerPressed), handledEventsToo: true);
        _box.AddHandler(PointerMovedEvent, new PointerEventHandler(OnCaretPointerMoved), handledEventsToo: true);
        _box.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => _boxSelecting = false), handledEventsToo: true);
        _box.PointerCaptureLost += (_, _) => _boxSelecting = false;
        _box.TextCompositionStarted += (_, _) => _composing = true;
        _box.TextCompositionEnded += (_, _) =>
        {
            _composing = false;
            QueueCaretSync();
        };
        _box.GotFocus += (_, _) => UpdateCaretOverlay();
        _box.LostFocus += (_, _) => UpdateCaretOverlay();
        _box.SizeChanged += (_, _) => UpdateCaretOverlay();
        _box.Loaded += (_, _) =>
        {
            if (Scroller is { } scroller)
            {
                scroller.ViewChanged += (_, _) => UpdateCaretOverlay();
            }
        };
        ActualThemeChanged += (_, _) => RestyleCaretShapes();
    }

    /// <summary>The selection RichEdit shows, as anchor and active end.</summary>
    private (int Anchor, int Active) ViewSelection()
    {
        var selection = _box.Document.Selection;
        var start = Math.Min(selection.StartPosition, _text.Length);
        var end = Math.Min(selection.EndPosition, _text.Length);
        return selection.Options.HasFlag(SelectionOptions.StartActive) ? (end, start) : (start, end);
    }

    /// <summary>One caret, where RichEdit's selection is: after an edit that replaced the whole text, a find or an undo.</summary>
    private void ResetCaretsToView()
    {
        var (anchor, active) = ViewSelection();
        _carets.Reset(anchor, active);
    }

    /// <summary>Back to the primary caret before an edit that only knows RichEdit's one selection.</summary>
    private void CollapseCarets() => _carets.CollapseToPrimary();

    private void QueueCaretSync()
    {
        if (_applyingCarets > 0 || _boxSelecting || _caretSyncQueued)
        {
            return;
        }

        // Deferred, so a pointer handler sees the carets as they were before RichEdit moved its selection for the click.
        _caretSyncQueued = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            _caretSyncQueued = false;
            SyncCaretsWithView();
        });
    }

    /// <summary>
    /// Brings the carets up to what RichEdit did by itself: text typed at the primary caret is repeated at the others,
    /// and a click or a move RichEdit made returns to one caret there.
    /// </summary>
    private void SyncCaretsWithView()
    {
        if (_applyingCarets > 0 || _boxSelecting)
        {
            return;
        }

        SyncText();
        SyncCaretSelectionWithView();
    }

    /// <summary>The selection half of <see cref="SyncCaretsWithView"/>, which reads no text, for a check before every key.</summary>
    private void SyncCaretSelectionWithView()
    {
        var (anchor, active) = ViewSelection();
        var primary = _carets.Primary;
        if (Math.Min(anchor, active) == primary.Start && Math.Max(anchor, active) == primary.End)
        {
            return;
        }

        _carets.Reset(anchor, active);
    }

    /// <summary>
    /// Repeats at every caret an edit RichEdit made at the primary one: the document is put back and the edit made
    /// through the model, so all carets change in one undo step. Returns false when the edit is not one the other
    /// carets can repeat, such as a paste RichEdit made itself.
    /// </summary>
    private bool TryRepeatAtCarets(string edited)
    {
        var old = _text;
        var primary = _carets.Primary;
        var start = Math.Min(primary.Start, old.Length);
        var end = Math.Min(primary.End, old.Length);
        var tail = old.Length - end;
        if (edited.Length < tail || !edited.AsSpan(edited.Length - tail).SequenceEqual(old.AsSpan(end)))
        {
            return false;
        }

        var prefix = Math.Min(edited.AsSpan().CommonPrefixLength(old), start);
        var insertedEnd = edited.Length - tail;
        if (insertedEnd < prefix)
        {
            return false;
        }

        // A dead key or an input method may replace characters it typed just before the caret.
        var before = start - prefix;
        if (!_carets.CanReplaceBeforeCarets(old.AsSpan(prefix, before)))
        {
            return false;
        }

        _suppress = true;
        _applyingCarets++;
        try
        {
            _box.Document.GetRange(prefix, insertedEnd).SetText(TextSetOptions.None, old[prefix..end]);
        }
        finally
        {
            _applyingCarets--;
            _suppress = false;
        }

        _carets.ReplaceAroundCarets(before, edited[prefix..insertedEnd]);
        return true;
    }

    /// <summary>The model's edits, applied through RichEdit ranges so formatting and scroll stay put, as one undo step.</summary>
    private void ApplyCaretEdits(IReadOnlyList<TextEdit> edits, MultiCursorEditKind kind)
    {
        PushUndo(force: kind == MultiCursorEditKind.Command);
        _suppress = true;
        _applyingCarets++;
        try
        {
            var document = _box.Document;
            document.BatchDisplayUpdates();

            // Last edit first, so the earlier offsets still point where the model meant.
            for (var i = edits.Count - 1; i >= 0; i--)
            {
                var edit = edits[i];
                document.GetRange(edit.Start, edit.End).SetText(TextSetOptions.None, edit.Text);
            }

            document.ApplyDisplayUpdates();
            _text = ReadDocument();
        }
        finally
        {
            _applyingCarets--;
            _suppress = false;
        }

        UpdateGutter();
        HideSuggestion();
        _highlightTimer.Restart();
        TextChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnCaretsChanged()
    {
        ShowPrimaryCaret();
        if (HasExtraCarets)
        {
            // Completion and suggestions act on the text around one caret, which the other carets' text need not match.
            HideCompletion();
            HideSuggestion();
        }

        UpdateCaretOverlay();
    }

    /// <summary>Puts RichEdit's selection on the primary caret and scrolls to it.</summary>
    private void ShowPrimaryCaret()
    {
        var primary = _carets.Primary;
        var length = _text.Length;
        var anchor = Math.Min(primary.Anchor, length);
        var active = Math.Min(primary.Active, length);
        var selection = _box.Document.Selection;
        var reversed = selection.Options.HasFlag(SelectionOptions.StartActive);
        if (selection.StartPosition == Math.Min(anchor, active) && selection.EndPosition == Math.Max(anchor, active)
            && (anchor == active || reversed == (active < anchor)))
        {
            return;
        }

        _applyingCarets++;
        try
        {
            // ITextRange.SetRange takes the anchor first and the active end second, as TOM's SetRange does.
            selection.SetRange(anchor, active);
            selection.ScrollIntoView(PointOptions.None);
        }
        finally
        {
            _applyingCarets--;
        }
    }

    /// <summary>Routes a key to the carets. Returns true when the key is done with.</summary>
    private bool TryHandleCaretKey(VirtualKey key, bool ctrl, bool shift, bool alt)
    {
        switch (key)
        {
            case VirtualKey.D when ctrl && !shift && !alt:
                return RunCaretCommand(static c => c.AddNextOccurrence());
            case VirtualKey.L when ctrl && shift && !alt:
                return RunCaretCommand(static c => c.SelectAllOccurrences());
            case VirtualKey.Up when ctrl && alt && !shift:
                return RunCaretCommand(static c => c.AddCaretAbove());
            case VirtualKey.Down when ctrl && alt && !shift:
                return RunCaretCommand(static c => c.AddCaretBelow());
        }

        if (!HasExtraCarets)
        {
            return false;
        }

        SyncCaretsWithView();
        if (!HasExtraCarets)
        {
            return false;
        }

        switch (key)
        {
            case VirtualKey.Escape when !ctrl && !shift && !alt:
                CollapseCarets();
                return true;
            case VirtualKey.Left when !alt:
                _carets.Move(ctrl ? CaretMotion.WordLeft : CaretMotion.Left, shift);
                return true;
            case VirtualKey.Right when !alt:
                _carets.Move(ctrl ? CaretMotion.WordRight : CaretMotion.Right, shift);
                return true;
            case VirtualKey.Up when !alt && !ctrl:
                _carets.Move(CaretMotion.Up, shift);
                return true;
            case VirtualKey.Down when !alt && !ctrl:
                _carets.Move(CaretMotion.Down, shift);
                return true;
            case VirtualKey.Home when !alt:
                _carets.Move(ctrl ? CaretMotion.DocumentStart : CaretMotion.SmartLineStart, shift);
                return true;
            case VirtualKey.End when !alt:
                _carets.Move(ctrl ? CaretMotion.DocumentEnd : CaretMotion.LineEnd, shift);
                return true;
            case VirtualKey.Back when !alt:
                _carets.Backspace(word: ctrl);
                return true;
            case VirtualKey.Delete when shift && !ctrl && !alt:
            case VirtualKey.X when ctrl && !shift && !alt:
                CutSelection();
                return true;
            case VirtualKey.Delete when !alt:
                _carets.Delete(word: ctrl);
                return true;
            case VirtualKey.Enter when !ctrl && !alt:
                _carets.InsertLineBreak(Indent, OpensBlock);
                return true;
            case VirtualKey.Tab when !ctrl && !alt && !shift:
                _carets.Type(Indent);
                return true;
            case VirtualKey.C when ctrl && !shift && !alt:
            case VirtualKey.Insert when ctrl && !shift && !alt:
                CopySelection();
                return true;
            case VirtualKey.V when ctrl && !shift && !alt:
            case VirtualKey.Insert when shift && !ctrl && !alt:
                PasteAsync();
                return true;
            case VirtualKey.A when ctrl && !shift && !alt:
            case VirtualKey.PageUp or VirtualKey.PageDown:
            case VirtualKey.Tab when shift:
                // Select All, paging and outdenting act on one selection; RichEdit and the editor do them after the collapse.
                CollapseCarets();
                return false;
            default:
                return false;
        }
    }

    /// <summary>The block-opening rule Return applies with one caret, so every caret indents alike.</summary>
    private static bool OpensBlock(string lineBeforeCaret) =>
        lineBeforeCaret.EndsWith('(') || lineBeforeCaret.EndsWith("BEGIN", StringComparison.OrdinalIgnoreCase);

    private bool RunCaretCommand(Func<MultiCursorModel, bool> command)
    {
        // Vim's normal mode is a mode without carets to add to; Vim takes Ctrl+D itself, and the rest would only confuse it.
        if (IsVimOutsideInsert)
        {
            return false;
        }

        SyncCaretsWithView();
        HideCompletion();
        HideSuggestion();
        command(_carets);
        return true;
    }

    private void CopySelection()
    {
        if (!HasExtraCarets)
        {
            _box.Document.Selection.Copy();
            return;
        }

        SyncCaretsWithView();
        SetClipboardText(_carets.Copy());
    }

    private void CutSelection()
    {
        if (!HasExtraCarets)
        {
            _box.Document.Selection.Cut();
            return;
        }

        SyncCaretsWithView();
        SetClipboardText(_carets.Cut());
    }

    private static void SetClipboardText(string text)
    {
        if (text.Length == 0)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(text.Replace("\r", "\r\n", StringComparison.Ordinal));
        Clipboard.SetContent(package);
    }

    private void OnCaretPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_box);
        if (!point.Properties.IsLeftButtonPressed || IsVimOutsideInsert || IsOnScrollBar(e.OriginalSource))
        {
            return;
        }

        var modifiers = e.KeyModifiers;
        var alt = modifiers.HasFlag(VirtualKeyModifiers.Menu);
        var shift = modifiers.HasFlag(VirtualKeyModifiers.Shift);
        var ctrl = modifiers.HasFlag(VirtualKeyModifiers.Control);
        SyncText();
        if (alt && !ctrl)
        {
            if (shift)
            {
                // Alt+Shift+drag selects a box, as in Visual Studio Code and as Option+drag does on macOS.
                _boxSelecting = true;
                _boxAnchor = LineAndColumnAt(point.Position);
                _carets.SelectColumns(_boxAnchor.Line, _boxAnchor.Column, _boxAnchor.Line, _boxAnchor.Column);
            }
            else
            {
                _carets.ToggleCaret(OffsetAt(point.Position));
            }

            return;
        }

        // A plain click returns to one caret, and ends an Emacs region even where the caret already was.
        _boxSelecting = false;
        ResetCaretsToView();
        _carets.Touch();
    }

    private void OnCaretPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_boxSelecting)
        {
            return;
        }

        if (!e.GetCurrentPoint(_box).Properties.IsLeftButtonPressed)
        {
            _boxSelecting = false;
            return;
        }

        var (line, column) = LineAndColumnAt(e.GetCurrentPoint(_box).Position);
        _carets.SelectColumns(_boxAnchor.Line, _boxAnchor.Column, line, column);
    }

    private int OffsetAt(Point point)
    {
        var range = _box.Document.GetRangeFromPoint(point, PointOptions.ClientCoordinates);
        return Math.Clamp(range.StartPosition, 0, _text.Length);
    }

    /// <summary>
    /// The line under a point and the column its x falls on, which may lie past the line's end so a box can reach
    /// beyond short lines. Columns count characters of the monospaced editor font.
    /// </summary>
    private (int Line, int Column) LineAndColumnAt(Point point)
    {
        var line = _carets.LineOf(OffsetAt(point));
        var (start, end) = _carets.LineSpan(line);
        _box.Document.GetRange(start, start).GetRect(PointOptions.ClientCoordinates, out var origin, out _);
        var width = CharacterWidth(start, end);
        return (line, Math.Max(0, (int)Math.Round((point.X - origin.X) / width)));
    }

    private double CharacterWidth(int lineStart, int lineEnd)
    {
        if (lineEnd > lineStart)
        {
            _box.Document.GetRange(lineStart, lineEnd).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
            if (rect.Width > 1)
            {
                return rect.Width / (lineEnd - lineStart);
            }
        }

        return Math.Max(1, _box.FontSize * 0.6);
    }

    private void EnsureCaretLayer()
    {
        if (_caretLayer is not null || Content is not Grid root)
        {
            return;
        }

        _caretLayer = new Canvas { IsHitTestVisible = false };
        _caretLayer.SizeChanged += (_, args) => _caretLayer.Clip = new RectangleGeometry
        {
            Rect = new Rect(0, 0, args.NewSize.Width, args.NewSize.Height),
        };
        Grid.SetRow(_caretLayer, 1);
        Grid.SetColumn(_caretLayer, 1);
        root.Children.Add(_caretLayer);
    }

    /// <summary>
    /// Draws every caret but the primary, which RichEdit draws itself, and their selections, for the visible lines
    /// only so thousands of carets after Ctrl+Shift+L cost no more than a screenful.
    /// </summary>
    private void UpdateCaretOverlay()
    {
        if (_caretLayer is null && !HasExtraCarets)
        {
            return;
        }

        EnsureCaretLayer();
        var used = 0;
        if (HasExtraCarets && _box.FocusState != FocusState.Unfocused && _caretLayer is not null)
        {
            var (firstLine, lastLine) = VisibleLineRange();
            var visibleStart = _carets.LineSpan(firstLine).Start;
            var visibleEnd = _carets.LineSpan(Math.Min(lastLine + 1, Math.Max(0, _lineCount - 1))).End;
            var carets = _carets.Carets;
            for (var i = 0; i < carets.Count; i++)
            {
                var caret = carets[i];
                if (i == _carets.PrimaryIndex || caret.End < visibleStart || caret.Start > visibleEnd)
                {
                    continue;
                }

                if (!caret.IsEmpty)
                {
                    used = DrawSelection(caret, visibleStart, visibleEnd, used);
                }

                used = DrawCaret(caret.Active, used);
            }
        }

        for (var i = used; i < _caretShapes.Count; i++)
        {
            _caretShapes[i].Visibility = Visibility.Collapsed;
        }
    }

    private int DrawCaret(int offset, int used)
    {
        var at = Math.Min(offset, _text.Length);
        _box.Document.GetRange(at, at).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        var height = rect.Height > 1 ? rect.Height : LineHeightPixels;
        Place(Shape(used, isCaret: true), rect.X - (CaretWidth / 2), rect.Y, CaretWidth, height);
        return used + 1;
    }

    private int DrawSelection(Caret caret, int visibleStart, int visibleEnd, int used)
    {
        var from = Math.Max(caret.Start, visibleStart);
        var to = Math.Min(Math.Min(caret.End, visibleEnd), _text.Length);
        var lastLine = _carets.LineOf(to);
        for (var line = _carets.LineOf(from); line <= lastLine; line++)
        {
            var (lineStart, lineEnd) = _carets.LineSpan(line);
            var segmentStart = Math.Max(from, lineStart);
            var segmentEnd = Math.Min(to, lineEnd);
            _box.Document.GetRange(segmentStart, Math.Max(segmentStart, segmentEnd)).GetRect(PointOptions.ClientCoordinates, out var rect, out _);

            // A selected line break shows as half a character, as RichEdit shows its own.
            var width = segmentEnd > segmentStart ? rect.Width : 0;
            if (caret.End > lineEnd)
            {
                width += CharacterWidth(0, 0) / 2;
            }

            if (width > 0)
            {
                Place(Shape(used++, isCaret: false), rect.X, rect.Y, width, rect.Height > 1 ? rect.Height : LineHeightPixels);
            }
        }

        return used;
    }

    private void Place(Rectangle shape, double x, double y, double width, double height)
    {
        var origin = _box.TransformToVisual(_caretLayer).TransformPoint(new Point(x, y));
        Canvas.SetLeft(shape, origin.X);
        Canvas.SetTop(shape, origin.Y);
        shape.Width = width;
        shape.Height = height;
        shape.Visibility = Visibility.Visible;
    }

    /// <summary>A pooled rectangle, styled as a caret or a selection; carets and selections trade shapes as they come and go.</summary>
    private Rectangle Shape(int index, bool isCaret)
    {
        if (index == _caretShapes.Count)
        {
            var created = new Rectangle();
            _caretShapes.Add(created);
            _caretLayer!.Children.Add(created);
        }

        var shape = _caretShapes[index];
        var tag = isCaret ? CaretTag : SelectionTag;
        if (!ReferenceEquals(shape.Tag, tag))
        {
            shape.Tag = tag;
            ApplyCaretStyle(shape);
        }

        return shape;
    }

    private void ApplyCaretStyle(Rectangle shape)
    {
        var isCaret = ReferenceEquals(shape.Tag, CaretTag);
        shape.Fill = ThemeResources.Brush(this, isCaret ? "TextFillColorPrimaryBrush" : "AccentFillColorDefaultBrush");
        shape.Opacity = isCaret ? 1 : SelectionOpacity;
    }

    private void RestyleCaretShapes()
    {
        foreach (var shape in _caretShapes)
        {
            ApplyCaretStyle(shape);
        }
    }

    /// <summary>Whether a press landed on one of the editor's scroll bars, which must leave the carets alone.</summary>
    private bool IsOnScrollBar(object? source)
    {
        for (var element = source as DependencyObject; element is not null && !ReferenceEquals(element, _box); element = VisualTreeHelper.GetParent(element))
        {
            if (element is Microsoft.UI.Xaml.Controls.Primitives.ScrollBar)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>The editor's text as the model edits it: the document's '\r' line ends, offsets unchanged.</summary>
    private sealed class CaretBuffer(SqlEditor editor) : IMultiCursorBuffer
    {
        public string Text => editor._text;

        public string LineBreak => "\r";

        public void Apply(IReadOnlyList<TextEdit> edits, MultiCursorEditKind kind) => editor.ApplyCaretEdits(edits, kind);
    }
}
