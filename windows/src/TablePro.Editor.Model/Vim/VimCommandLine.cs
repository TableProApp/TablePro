namespace TablePro.Editor.Model.Vim;

public abstract record VimExCommand
{
    public sealed record RunQuery : VimExCommand;

    public sealed record CloseTab : VimExCommand;

    // 1-based position in the tab strip.
    public sealed record SelectTab(int Number) : VimExCommand;

    // Tabs to move by, wrapping around the strip.
    public sealed record SelectAdjacentTab(int Offset) : VimExCommand;
}

// The ex commands the macOS app takes (VimCommandLineHandler): :w runs the query, :q closes the tab, and :tabnext,
// :tabprevious and :tabNext, with gt and gT, switch tabs.
public static class VimCommandLine
{
    // A count with no tab strip to measure it against stops here, past any strip's length.
    private const int CountLimit = 999_999;

    // Each spelling Vim accepts, from the shortest abbreviation to the full name.
    private static readonly Dictionary<string, bool> s_tabCommands = BuildTabCommands();

    public static VimExCommand? Parse(string command, int tabCount)
    {
        ArgumentNullException.ThrowIfNull(command);
        var trimmed = command.Trim(' ', '\t');
        switch (trimmed)
        {
            case "w":
                return new VimExCommand.RunQuery();
            case "q":
                return new VimExCommand.CloseTab();
        }
        var parts = trimmed.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length is 0 or > 2 || !s_tabCommands.TryGetValue(parts[0], out var next))
        {
            return null;
        }
        var argument = parts.Length == 2 ? parts[1] : null;
        int? tabs = tabCount > 0 ? tabCount : null;
        if (!next)
        {
            if (argument is null)
            {
                return new VimExCommand.SelectAdjacentTab(-1);
            }
            return Count(argument, CountLimit, tabs) is { } back ? new VimExCommand.SelectAdjacentTab(-back) : null;
        }
        if (argument is null)
        {
            return new VimExCommand.SelectAdjacentTab(1);
        }
        if (argument[0] is '+' or '-')
        {
            if (Count(argument[1..], CountLimit, tabs) is not { } offset)
            {
                return null;
            }
            return new VimExCommand.SelectAdjacentTab(argument[0] == '-' ? -offset : offset);
        }
        // Past the last tab is the last tab, as Vim's goto_tabpage reads it.
        return Count(argument, tabs ?? CountLimit, null) is { } number ? new VimExCommand.SelectTab(number) : null;
    }

    // Read a digit at a time, so a count of any length neither overflows nor leaves the bound. A modulus reduces a move
    // by a multiple of the tab count, which lands where it started, to less than one lap.
    private static int? Count(string text, int cap, int? modulus)
    {
        if (text.Length == 0)
        {
            return null;
        }
        var value = 0;
        var isZero = true;
        foreach (var c in text)
        {
            if (c is < '0' or > '9')
            {
                return null;
            }
            var digit = c - '0';
            isZero &= digit == 0;
            value = modulus is { } lap ? (value * 10 + digit) % lap : Math.Min(value * 10 + digit, cap);
        }
        return isZero ? null : value;
    }

    private static Dictionary<string, bool> BuildTabCommands()
    {
        var names = new Dictionary<string, bool>(StringComparer.Ordinal);
        for (var end = 4; end <= 7; end++)
        {
            names["tabnext"[..end]] = true;
        }
        for (var end = 4; end <= 11; end++)
        {
            names["tabprevious"[..end]] = false;
        }
        for (var end = 4; end <= 7; end++)
        {
            names["tabNext"[..end]] = false;
        }
        return names;
    }
}
