namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    private string? _lastSearchPattern;
    private bool _lastSearchForward = true;
    private bool _lastSearchWholeWord;

    private void RunSearch(string pattern, bool forward)
    {
        if (pattern.Length == 0)
        {
            return;
        }

        _lastSearchPattern = pattern;
        _lastSearchForward = forward;
        _lastSearchWholeWord = false;
        JumpToMatch(pattern, forward, wholeWord: false);
    }

    private void SearchNext(bool reverseDirection)
    {
        if (_lastSearchPattern is { } pattern)
        {
            JumpToMatch(pattern, reverseDirection ? !_lastSearchForward : _lastSearchForward, _lastSearchWholeWord);
        }
    }

    /// <summary>* and #: search for the word under the cursor as a whole word.</summary>
    private void SearchWordUnderCursor(bool forward)
    {
        var pos = Caret;
        if (pos >= Length)
        {
            return;
        }

        var start = pos;
        while (start > 0 && VimText.IsWordChar(CharAt(start - 1)))
        {
            start--;
        }

        var end = pos;
        while (end < Length && VimText.IsWordChar(CharAt(end)))
        {
            end++;
        }

        if (end <= start)
        {
            return;
        }

        var word = Substring(new VimRange(start, end - start));
        _lastSearchPattern = word;
        _lastSearchForward = forward;
        _lastSearchWholeWord = true;
        JumpToMatch(word, forward, wholeWord: true);
    }

    private void JumpToMatch(string pattern, bool forward, bool wholeWord)
    {
        var origin = Caret;
        var target = FindPattern(pattern, origin, forward, wholeWord);
        if (target >= 0)
        {
            MoveTo(target);
            _lastJumpOrigin = origin;
        }
    }

    /// <summary>The next literal match from an offset in a direction, wrapping around the text; the origin itself last.</summary>
    private int FindPattern(string pattern, int origin, bool forward, bool wholeWord)
    {
        var text = Text;
        if (text.Length == 0 || pattern.Length == 0)
        {
            return -1;
        }

        if (forward)
        {
            for (var from = Math.Min(origin + 1, text.Length); from < text.Length;)
            {
                var at = text.IndexOf(pattern, from, StringComparison.Ordinal);
                if (at < 0)
                {
                    break;
                }

                if (IsMatch(at))
                {
                    return at;
                }

                from = at + 1;
            }

            for (var from = 0; from < origin;)
            {
                var at = text.IndexOf(pattern, from, StringComparison.Ordinal);
                if (at < 0 || at >= origin)
                {
                    break;
                }

                if (IsMatch(at))
                {
                    return at;
                }

                from = at + 1;
            }
        }
        else
        {
            for (var i = Math.Min(origin - 1, text.Length - 1); i >= 0; i--)
            {
                if (IsMatch(i))
                {
                    return i;
                }
            }

            for (var i = text.Length - 1; i > origin; i--)
            {
                if (IsMatch(i))
                {
                    return i;
                }
            }
        }

        return IsMatch(origin) ? origin : -1;

        bool IsMatch(int index)
        {
            if (index < 0 || index + pattern.Length > text.Length
                || !text.AsSpan(index, pattern.Length).SequenceEqual(pattern))
            {
                return false;
            }

            if (!wholeWord)
            {
                return true;
            }

            var after = index + pattern.Length;
            return (index == 0 || !VimText.IsWordChar(text[index - 1]))
                && (after >= text.Length || !VimText.IsWordChar(text[after]));
        }
    }
}
