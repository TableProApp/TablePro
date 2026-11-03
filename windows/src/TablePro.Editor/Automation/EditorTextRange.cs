using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Automation.Text;
using TablePro.Editor.Model;

namespace TablePro.Editor.Automation;

// A unit the editor lacks falls back to the next larger one, as UIA asks: format to word, page to document.
internal sealed partial class EditorTextRange(SqlEditorAutomationPeer peer, int start, int end) : ITextRangeProvider
{
    private const int IsReadOnlyAttribute = 40015;
    private const int FontNameAttribute = 40005;

    private int _start = start;
    private int _end = end;

    private TextDocument Document => peer.Editor.Document;

    public ITextRangeProvider Clone() => new EditorTextRange(peer, _start, _end);

    public bool Compare(ITextRangeProvider textRangeProvider) =>
        textRangeProvider is EditorTextRange other && other._start == _start && other._end == _end;

    public int CompareEndpoints(TextPatternRangeEndpoint endpoint, ITextRangeProvider textRangeProvider,
        TextPatternRangeEndpoint targetEndpoint)
    {
        Clamp();
        var other = (EditorTextRange)textRangeProvider;
        return Position(endpoint).CompareTo(other.Position(targetEndpoint));
    }

    public void ExpandToEnclosingUnit(TextUnit unit)
    {
        Clamp();
        (_start, _end) = Enclosing(unit, _start);
    }

    public ITextRangeProvider? FindAttribute(int attributeId, object value, bool backward) => null;

    public ITextRangeProvider? FindText(string text, bool backward, bool ignoreCase)
    {
        Clamp();
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }
        var haystack = Document.GetText(_start, _end - _start);
        var comparison = ignoreCase ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var at = backward ? haystack.LastIndexOf(text, comparison) : haystack.IndexOf(text, comparison);
        return at < 0 ? null : new EditorTextRange(peer, _start + at, _start + at + text.Length);
    }

    public object? GetAttributeValue(int attributeId) => attributeId switch
    {
        IsReadOnlyAttribute => false,
        FontNameAttribute => "Cascadia Mono",
        _ => null,
    };

    public void GetBoundingRectangles(out double[] returnValue)
    {
        Clamp();
        var rects = peer.Editor.RangeRects(_start, _end);
        returnValue = new double[rects.Count * 4];
        for (var i = 0; i < rects.Count; i++)
        {
            var client = peer.Editor.ToUiaClient(rects[i]);
            returnValue[i * 4] = client.X;
            returnValue[i * 4 + 1] = client.Y;
            returnValue[i * 4 + 2] = client.Width;
            returnValue[i * 4 + 3] = client.Height;
        }
    }

    public IRawElementProviderSimple GetEnclosingElement() => peer.Provider;

    public string GetText(int maxLength)
    {
        Clamp();
        var length = _end - _start;
        if (maxLength >= 0)
        {
            length = Math.Min(length, maxLength);
        }
        return Document.GetText(_start, length);
    }

    public int Move(TextUnit unit, int count)
    {
        Clamp();
        if (count == 0)
        {
            return 0;
        }
        if (_start == _end)
        {
            var moved = Step(unit, ref _start, count);
            _end = _start;
            return moved;
        }
        (_start, _end) = Enclosing(unit, _start);
        var position = _start;
        var done = Step(unit, ref position, count);
        if (position >= Document.Length && count > 0)
        {
            (_start, _end) = (Document.Length, Document.Length);
            return done;
        }
        (_start, _end) = Enclosing(unit, position);
        return done;
    }

    public void MoveEndpointByRange(TextPatternRangeEndpoint endpoint, ITextRangeProvider textRangeProvider,
        TextPatternRangeEndpoint targetEndpoint)
    {
        SetPosition(endpoint, ((EditorTextRange)textRangeProvider).Position(targetEndpoint));
    }

    public int MoveEndpointByUnit(TextPatternRangeEndpoint endpoint, TextUnit unit, int count)
    {
        Clamp();
        var position = Position(endpoint);
        var moved = Step(unit, ref position, count);
        SetPosition(endpoint, position);
        return moved;
    }

    // A client may hold a range across edits, so every call that reads the document clamps it first.
    public void Select()
    {
        Clamp();
        peer.Editor.Model.SetSelection(_start, _end);
    }

    public void AddToSelection()
    {
        Clamp();
        peer.Editor.Model.AddSelection(new Selection(_start, _end));
    }

    public void RemoveFromSelection()
    {
        Clamp();
        var remaining = peer.Editor.Model.Selections.Where(s => s.Start != _start || s.End != _end).ToList();
        if (remaining.Count > 0)
        {
            peer.Editor.Model.SetSelections(remaining);
        }
    }

    public void ScrollIntoView(bool alignToTop)
    {
        Clamp();
        var line = Document.GetLineFromOffset(alignToTop ? _start : _end);
        var (first, last) = peer.Editor.VisibleLines();
        if (alignToTop || line < first || line > last)
        {
            peer.Editor.ScrollToLine(alignToTop ? line : Math.Max(0, line - (last - first) + 1));
        }
    }

    public IRawElementProviderSimple[] GetChildren() => [];

    private int Position(TextPatternRangeEndpoint endpoint) => endpoint == TextPatternRangeEndpoint.Start ? _start : _end;

    private void SetPosition(TextPatternRangeEndpoint endpoint, int position)
    {
        position = Math.Clamp(position, 0, Document.Length);
        if (endpoint == TextPatternRangeEndpoint.Start)
        {
            _start = position;
            _end = Math.Max(_end, position);
        }
        else
        {
            _end = position;
            _start = Math.Min(_start, position);
        }
    }

    private void Clamp()
    {
        _start = Math.Clamp(_start, 0, Document.Length);
        _end = Math.Clamp(_end, _start, Document.Length);
    }

    private int Step(TextUnit unit, ref int position, int count)
    {
        var moved = 0;
        while (moved < Math.Abs(count))
        {
            var next = count > 0 ? Next(unit, position) : Previous(unit, position);
            if (next == position)
            {
                break;
            }
            position = next;
            moved++;
        }
        return count > 0 ? moved : -moved;
    }

    private int Next(TextUnit unit, int position) => unit switch
    {
        TextUnit.Character => TextUnits.NextCaretStop(Document, position),
        TextUnit.Format or TextUnit.Word => TextUnits.NextWordStart(Document, position),
        TextUnit.Line or TextUnit.Paragraph => LineAfter(position),
        _ => Document.Length,
    };

    private int Previous(TextUnit unit, int position) => unit switch
    {
        TextUnit.Character => TextUnits.PreviousCaretStop(Document, position),
        TextUnit.Format or TextUnit.Word => TextUnits.PreviousWordStart(Document, position),
        TextUnit.Line or TextUnit.Paragraph => LineBefore(position),
        _ => 0,
    };

    private (int Start, int End) Enclosing(TextUnit unit, int position)
    {
        switch (unit)
        {
            case TextUnit.Character:
                return position >= Document.Length ? (position, position) : (position, TextUnits.NextCaretStop(Document, position));
            case TextUnit.Format:
            case TextUnit.Word:
                // A word takes the spaces after it, as Windows text controls report words.
                var probe = position < Document.Length ? TextUnits.NextCaretStop(Document, position) : position;
                var start = TextUnits.PreviousWordStart(Document, probe);
                return (start, TextUnits.NextWordStart(Document, start));
            case TextUnit.Line:
            case TextUnit.Paragraph:
                var line = Document.GetLineFromOffset(position);
                return (Document.GetLineStart(line), line + 1 < Document.LineCount ? Document.GetLineStart(line + 1) : Document.Length);
            default:
                return (0, Document.Length);
        }
    }

    private int LineAfter(int position)
    {
        var line = Document.GetLineFromOffset(position);
        return line + 1 < Document.LineCount ? Document.GetLineStart(line + 1) : Document.Length;
    }

    private int LineBefore(int position)
    {
        var line = Document.GetLineFromOffset(position);
        var start = Document.GetLineStart(line);
        return position > start ? start : line > 0 ? Document.GetLineStart(line - 1) : 0;
    }
}
