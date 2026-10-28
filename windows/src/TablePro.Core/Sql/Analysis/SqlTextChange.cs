namespace TablePro.Core.Sql.Analysis;

/// <summary>
/// The one range an edit replaced between two versions of a text, found from their common prefix and suffix. The
/// editor uses it to keep the last analysis's squiggles on their text while typing, until the next analysis lands.
/// </summary>
public readonly record struct SqlTextChange(int Start, int OldLength, int NewLength)
{
    public static SqlTextChange Between(string before, string after)
    {
        ArgumentNullException.ThrowIfNull(before);
        ArgumentNullException.ThrowIfNull(after);
        var prefix = before.AsSpan().CommonPrefixLength(after);
        var limit = Math.Min(before.Length, after.Length) - prefix;
        var suffix = 0;
        while (suffix < limit && before[before.Length - 1 - suffix] == after[after.Length - 1 - suffix])
        {
            suffix++;
        }

        return new SqlTextChange(prefix, before.Length - prefix - suffix, after.Length - prefix - suffix);
    }

    /// <summary>
    /// Where a range of the old text starts in the new one. False when the edit touched it, its edges included,
    /// since typing against a name changes the name the diagnostic was about.
    /// </summary>
    public bool TryMap(int start, int length, out int mapped)
    {
        if (start + length < Start)
        {
            mapped = start;
            return true;
        }

        if (start > Start + OldLength)
        {
            mapped = start + NewLength - OldLength;
            return true;
        }

        mapped = -1;
        return false;
    }
}
