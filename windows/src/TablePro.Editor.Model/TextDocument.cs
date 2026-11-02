namespace TablePro.Editor.Model;

public enum LineEnding
{
    CrLf,
    Lf,
    Cr,
}

// One replacement, as the document saw it. Lines are counted before the change.
public sealed record TextChange(
    int Offset,
    string RemovedText,
    string InsertedText,
    int StartLine,
    int RemovedBreaks,
    int InsertedBreaks,
    long Version)
{
    public int RemovedLength => RemovedText.Length;

    public int InsertedLength => InsertedText.Length;
}

// The text of one editor. Line breaks are stored as '\n' alone, whatever the file used; LineEnding puts the
// file's own break back when the text leaves the editor. Offsets everywhere (carets, TSF, UIA) count UTF-16 units
// of this normalized text.
public sealed class TextDocument
{
    private readonly Rope _rope = new();
    private string? _snapshot;
    private long _snapshotVersion = -1;

    public TextDocument()
    {
        Undo = new UndoHistory();
    }

    public TextDocument(string text)
        : this()
    {
        SetText(text);
    }

    public event EventHandler<TextChange>? Changed;

    // Raised by SetText, which replaces everything and clears the undo history.
    public event EventHandler? Reset;

    public UndoHistory Undo { get; }

    public LineEnding LineEnding { get; set; } = LineEnding.CrLf;

    public int Length => _rope.Length;

    public int LineCount => _rope.LineBreaks + 1;

    public long Version { get; private set; }

    public void SetText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        LineEnding = DetectLineEnding(text) ?? LineEnding;
        _rope.SetText(Normalize(text));
        Version++;
        Undo.Clear();
        Reset?.Invoke(this, EventArgs.Empty);
    }

    public string GetText() => GetText(0, Length);

    public string GetText(int offset, int length) => _rope.GetText(offset, length);

    // The whole text once per version, for searches that want one string.
    public string Snapshot()
    {
        if (_snapshotVersion != Version || _snapshot is null)
        {
            _snapshot = GetText();
            _snapshotVersion = Version;
        }
        return _snapshot;
    }

    // The text with the document's own line breaks, for saving and the clipboard.
    public string ExportText(int offset, int length)
    {
        var text = GetText(offset, length);
        return LineEnding switch
        {
            LineEnding.CrLf => text.Replace("\n", "\r\n", StringComparison.Ordinal),
            LineEnding.Cr => text.Replace('\n', '\r'),
            _ => text,
        };
    }

    public char CharAt(int offset) => _rope.CharAt(offset);

    public void CopyTo(int offset, Span<char> destination) => _rope.CopyTo(offset, destination);

    public IEnumerable<ReadOnlyMemory<char>> Chunks(int offset, int length) => _rope.Chunks(offset, length);

    public int GetLineStart(int line) => _rope.LineStart(line);

    // The offset of the line's '\n', or the document's end on the last line.
    public int GetLineEnd(int line) => line + 1 < LineCount ? _rope.LineStart(line + 1) - 1 : Length;

    public int GetLineLength(int line) => GetLineEnd(line) - GetLineStart(line);

    public int GetLineFromOffset(int offset) => _rope.LineOf(offset);

    public string GetLineText(int line)
    {
        var start = GetLineStart(line);
        return GetText(start, GetLineEnd(line) - start);
    }

    public (int Line, int Column) GetPosition(int offset)
    {
        var line = GetLineFromOffset(offset);
        return (line, offset - GetLineStart(line));
    }

    public int GetOffset(int line, int column)
    {
        line = Math.Clamp(line, 0, LineCount - 1);
        var start = GetLineStart(line);
        return start + Math.Clamp(column, 0, GetLineEnd(line) - start);
    }

    public TextChange Replace(int offset, int length, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var change = ApplyReplace(offset, length, Normalize(text));
        Undo.Record(change);
        return change;
    }

    // Undo and redo replay through here, so they never record a step of their own.
    internal TextChange ReplaceWithoutUndo(int offset, int length, string text) => ApplyReplace(offset, length, text);

    private TextChange ApplyReplace(int offset, int length, string text)
    {
        if (offset < 0 || length < 0 || offset + length > Length)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }
        var startLine = _rope.LineOf(offset);
        var removed = _rope.GetText(offset, length);
        var removedBreaks = removed.AsSpan().Count('\n');
        _rope.Remove(offset, length);
        _rope.Insert(offset, text);
        Version++;
        var change = new TextChange(offset, removed, text, startLine, removedBreaks, text.AsSpan().Count('\n'), Version);
        Changed?.Invoke(this, change);
        return change;
    }

    public static string Normalize(string text)
    {
        if (text.AsSpan().IndexOf('\r') < 0)
        {
            return text;
        }
        return text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
    }

    private static LineEnding? DetectLineEnding(string text)
    {
        var index = text.AsSpan().IndexOfAny('\r', '\n');
        if (index < 0)
        {
            return null;
        }
        if (text[index] == '\n')
        {
            return LineEnding.Lf;
        }
        return index + 1 < text.Length && text[index + 1] == '\n' ? LineEnding.CrLf : LineEnding.Cr;
    }

    internal void CheckInvariants() => _rope.CheckInvariants();
}
