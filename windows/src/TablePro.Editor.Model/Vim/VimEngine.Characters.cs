namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    internal int CharacterStart(int offset) => _buffer.CharacterRange(offset).Location;

    // At or past the end of the text this is the end of the text.
    internal int CharacterEnd(int offset) => _buffer.CharacterRange(offset).End;

    // Stops at the last step that stays within limit; an offset already past it comes back to limit.
    internal int CharacterOffsetAfter(int offset, int count, int limit)
    {
        var position = offset;
        for (var i = 0; i < Math.Max(0, count); i++)
        {
            var next = CharacterEnd(position);
            if (next <= position || next > limit)
            {
                break;
            }
            position = next;
        }
        return Math.Min(position, limit);
    }

    internal int CharacterOffsetBefore(int offset, int count, int limit)
    {
        var position = offset;
        for (var i = 0; i < Math.Max(0, count); i++)
        {
            if (position <= limit)
            {
                break;
            }
            position = CharacterStart(position - 1);
        }
        return Math.Max(position, limit);
    }

    // The end of the line's text, before its break.
    internal int ContentEnd(VimRange line)
    {
        var lineEnd = line.End;
        return lineEnd > line.Location && lineEnd <= _buffer.Length && _buffer.CharAt(lineEnd - 1) == '\n'
            ? lineEnd - 1
            : lineEnd;
    }

    // A single control character other than tab and the line breaks, which typing never writes.
    internal static bool IsUnwritableControl(string key) =>
        key.Length == 1 && char.IsControl(key[0]) && key[0] is not ('\t' or '\n' or '\r');

    internal static bool IsBackspace(string key) => key is "\b" or "\u007F";
}
