namespace TablePro.Core.Editing.MultiCursor;

public sealed partial class MultiCursorModel
{
    /// <summary>
    /// Ctrl+D. On a bare caret, selects the word at each caret; with a selection, adds the next match of the primary's
    /// text after it, wrapping at the end, as the new primary. Matches are case-sensitive. Returns false when there is
    /// no word at the caret or every match is already selected.
    /// </summary>
    public bool AddNextOccurrence()
    {
        var text = Text;
        var primary = _carets[_primary];
        if (primary.IsEmpty)
        {
            return SelectWordsAtCarets(text.Length);
        }

        var needle = text.AsSpan(primary.Start, primary.Length);
        var wholeWord = _wholeWordSearch && _wholeWordVersion == Version;
        var from = primary.End;
        for (var pass = 0; pass < 2; pass++)
        {
            var searchFrom = pass == 0 ? from : 0;
            var limit = pass == 0 ? text.Length : Math.Min(from, text.Length);
            var at = searchFrom;
            while (at < limit)
            {
                var found = text.AsSpan(at, limit - at).IndexOf(needle, StringComparison.Ordinal);
                if (found < 0)
                {
                    break;
                }

                var start = at + found;
                var end = start + needle.Length;
                if ((!wholeWord || _lines.IsWholeWord(start, end)) && !_carets.Exists(c => (c.Start < end && start < c.End) || (c.Start == start && c.End == end)))
                {
                    var list = new List<Caret>(_carets) { Caret.Over(start, end) };
                    Normalize(list, list.Count - 1, text.Length);
                    KeepWholeWord(wholeWord);
                    return true;
                }

                at = start + 1;
            }
        }

        return false;
    }

    /// <summary>
    /// Ctrl+Shift+L. A selection at every match of the primary's selected text, or of the word at the caret, matching
    /// whole words only in that case. The primary stays on the match it was on.
    /// </summary>
    public bool SelectAllOccurrences()
    {
        var text = Text;
        var primary = _carets[_primary];
        int start, end;
        bool wholeWord;
        if (primary.IsEmpty)
        {
            (start, end) = _lines.WordAt(primary.Active);
            wholeWord = true;
        }
        else
        {
            (start, end) = (primary.Start, primary.End);
            wholeWord = _wholeWordSearch && _wholeWordVersion == Version;
        }

        if (end == start)
        {
            return false;
        }

        var needle = text.Substring(start, end - start);
        var list = new List<Caret>();
        var primaryIndex = 0;
        var at = 0;
        while (at <= text.Length - needle.Length)
        {
            var found = text.IndexOf(needle, at, StringComparison.Ordinal);
            if (found < 0)
            {
                break;
            }

            if (!wholeWord || _lines.IsWholeWord(found, found + needle.Length))
            {
                if (found == start)
                {
                    primaryIndex = list.Count;
                }

                list.Add(Caret.Over(found, found + needle.Length));
                at = found + needle.Length;
            }
            else
            {
                at = found + 1;
            }
        }

        if (list.Count == 0)
        {
            return false;
        }

        Normalize(list, primaryIndex, text.Length);
        KeepWholeWord(wholeWord);
        return true;
    }

    private bool SelectWordsAtCarets(int length)
    {
        var list = new List<Caret>(_carets.Count);
        var any = false;
        foreach (var caret in _carets)
        {
            if (!caret.IsEmpty)
            {
                list.Add(caret);
                continue;
            }

            var (start, end) = _lines.WordAt(caret.Active);
            any |= end > start;
            list.Add(end > start ? Caret.Over(start, end) : caret);
        }

        if (!any)
        {
            return false;
        }

        Normalize(list, _primary, length);
        KeepWholeWord(true);
        return true;
    }

    private void KeepWholeWord(bool wholeWord)
    {
        _wholeWordSearch = wholeWord;
        _wholeWordVersion = Version;
    }
}
