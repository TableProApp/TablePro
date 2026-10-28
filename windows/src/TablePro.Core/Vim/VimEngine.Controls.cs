using System.Globalization;

namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    private const char IncrementKey = '\u0001';
    private const char PageUpKey = '\u0002';
    private const char HalfPageDownKey = '\u0004';
    private const char LineDownKey = '\u0005';
    private const char PageDownKey = '\u0006';
    private const char RedoKey = '\u0012';
    private const char HalfPageUpKey = '\u0015';
    private const char DecrementKey = '\u0018';
    private const char LineUpKey = '\u0019';

    /// <summary>Control chords that move like a motion key: Ctrl+H is h, Ctrl+N is j and Ctrl+P is k.</summary>
    private static char? ControlMotion(char key) => key switch
    {
        '\b' => 'h',
        '\u000E' => 'j',
        '\u0010' => 'k',
        _ => null,
    };

    internal static bool IsNormalControl(char key) =>
        key is IncrementKey or PageUpKey or HalfPageDownKey or LineDownKey or PageDownKey or RedoKey or HalfPageUpKey
            or DecrementKey or LineUpKey;

    private bool HandleNormalControl(char key)
    {
        if (ControlMotion(key) is { } motion)
        {
            ProcessNormal(motion, shift: false);
            return true;
        }

        if (!IsNormalControl(key))
        {
            return false;
        }

        // A control key after an operator cancels it, as Vim does for keys that are not motions.
        if (_pendingOperator is not null)
        {
            _pendingOperator = null;
            _countPrefix = 0;
            _operatorCount = 0;
            return true;
        }

        var hasExplicitCount = _countPrefix > 0;
        var count = ConsumeCount();
        switch (key)
        {
            case IncrementKey:
                AdjustNumberOnLine(count);
                break;
            case DecrementKey:
                AdjustNumberOnLine(-count);
                break;
            case HalfPageDownKey:
                ScrollByLines(hasExplicitCount ? count : HalfVisibleLineCount());
                break;
            case HalfPageUpKey:
                ScrollByLines(-(hasExplicitCount ? count : HalfVisibleLineCount()));
                break;
            case PageDownKey:
                ScrollByLines(VisibleLineSpan() * count);
                break;
            case PageUpKey:
                ScrollByLines(-VisibleLineSpan() * count);
                break;
            case RedoKey:
                for (var i = 0; i < count; i++)
                {
                    _buffer.Redo();
                }

                break;
        }

        return true;
    }

    private bool HandleVisualControl(char key, bool linewise)
    {
        if (ControlMotion(key) is { } motion)
        {
            ProcessVisual(motion, shift: false);
            return true;
        }

        if (!IsNormalControl(key))
        {
            return false;
        }

        switch (key)
        {
            case HalfPageDownKey:
                MoveVisualCursor(HalfVisibleLineCount(), linewise);
                break;
            case HalfPageUpKey:
                MoveVisualCursor(-HalfVisibleLineCount(), linewise);
                break;
            case PageDownKey:
                MoveVisualCursor(VisibleLineSpan(), linewise);
                break;
            case PageUpKey:
                MoveVisualCursor(-VisibleLineSpan(), linewise);
                break;
        }

        return true;
    }

    private void MoveVisualCursor(int lines, bool linewise)
    {
        var (line, column) = LineAndColumn(VisualCursorEnd());
        var target = Math.Clamp(line + lines, 0, LineCount - 1);
        UpdateVisualSelection(OffsetForLine(target, column), linewise);
    }

    private int HalfVisibleLineCount()
    {
        var (first, last) = _buffer.VisibleLines();
        return Math.Max(1, (last - first + 1) / 2);
    }

    private int VisibleLineSpan()
    {
        var (first, last) = _buffer.VisibleLines();
        return Math.Max(1, last - first + 1);
    }

    private void ScrollByLines(int delta)
    {
        var (line, column) = LineAndColumn(Caret);
        MoveTo(OffsetForLine(Math.Clamp(line + delta, 0, LineCount - 1), column));
        _goalColumn = null;
    }

    /// <summary>Ctrl+A and Ctrl+X: add to the first number at or after the cursor on its line, decimal or 0x hex.</summary>
    private void AdjustNumberOnLine(int delta)
    {
        if (delta == 0)
        {
            return;
        }

        var line = LineAt(Caret);
        if (FindNumber(Caret, line.Start, ContentEnd(line)) is not { } match)
        {
            return;
        }

        var value = match.Value + delta;
        // Hex keeps a sign rather than wrapping to two's complement, which is how the macOS engine writes it.
        var replacement = match.IsHex
            ? string.Concat(
                match.HexUppercase ? "0X" : "0x",
                value < 0 ? "-" : string.Empty,
                Math.Abs(value).ToString(match.HexUppercase ? "X" : "x", CultureInfo.InvariantCulture))
            : value.ToString(CultureInfo.InvariantCulture);
        ReplaceRange(new VimRange(match.Start, match.End - match.Start), replacement);
        MoveTo(Math.Max(match.Start, match.Start + replacement.Length - 1));
    }

    private (int Start, int End, long Value, bool IsHex, bool HexUppercase)? FindNumber(int cursor, int lineStart, int contentEnd)
    {
        if (contentEnd <= lineStart)
        {
            return null;
        }

        var scan = Math.Max(cursor, lineStart);
        while (scan < contentEnd && !char.IsAsciiDigit(CharAt(scan)))
        {
            scan++;
        }

        if (scan >= contentEnd)
        {
            return null;
        }

        var start = scan;
        if (start >= lineStart + 2 && CharAt(start - 2) == '0' && CharAt(start - 1) is 'x' or 'X')
        {
            start -= 2;
        }

        var isHex = start + 1 < contentEnd && CharAt(start) == '0' && CharAt(start + 1) is 'x' or 'X';
        var end = scan;
        long value;
        if (isHex)
        {
            end = start + 2;
            while (end < contentEnd && char.IsAsciiHexDigit(CharAt(end)))
            {
                end++;
            }

            if (end <= start + 2
                || !long.TryParse(Text.AsSpan(start + 2, end - start - 2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out value))
            {
                return null;
            }

            return (start, end, value, true, CharAt(start + 1) == 'X');
        }

        while (end < contentEnd && char.IsAsciiDigit(CharAt(end)))
        {
            end++;
        }

        if (start > lineStart && CharAt(start - 1) == '-')
        {
            start--;
        }

        return long.TryParse(Text.AsSpan(start, end - start), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value)
            ? (start, end, value, false, false)
            : null;
    }
}
