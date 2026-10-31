namespace TablePro.Core.Editing.MultiCursor;

/// <summary>
/// One caret and its selection. <see cref="Anchor"/> is where the selection started and stays put while it grows;
/// <see cref="Active"/> is the end that moves and where the caret blinks. Both are UTF-16 offsets.
/// <see cref="PreferredColumn"/> is the column Up and Down aim for, kept across short lines so a caret returns to its
/// column on a longer one; -1 when the caret's own column applies.
/// </summary>
public readonly record struct Caret(int Anchor, int Active, int PreferredColumn = -1)
{
    public int Start => Math.Min(Anchor, Active);

    public int End => Math.Max(Anchor, Active);

    public int Length => End - Start;

    public bool IsEmpty => Anchor == Active;

    /// <summary>Whether the active end is the start, as after Shift+Left.</summary>
    public bool IsReversed => Active < Anchor;

    public static Caret At(int offset) => new(offset, offset);

    /// <summary>A selection over a range, its active end last, as a search match or Ctrl+D selects.</summary>
    public static Caret Over(int start, int end) => new(start, end);

    public bool Contains(int offset) => offset >= Start && offset <= End;
}

/// <summary>A replacement of <see cref="Length"/> characters at <see cref="Start"/> with <see cref="Text"/>.</summary>
public readonly record struct TextEdit(int Start, int Length, string Text)
{
    public int End => Start + Length;
}

/// <summary>What an edit was, so the editor can join typing into one undo step the way it joins single keystrokes.</summary>
public enum MultiCursorEditKind
{
    /// <summary>Characters typed or deleted one at a time.</summary>
    Typing,

    /// <summary>Anything that should be an undo step of its own: paste, cut, a word deletion, a kill or a yank.</summary>
    Command,
}

/// <summary>Where a caret moves. Each caret moves from its own active end.</summary>
public enum CaretMotion
{
    Left,
    Right,

    /// <summary>To the start of the word before the caret.</summary>
    WordLeft,

    /// <summary>To the start of the next word, as Ctrl+Right does on Windows.</summary>
    WordRight,

    /// <summary>To the end of the word at or after the caret, as Emacs's M-f and macOS's Option+Right do.</summary>
    WordEnd,
    Up,
    Down,

    /// <summary>To column 0.</summary>
    LineStart,

    /// <summary>To the first non-blank character of the line, or to column 0 when the caret is already there, as Home does.</summary>
    SmartLineStart,
    LineEnd,
    DocumentStart,
    DocumentEnd,
}
