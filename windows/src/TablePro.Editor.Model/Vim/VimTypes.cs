namespace TablePro.Editor.Model.Vim;

public enum VimMode
{
    Normal,
    Insert,
    Replace,
    Visual,
    VisualLine,
    CommandLine,
}

public static class VimModes
{
    // Insert and Replace leave typing to the editor.
    public static bool IsInsert(this VimMode mode) => mode is VimMode.Insert or VimMode.Replace;

    public static bool IsVisual(this VimMode mode) => mode is VimMode.Visual or VimMode.VisualLine;
}

// What the editor around the engine does for it: what is on screen, the clipboard, scrolling, folds and commands.
public interface IVimHost
{
    // The first and last rows on screen, inclusive.
    (int First, int Last) VisibleRows();

    void WriteClipboard(string text);

    void ScrollRows(int rows);

    void ScrollCaret(VimScroll position);

    void Fold(VimFold command);

    // An ex command, or gt and gT as "tabnext" and "tabprevious"; VimCommandLine reads it.
    void Command(string command);
}

// Keys Insert mode leaves to the editor, which a macro still replays.
public enum VimEditorKey
{
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    Delete,
}

public enum VimScroll
{
    Top,
    Middle,
    Bottom,
}

public enum VimFold
{
    Open,
    Close,
    Toggle,
    OpenAll,
    CloseAll,
}

// UTF-16 offsets into the editor's text, as NSRange counts them on macOS.
internal readonly record struct VimRange(int Location, int Length)
{
    public int End => Location + Length;
}

public sealed record VimRegister(string Text = "", bool IsLinewise = false);

// Registers and macros belong to the app, not one editor, as Vim keeps them across buffers.
public sealed class VimRegisters
{
    public static VimRegisters Shared { get; } = new();

    internal VimRegister Unnamed { get; set; } = new();

    internal VimRegister[] Numbered { get; } = [.. Enumerable.Repeat(new VimRegister(), 10)];

    internal Dictionary<string, VimRegister> Named { get; } = new(StringComparer.Ordinal);

    internal Dictionary<string, List<VimKeystroke>> Macros { get; } = new(StringComparer.Ordinal);

    internal string? LastInvokedMacro { get; set; }
}

internal readonly record struct VimKeystroke(string Key, bool Shift);

internal enum VimOperator
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

internal sealed record VimFindCharRequest(bool Forward, bool Till);

internal sealed record VimLastFindChar(string Char, bool Forward, bool Till);

internal abstract record VimDotKind
{
    public sealed record DeleteCharForward(int Count) : VimDotKind;

    public sealed record DeleteCharBackward(int Count) : VimDotKind;

    public sealed record OperatorWithMotion(VimOperator Op, string Motion, bool Shift, int Count) : VimDotKind;

    public sealed record OperatorDoubled(VimOperator Op, int Count) : VimDotKind;

    public sealed record ToggleCase(int Count) : VimDotKind;

    public sealed record JoinLines(bool WithSpace, int Count) : VimDotKind;

    public sealed record ReplaceChar(string Char, int Count) : VimDotKind;
}

internal enum VimMacroPendingKind
{
    RecordTarget,
    ReplayTarget,
}

internal enum VimBracketPending
{
    OpenBracket,
    CloseBracket,
}

internal sealed record VimReplaceModeEdit(int Offset, string? Original, int InsertedLength);
