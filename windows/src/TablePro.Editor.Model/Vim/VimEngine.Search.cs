namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    internal void RunSearch(string pattern, bool forward)
    {
        if (pattern.Length == 0)
        {
            return;
        }
        LastSearchPattern = pattern;
        LastSearchForward = forward;
        var origin = _buffer.SelectedRange.Location;
        if (FindPattern(pattern, origin, forward, wholeWord: false) is { } target)
        {
            _buffer.SetCaret(target);
            LastJumpOrigin = origin;
        }
    }

    internal void SearchNext(bool reverseDirection)
    {
        if (LastSearchPattern is not { } pattern)
        {
            return;
        }
        var forward = reverseDirection ? !LastSearchForward : LastSearchForward;
        var origin = _buffer.SelectedRange.Location;
        if (FindPattern(pattern, origin, forward, wholeWord: false) is { } target)
        {
            _buffer.SetCaret(target);
            LastJumpOrigin = origin;
        }
    }

    internal void SearchWordUnderCursor(bool forward)
    {
        var pos = _buffer.SelectedRange.Location;
        if (pos >= _buffer.Length)
        {
            return;
        }
        var start = pos;
        while (start > 0 && VimTextBuffer.IsWordChar(_buffer.CharAt(start - 1)))
        {
            start--;
        }
        var end = pos;
        while (end < _buffer.Length && VimTextBuffer.IsWordChar(_buffer.CharAt(end)))
        {
            end++;
        }
        if (end <= start)
        {
            return;
        }
        var word = _buffer.Text(new VimRange(start, end - start));
        LastSearchPattern = word;
        LastSearchForward = forward;
        if (FindPattern(word, pos, forward, wholeWord: true) is { } target)
        {
            _buffer.SetCaret(target);
            LastJumpOrigin = pos;
        }
    }

    // Literal and case-sensitive, wrapping past either end, as the macOS engine searches.
    internal int? FindPattern(string pattern, int origin, bool forward, bool wholeWord)
    {
        var text = _buffer.Model.Document.Snapshot();
        var total = text.Length;
        if (total == 0 || pattern.Length == 0)
        {
            return null;
        }
        bool Whole(int index)
        {
            var after = index + pattern.Length;
            return !wholeWord || ((index == 0 || !VimTextBuffer.IsWordChar(text[index - 1]))
                && (after >= total || !VimTextBuffer.IsWordChar(text[after])));
        }
        int Next(int from)
        {
            for (var at = from < total ? text.IndexOf(pattern, Math.Max(0, from), StringComparison.Ordinal) : -1;
                at >= 0;
                at = at + 1 < total ? text.IndexOf(pattern, at + 1, StringComparison.Ordinal) : -1)
            {
                if (Whole(at))
                {
                    return at;
                }
            }
            return -1;
        }
        int Previous(int from)
        {
            // A match found backward from an index ends at or before it, so the search starts where one at from ends.
            var at = from >= 0 ? LastBefore(Math.Min(total - 1, from + pattern.Length - 1)) : -1;
            for (; at >= 0; at = at > 0 ? LastBefore(at + pattern.Length - 2) : -1)
            {
                if (Whole(at))
                {
                    return at;
                }
            }
            return -1;
        }

        int LastBefore(int end) => text.LastIndexOf(pattern, end, StringComparison.Ordinal);

        int found;
        if (forward)
        {
            found = Next(origin + 1);
            if (found < 0)
            {
                found = Next(0);
            }
        }
        else
        {
            found = Previous(origin - 1);
            if (found < 0)
            {
                found = Previous(total - 1);
            }
        }
        return found >= 0 ? found : null;
    }
}
