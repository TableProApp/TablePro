namespace TablePro.Core.Editing.MultiCursor;

public sealed partial class MultiCursorModel
{
    /// <summary>
    /// Moves every caret. Extending keeps each anchor and moves the active end, as Shift+arrows do; otherwise Left and
    /// Right on a selection land on its near edge instead of moving, as in every Windows text box.
    /// </summary>
    public void Move(CaretMotion motion, bool extend)
    {
        var text = Text;
        var list = new List<Caret>(_carets.Count);
        foreach (var caret in _carets)
        {
            if (!extend && !caret.IsEmpty && motion is CaretMotion.Left or CaretMotion.Right)
            {
                list.Add(Caret.At(motion == CaretMotion.Left ? caret.Start : caret.End));
                continue;
            }

            var target = Target(motion, caret, text.Length, out var column);
            list.Add(extend ? new Caret(caret.Anchor, target, column) : new Caret(target, target, column));
        }

        Normalize(list, _primary, text.Length);
    }

    /// <summary>Where a motion takes a caret's active end; <paramref name="column"/> is the column Up and Down keep aiming for.</summary>
    private int Target(CaretMotion motion, Caret caret, int length, out int column)
    {
        column = -1;
        var at = caret.Active;
        switch (motion)
        {
            case CaretMotion.Left:
                return _lines.Previous(at);
            case CaretMotion.Right:
                return _lines.Next(at);
            case CaretMotion.WordLeft:
                return _lines.WordStartBefore(at);
            case CaretMotion.WordRight:
                return _lines.NextWordStart(at);
            case CaretMotion.WordEnd:
                return _lines.WordEndAfter(at);
            case CaretMotion.Up:
            case CaretMotion.Down:
            {
                var line = _lines.LineOf(at);
                column = caret.PreferredColumn >= 0 ? caret.PreferredColumn : at - _lines.Start(line);
                var target = line + (motion == CaretMotion.Up ? -1 : 1);
                if (target < 0)
                {
                    return 0;
                }

                if (target >= _lines.Count)
                {
                    return length;
                }

                return Math.Min(_lines.Start(target) + column, _lines.End(target));
            }

            case CaretMotion.LineStart:
                return _lines.Start(_lines.LineOf(at));
            case CaretMotion.SmartLineStart:
            {
                var line = _lines.LineOf(at);
                var start = _lines.Start(line);
                var end = _lines.End(line);
                var firstText = start;
                while (firstText < end && TextLines.IsBlank(_lines.Text[firstText]))
                {
                    firstText++;
                }

                return at == firstText ? start : firstText;
            }

            case CaretMotion.LineEnd:
                return _lines.End(_lines.LineOf(at));
            case CaretMotion.DocumentStart:
                return 0;
            case CaretMotion.DocumentEnd:
                return length;
            default:
                return at;
        }
    }
}
