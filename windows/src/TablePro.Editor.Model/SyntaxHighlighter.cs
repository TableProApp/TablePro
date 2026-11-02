using System.Buffers;

namespace TablePro.Editor.Model;

// A colored run, relative to the text it was read from. Kind is the lexer's own value; the view maps it to a brush.
public readonly record struct SyntaxSpan(int Start, int Length, byte Kind)
{
    public int End => Start + Length;
}

// The seam to a lexer. It writes the tokens of text in order, whitespace left out, and returns how many it wrote.
// A span as long as text always suffices. It must read text from its start as code: no state comes in.
public interface ISyntaxLexer
{
    int Tokenize(ReadOnlySpan<char> text, Span<SyntaxSpan> spans);
}

// Colors for the lines on screen, over a lexer that only reads from a clean start. Each line keeps one fact: does it
// start outside every token (clean), or inside one that began above (a block comment, a string)? Lexing the visible
// lines starts at the nearest clean line above them, so tokens that span lines come out right.
//
// Facts are known for lines before the frontier. An edit moves the frontier back to the edited line; lexing forward
// from there stops early once a line after the edit is clean again as it was before, because a lexer that starts
// clean on unchanged text reads it the same way. Nothing here touches the document, so coloring never makes an
// undo step.
public sealed class SyntaxHighlighter : IDisposable
{
    private const byte Unknown = 0;
    private const byte Clean = 1;
    private const byte Inside = 2;
    private const int Window = 64 * 1024;

    private readonly TextDocument _document;
    private readonly ISyntaxLexer _lexer;
    private readonly GapList<byte> _lines = new();
    private int _frontier;
    private int _staleEnd;
    private int _convergeFrom;

    public SyntaxHighlighter(TextDocument document, ISyntaxLexer lexer)
    {
        _document = document;
        _lexer = lexer;
        Reset();
        document.Changed += OnChanged;
        document.Reset += OnReset;
    }

    public void Dispose()
    {
        _document.Changed -= OnChanged;
        _document.Reset -= OnReset;
    }

    // Lines whose start state is known, for tests and the idle pass.
    public int Frontier => _frontier;

    // Characters handed to the lexer since the last reset, for the gate's measurements.
    public long LexedChars { get; private set; }

    public int LexCalls { get; private set; }

    public bool IsLineClean(int line)
    {
        EnsureStates(line);
        return _lines[line] == Clean;
    }

    // Spans with document offsets that touch lines first to last.
    public void GetTokens(int firstLine, int lastLine, List<SyntaxSpan> output)
    {
        output.Clear();
        firstLine = Math.Clamp(firstLine, 0, _document.LineCount - 1);
        lastLine = Math.Clamp(lastLine, firstLine, _document.LineCount - 1);
        EnsureStates(firstLine);
        var clean = firstLine;
        while (_lines[clean] != Clean)
        {
            clean--;
        }
        var start = _document.GetLineStart(clean);
        var end = _document.GetLineEnd(lastLine);
        var from = _document.GetLineStart(firstLine);
        var buffer = ArrayPool<char>.Shared.Rent(Math.Max(1, end - start));
        var spans = ArrayPool<SyntaxSpan>.Shared.Rent(Math.Max(1, end - start));
        try
        {
            var text = buffer.AsSpan(0, end - start);
            _document.CopyTo(start, text);
            var count = Lex(text, spans);
            for (var i = 0; i < count; i++)
            {
                var span = spans[i];
                if (start + span.End > from)
                {
                    output.Add(span with { Start = span.Start + start });
                }
            }
        }
        finally
        {
            ArrayPool<char>.Shared.Return(buffer);
            ArrayPool<SyntaxSpan>.Shared.Return(spans);
        }
    }

    // Lexes a few windows past the frontier while the editor is idle, so a later jump finds its lines known.
    // False once every line is known.
    public bool AdvanceIdle(int windows)
    {
        for (var i = 0; i < windows && _frontier < _document.LineCount; i++)
        {
            AdvanceOnce(Window);
        }
        return _frontier < _document.LineCount;
    }

    // Moves the frontier past line, lexing from the last clean line in windows.
    public void EnsureStates(int line)
    {
        var window = Window;
        while (_frontier <= line && _frontier < _document.LineCount)
        {
            var before = _frontier;
            AdvanceOnce(window);
            window = _frontier == before ? window * 2 : Window;
        }
    }

    private void AdvanceOnce(int window)
    {
        var clean = _frontier - 1;
        while (_lines[clean] != Clean)
        {
            clean--;
        }
        var start = _document.GetLineStart(clean);
        var limit = Math.Min(_document.Length, start + window);
        var lastLine = _document.GetLineFromOffset(limit);
        var end = limit == _document.Length ? limit : _document.GetLineEnd(lastLine);
        var atDocumentEnd = end == _document.Length;
        var length = end - start;
        var buffer = ArrayPool<char>.Shared.Rent(Math.Max(1, length));
        var spans = ArrayPool<SyntaxSpan>.Shared.Rent(Math.Max(1, length));
        try
        {
            var text = buffer.AsSpan(0, length);
            _document.CopyTo(start, text);
            var count = Lex(text, spans);
            // A token cut by the window's end may go on past it, so the lines it covers wait for a longer window.
            var known = length;
            if (!atDocumentEnd && count > 0 && spans[count - 1].End >= length)
            {
                known = spans[count - 1].Start;
            }
            var spanIndex = 0;
            var line = clean;
            var lineStart = 0;
            while (true)
            {
                var next = text[lineStart..].IndexOf('\n');
                if (next < 0)
                {
                    break;
                }
                lineStart += next + 1;
                line++;
                if (lineStart > known)
                {
                    break;
                }
                while (spanIndex < count && spans[spanIndex].End <= lineStart)
                {
                    spanIndex++;
                }
                var state = spanIndex < count && spans[spanIndex].Start < lineStart ? Inside : Clean;
                if (line < _frontier)
                {
                    continue;
                }
                var old = _lines[line];
                _lines[line] = state;
                _frontier = line + 1;
                if (state == Clean && old == Clean && line >= _convergeFrom && line < _staleEnd)
                {
                    _frontier = _staleEnd;
                    _staleEnd = 0;
                    return;
                }
            }
            if (atDocumentEnd)
            {
                _frontier = _document.LineCount;
            }
        }
        finally
        {
            ArrayPool<char>.Shared.Return(buffer);
            ArrayPool<SyntaxSpan>.Shared.Return(spans);
        }
    }

    private int Lex(ReadOnlySpan<char> text, Span<SyntaxSpan> spans)
    {
        LexCalls++;
        LexedChars += text.Length;
        return _lexer.Tokenize(text, spans);
    }

    private void OnReset(object? sender, EventArgs e) => Reset();

    private void OnChanged(object? sender, TextChange change)
    {
        var removedEnd = change.StartLine + change.RemovedBreaks;
        var delta = change.InsertedBreaks - change.RemovedBreaks;
        _lines.RemoveRange(change.StartLine + 1, change.RemovedBreaks);
        _lines.InsertRange(change.StartLine + 1, change.InsertedBreaks, Unknown);
        var editEnd = change.StartLine + change.InsertedBreaks;

        var stale = Math.Max(_frontier, _staleEnd);
        _staleEnd = stale > removedEnd + 1 ? stale + delta : 0;
        _convergeFrom = _convergeFrom > removedEnd ? Math.Max(_convergeFrom + delta, editEnd + 1) : editEnd + 1;
        _frontier = Math.Min(_frontier, change.StartLine + 1);
    }

    private void Reset()
    {
        _lines.Clear();
        _lines.InsertRange(0, _document.LineCount, Unknown);
        _lines[0] = Clean;
        _frontier = 1;
        _staleEnd = 0;
        _convergeFrom = 0;
        LexedChars = 0;
        LexCalls = 0;
    }
}
