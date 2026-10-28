using System.Collections.Frozen;

namespace TablePro.Core.Vim;

/// <summary>
/// Interprets the Ex commands the editor supports: :w, :q, and :tabnext / :tabprevious / :tabNext with their
/// abbreviations and counts, which gt and gT also send.
/// </summary>
public sealed class VimCommandLineHandler
{
    // A count with no tab strip to measure it against stops here, past any strip's length.
    private const int CountLimit = 999_999;

    // Each spelling Vim accepts, from the shortest abbreviation to the full name.
    private static readonly FrozenDictionary<string, bool> TabCommands = BuildTabCommands();

    /// <summary>:w.</summary>
    public event EventHandler? WriteRequested;

    /// <summary>:q.</summary>
    public event EventHandler? QuitRequested;

    /// <summary>A tab to select by its 1-based position in the tab strip.</summary>
    public event EventHandler<int>? TabSelected;

    /// <summary>A tab to select relative to the current one, positive to the right.</summary>
    public event EventHandler<int>? AdjacentTabSelected;

    /// <summary>How many tabs the strip has, so absolute counts clamp to it and relative ones wrap within it.</summary>
    public Func<int>? TabCount { get; set; }

    private int? Tabs => TabCount?.Invoke() is > 0 and var count ? count : null;

    public void Handle(string command)
    {
        ArgumentNullException.ThrowIfNull(command);
        var trimmed = command.Trim(' ', '\t');
        switch (trimmed)
        {
            case "w":
                WriteRequested?.Invoke(this, EventArgs.Empty);
                break;
            case "q":
                QuitRequested?.Invoke(this, EventArgs.Empty);
                break;
            default:
                HandleTabCommand(trimmed);
                break;
        }
    }

    private static FrozenDictionary<string, bool> BuildTabCommands()
    {
        var names = new Dictionary<string, bool>(StringComparer.Ordinal);
        for (var end = 4; end <= 7; end++)
        {
            names["tabnext"[..end]] = true;
            names["tabNext"[..end]] = false;
        }

        for (var end = 4; end <= 11; end++)
        {
            names["tabprevious"[..end]] = false;
        }

        return names.ToFrozenDictionary(StringComparer.Ordinal);
    }

    private void HandleTabCommand(string command)
    {
        var parts = command.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length is 0 or > 2 || !TabCommands.TryGetValue(parts[0], out var next))
        {
            return;
        }

        var argument = parts.Length == 2 ? parts[1] : null;
        if (!next)
        {
            if (argument is null)
            {
                AdjacentTabSelected?.Invoke(this, -1);
            }
            else if (RelativeCount(argument) is { } count)
            {
                AdjacentTabSelected?.Invoke(this, -count);
            }

            return;
        }

        if (argument is null)
        {
            AdjacentTabSelected?.Invoke(this, 1);
        }
        else if (argument[0] is '+' or '-')
        {
            if (RelativeCount(argument[1..]) is { } offset)
            {
                AdjacentTabSelected?.Invoke(this, argument[0] == '-' ? -offset : offset);
            }
        }
        else if (Count(argument, Tabs ?? CountLimit, modulus: null) is { } number)
        {
            // Past the last tab is the last tab, as Vim's goto_tabpage reads it.
            TabSelected?.Invoke(this, number);
        }
    }

    // Moving by a multiple of the tab count lands where it started, so the move is reduced to less than one lap.
    private int? RelativeCount(string text) => Count(text, CountLimit, Tabs);

    // Read a digit at a time, so a count of any length neither overflows nor leaves the bound.
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
            if (!char.IsAsciiDigit(c))
            {
                return null;
            }

            var digit = c - '0';
            isZero &= digit == 0;
            value = modulus is { } m ? ((value * 10) + digit) % m : Math.Min((value * 10) + digit, cap);
        }

        return isZero ? null : value;
    }
}
