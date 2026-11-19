using System.Globalization;

namespace TablePro.Editor.Model.Vim;

internal enum VimNormalControl
{
    IncrementNumber = 0x01,
    ScrollPageUp = 0x02,
    ScrollHalfPageDown = 0x04,
    ScrollLineDown = 0x05,
    ScrollPageDown = 0x06,
    Redo = 0x12,
    ScrollHalfPageUp = 0x15,
    DecrementNumber = 0x18,
    ScrollLineUp = 0x19,
}

internal sealed record VimNumberMatch(int Start, int End, long Value, bool IsHex, bool HexUppercase);

public sealed partial class VimEngine
{
    // Ctrl+H, Ctrl+N and Ctrl+P move as h, j and k do.
    internal static string? ControlMotionKey(string key) => key switch
    {
        "\b" => "h",
        "\u000E" => "j",
        "\u0010" => "k",
        _ => null,
    };

    internal static VimNormalControl? NormalControl(string key)
    {
        if (key.Length != 1)
        {
            return null;
        }
        var value = (VimNormalControl)key[0];
        return Enum.IsDefined(value) ? value : null;
    }

    private bool HandleNormalControl(string key)
    {
        if (ControlMotionKey(key) is { } motion)
        {
            ProcessNormal(motion, shift: false);
            return true;
        }
        if (NormalControl(key) is not { } control)
        {
            return false;
        }
        if (PendingOperator is not null)
        {
            CancelPending();
            return true;
        }
        PerformNormalControl(control);
        return true;
    }

    private bool HandleVisualControl(string key, bool linewise)
    {
        if (ControlMotionKey(key) is { } motion)
        {
            ProcessVisual(motion, shift: false);
            return true;
        }
        if (NormalControl(key) is not { } control)
        {
            return false;
        }
        switch (control)
        {
            case VimNormalControl.ScrollHalfPageDown:
                MoveVisualCursor(HalfVisibleLineCount(), linewise);
                break;
            case VimNormalControl.ScrollHalfPageUp:
                MoveVisualCursor(-HalfVisibleLineCount(), linewise);
                break;
            case VimNormalControl.ScrollPageDown:
                MoveVisualCursor(VisibleLineSpan(), linewise);
                break;
            case VimNormalControl.ScrollPageUp:
                MoveVisualCursor(-VisibleLineSpan(), linewise);
                break;
            case VimNormalControl.ScrollLineDown:
                ScrollView(ConsumeCount());
                break;
            case VimNormalControl.ScrollLineUp:
                ScrollView(-ConsumeCount());
                break;
        }
        return true;
    }

    private void PerformNormalControl(VimNormalControl control)
    {
        var hasExplicitCount = CountPrefix > 0;
        var count = ConsumeCount();
        switch (control)
        {
            case VimNormalControl.IncrementNumber:
                AdjustNumberOnLine(count);
                break;
            case VimNormalControl.DecrementNumber:
                AdjustNumberOnLine(-count);
                break;
            case VimNormalControl.ScrollHalfPageDown:
                ScrollByLines(hasExplicitCount ? count : HalfVisibleLineCount());
                break;
            case VimNormalControl.ScrollHalfPageUp:
                ScrollByLines(-(hasExplicitCount ? count : HalfVisibleLineCount()));
                break;
            case VimNormalControl.ScrollPageDown:
                ScrollByLines(VisibleLineSpan() * count);
                break;
            case VimNormalControl.ScrollPageUp:
                ScrollByLines(-VisibleLineSpan() * count);
                break;
            case VimNormalControl.Redo:
                for (var i = 0; i < count; i++)
                {
                    _buffer.Redo();
                }
                break;
            case VimNormalControl.ScrollLineDown:
                ScrollView(count);
                break;
            case VimNormalControl.ScrollLineUp:
                ScrollView(-count);
                break;
        }
    }

    // Ctrl+E and Ctrl+Y move the view by rows and the caret only when the view leaves it behind.
    private void ScrollView(int rows)
    {
        _buffer.Host.ScrollRows(rows);
        var model = _buffer.Model;
        var (first, last) = _buffer.VisibleRows();
        var cursor = _mode.IsVisual() ? VisualCursorEnd() : _buffer.SelectedRange.Location;
        var row = model.Rows.RowOf(cursor);
        if (row >= first && row <= last)
        {
            return;
        }
        var target = ClampToContentPosition(model.Rows.OffsetAt(row < first ? first : last, model.Rows.ColumnInRow(cursor)));
        if (_mode.IsVisual())
        {
            UpdateVisualSelection(target, _mode == VimMode.VisualLine);
        }
        else
        {
            _buffer.SetCaret(target);
        }
    }

    private void MoveVisualCursor(int lines, bool linewise)
    {
        var (line, column) = _buffer.LineAndColumn(VisualCursorEnd());
        UpdateVisualSelection(_buffer.Offset(_buffer.StepLines(line, lines), column), linewise);
    }

    internal int HalfVisibleLineCount() => Math.Max(1, _buffer.VisibleLineCount() / 2);

    internal int VisibleLineSpan() => _buffer.VisibleLineCount();

    internal void ScrollByLines(int delta)
    {
        var (line, column) = _buffer.LineAndColumn(_buffer.SelectedRange.Location);
        _buffer.SetCaret(_buffer.Offset(_buffer.StepLines(line, delta), column));
        GoalColumn = null;
    }

    internal void AdjustNumberOnLine(long delta)
    {
        if (delta == 0)
        {
            return;
        }
        var pos = _buffer.SelectedRange.Location;
        var line = _buffer.LineRange(pos);
        if (FindNumber(pos, line.Location, ContentEnd(line)) is not { } match)
        {
            return;
        }
        var replacement = FormatNumber(match.Value + delta, match.IsHex, match.HexUppercase);
        _buffer.Replace(new VimRange(match.Start, match.End - match.Start), replacement);
        var newEnd = match.Start + replacement.Length;
        _buffer.SetCaret(Math.Max(match.Start, newEnd - 1));
    }

    internal VimNumberMatch? FindNumber(int cursor, int lineStart, int contentEnd)
    {
        if (contentEnd <= lineStart)
        {
            return null;
        }
        var scan = Math.Max(cursor, lineStart);
        while (scan < contentEnd && !char.IsAsciiDigit(_buffer.CharAt(scan)))
        {
            scan++;
        }
        if (scan >= contentEnd)
        {
            return null;
        }
        var start = scan;
        if (start >= lineStart + 2 && _buffer.CharAt(start - 2) == '0' && _buffer.CharAt(start - 1) is 'x' or 'X')
        {
            start -= 2;
        }
        var end = scan;
        var isHex = start + 1 < contentEnd && _buffer.CharAt(start) == '0' && _buffer.CharAt(start + 1) is 'x' or 'X';
        var hexUppercase = false;
        if (isHex)
        {
            hexUppercase = _buffer.CharAt(start + 1) == 'X';
            end = start + 2;
            while (end < contentEnd && char.IsAsciiHexDigit(_buffer.CharAt(end)))
            {
                end++;
            }
            if (end <= start + 2)
            {
                return null;
            }
        }
        else
        {
            while (end < contentEnd && char.IsAsciiDigit(_buffer.CharAt(end)))
            {
                end++;
            }
            if (start > lineStart && _buffer.CharAt(start - 1) == '-')
            {
                start--;
            }
        }
        var text = _buffer.Text(new VimRange(start, end - start));
        return ParseNumberLiteral(text) is { } value ? new VimNumberMatch(start, end, value, isHex, hexUppercase) : null;
    }

    internal static long? ParseNumberLiteral(string text)
    {
        if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            return long.TryParse(text.AsSpan(2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var hex)
                ? hex
                : null;
        }
        return long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    internal static string FormatNumber(long value, bool hex, bool hexUppercase)
    {
        if (!hex)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }
        var body = value.ToString(hexUppercase ? "X" : "x", CultureInfo.InvariantCulture);
        return (hexUppercase ? "0X" : "0x") + body;
    }
}
