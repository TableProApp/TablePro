namespace TablePro.Core.Vim;

/// <summary>Text held by a register, and whether it was taken as whole lines, which decides how it pastes.</summary>
public readonly record struct VimRegister(string Text, bool IsLinewise)
{
    public static VimRegister Empty { get; } = new(string.Empty, false);

    public bool IsEmpty => string.IsNullOrEmpty(Text);
}

public enum VimOperator
{
    Delete,
    Yank,
    Change,
    Lowercase,
    Uppercase,
    ToggleCase,
    Indent,
    Outdent,
}
