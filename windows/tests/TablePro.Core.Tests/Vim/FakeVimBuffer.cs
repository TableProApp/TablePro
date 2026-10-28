using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>An in-memory <see cref="IVimBuffer"/> that records undo, redo and undo groups instead of performing them.</summary>
internal sealed class FakeVimBuffer : IVimBuffer
{
    private int _selectionStart;
    private int _selectionLength;

    public FakeVimBuffer(string text = "", int caret = 0)
    {
        Text = text;
        Select(caret, 0);
    }

    public string Text { get; set; }

    public int SelectionStart => _selectionStart;

    public int SelectionLength => _selectionLength;

    public string IndentUnit { get; set; } = "    ";

    /// <summary>The lines the fake editor shows; the whole text unless a test narrows it.</summary>
    public (int First, int Last)? Visible { get; set; }

    public int UndoCount { get; private set; }

    public int RedoCount { get; private set; }

    public int UndoGroupDepth { get; private set; }

    /// <summary>Outermost undo groups closed so far, each one undo step in a real editor.</summary>
    public int ClosedUndoGroups { get; private set; }

    public void Select(int start, int length)
    {
        _selectionStart = Math.Clamp(start, 0, Text.Length);
        _selectionLength = Math.Clamp(length, 0, Text.Length - _selectionStart);
    }

    public void Replace(int start, int length, string text)
    {
        Text = string.Concat(Text.AsSpan(0, start), text, Text.AsSpan(start + length));
        _selectionStart = start + text.Length;
        _selectionLength = 0;
    }

    public void Undo() => UndoCount++;

    public void Redo() => RedoCount++;

    public void BeginUndoGroup() => UndoGroupDepth++;

    public void EndUndoGroup()
    {
        Assert.True(UndoGroupDepth > 0, "EndUndoGroup without a matching BeginUndoGroup");
        if (--UndoGroupDepth == 0)
        {
            ClosedUndoGroups++;
        }
    }

    public (int First, int Last) VisibleLines() => Visible ?? (0, Math.Max(0, VimText.LineCount(Text) - 1));

    public (int Line, int Column) LineAndColumn(int offset) => VimText.LineAndColumn(Text, offset);

    public int OffsetForLine(int line, int column) => VimText.OffsetForLine(Text, line, column);
}

/// <summary>An engine over a fake buffer with the helpers every Vim test uses.</summary>
internal sealed class VimHarness
{
    public VimHarness(string text = "", int caret = 0)
    {
        Buffer = new FakeVimBuffer(text, caret);
        Engine = new VimEngine(Buffer);
    }

    public FakeVimBuffer Buffer { get; }

    public VimEngine Engine { get; }

    public int Pos => Buffer.SelectionStart;

    public string Text => Buffer.Text;

    public VimMode Mode => Engine.Mode;

    /// <summary>Sends each character as one key.</summary>
    public void Keys(string keys)
    {
        foreach (var key in keys)
        {
            Engine.Process(key);
        }
    }

    public bool Key(char key, bool shift = false) => Engine.Process(key, shift);

    public void Select(int start, int length = 0) => Buffer.Select(start, length);
}
