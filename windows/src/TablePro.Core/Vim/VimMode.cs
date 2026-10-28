namespace TablePro.Core.Vim;

public enum VimModeKind
{
    Normal,
    Insert,
    Replace,
    Visual,
    CommandLine,
}

/// <summary>A Vim editing mode. Visual mode carries whether it is linewise; command-line mode carries what was typed.</summary>
public readonly record struct VimMode
{
    private VimMode(VimModeKind kind, bool linewise, string? commandBuffer)
    {
        Kind = kind;
        IsLinewise = linewise;
        CommandBuffer = commandBuffer;
    }

    public static VimMode Normal { get; } = new(VimModeKind.Normal, false, null);

    public static VimMode Insert { get; } = new(VimModeKind.Insert, false, null);

    public static VimMode Replace { get; } = new(VimModeKind.Replace, false, null);

    public VimModeKind Kind { get; }

    /// <summary>Whether a visual mode selects whole lines.</summary>
    public bool IsLinewise { get; }

    /// <summary>The command line as typed, starting with its ':', '/' or '?' prompt; null outside command-line mode.</summary>
    public string? CommandBuffer { get; }

    /// <summary>Whether keys type text, as in insert and replace mode.</summary>
    public bool IsInsert => Kind is VimModeKind.Insert or VimModeKind.Replace;

    public bool IsVisual => Kind == VimModeKind.Visual;

    public bool IsCommandLine => Kind == VimModeKind.CommandLine;

    /// <summary>The label a mode indicator shows.</summary>
    public string DisplayLabel => Kind switch
    {
        VimModeKind.Normal => "NORMAL",
        VimModeKind.Insert => "INSERT",
        VimModeKind.Replace => "REPLACE",
        VimModeKind.Visual => IsLinewise ? "VISUAL LINE" : "VISUAL",
        _ => CommandBuffer ?? string.Empty,
    };

    public static VimMode Visual(bool linewise) => new(VimModeKind.Visual, linewise, null);

    public static VimMode CommandLine(string buffer) => new(VimModeKind.CommandLine, false, buffer);

    public override string ToString() => DisplayLabel;
}
