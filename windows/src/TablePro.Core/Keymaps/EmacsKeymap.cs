namespace TablePro.Core.Keymaps;

public enum EmacsMotion
{
    ForwardChar,
    BackwardChar,
    NextLine,
    PreviousLine,
    BeginningOfLine,
    EndOfLine,
    ForwardWord,
    BackwardWord,
}

public enum EmacsCommandKind
{
    Move,
    KillLine,
    KillWord,
    BackwardKillWord,
    KillRegion,
    CopyRegion,
    Yank,
    YankPop,
    SetMark,
    Quit,
}

/// <summary>An Emacs command; <see cref="Motion"/> applies to <see cref="EmacsCommandKind.Move"/> only.</summary>
public readonly record struct EmacsCommand(EmacsCommandKind Kind, EmacsMotion Motion = default)
{
    public static EmacsCommand Move(EmacsMotion motion) => new(EmacsCommandKind.Move, motion);

    public static EmacsCommand Of(EmacsCommandKind kind) => new(kind);
}

/// <summary>The kind of key pressed, for the keys whose character alone does not say what they are.</summary>
public enum EmacsKey
{
    /// <summary>A key that types a character, which <see cref="EmacsKeystroke.Character"/> holds as the key types it without Ctrl or Alt.</summary>
    Character,
    Space,
    Backspace,
    Left,
    Right,
    Up,
    Down,

    /// <summary>Navigation, function and other keys Emacs mode leaves alone.</summary>
    Other,
}

/// <summary>A key press as the editor sees it. Alt is Emacs's Meta, as Option is on macOS.</summary>
public readonly record struct EmacsKeystroke(EmacsKey Key, char Character = '\0', bool Control = false, bool Alt = false, bool Shift = false);

/// <summary>
/// The Emacs bindings the macOS editor has: motions, kills, yank and yank-pop, and a mark. Ctrl stands for Control and
/// Alt for Meta. Keys outside the table stay with the editor, so every other Windows shortcut keeps working.
/// </summary>
public static class EmacsKeymap
{
    public static EmacsCommand? Resolve(EmacsKeystroke keystroke, bool markActive)
    {
        var key = char.ToLowerInvariant(keystroke.Character);
        switch ((keystroke.Control, keystroke.Alt, keystroke.Shift))
        {
            case (true, false, false):
                return keystroke.Key == EmacsKey.Space ? EmacsCommand.Of(EmacsCommandKind.SetMark) : keystroke.Key == EmacsKey.Character ? ControlKey(key) : null;
            case (true, false, true):
                // Ctrl+@ is Ctrl+Shift+2 on a US layout; the layout decides whether the key reports '2' or '@'.
                return keystroke.Key == EmacsKey.Character && key is '@' or '2' ? EmacsCommand.Of(EmacsCommandKind.SetMark) : null;
            case (false, true, false):
                // Alt is Meta only for these keys, so Alt still reaches the access keys and menus for every other one.
                return keystroke.Key switch
                {
                    EmacsKey.Backspace => EmacsCommand.Of(EmacsCommandKind.BackwardKillWord),
                    EmacsKey.Character => MetaKey(key),
                    _ => null,
                };
            case (false, false, false):
                // With an active region the arrows extend it, as every motion does.
                return markActive ? RegionArrow(keystroke.Key) : null;
            default:
                return null;
        }
    }

    private static EmacsCommand? ControlKey(char key) => key switch
    {
        'a' => EmacsCommand.Move(EmacsMotion.BeginningOfLine),
        'e' => EmacsCommand.Move(EmacsMotion.EndOfLine),
        'f' => EmacsCommand.Move(EmacsMotion.ForwardChar),
        'b' => EmacsCommand.Move(EmacsMotion.BackwardChar),
        'n' => EmacsCommand.Move(EmacsMotion.NextLine),
        'p' => EmacsCommand.Move(EmacsMotion.PreviousLine),
        'k' => EmacsCommand.Of(EmacsCommandKind.KillLine),
        'y' => EmacsCommand.Of(EmacsCommandKind.Yank),
        'w' => EmacsCommand.Of(EmacsCommandKind.KillRegion),
        'g' => EmacsCommand.Of(EmacsCommandKind.Quit),
        ' ' => EmacsCommand.Of(EmacsCommandKind.SetMark),
        _ => null,
    };

    private static EmacsCommand? MetaKey(char key) => key switch
    {
        'f' => EmacsCommand.Move(EmacsMotion.ForwardWord),
        'b' => EmacsCommand.Move(EmacsMotion.BackwardWord),
        'd' => EmacsCommand.Of(EmacsCommandKind.KillWord),
        'y' => EmacsCommand.Of(EmacsCommandKind.YankPop),
        'w' => EmacsCommand.Of(EmacsCommandKind.CopyRegion),
        _ => null,
    };

    private static EmacsCommand? RegionArrow(EmacsKey key) => key switch
    {
        EmacsKey.Left => EmacsCommand.Move(EmacsMotion.BackwardChar),
        EmacsKey.Right => EmacsCommand.Move(EmacsMotion.ForwardChar),
        EmacsKey.Up => EmacsCommand.Move(EmacsMotion.PreviousLine),
        EmacsKey.Down => EmacsCommand.Move(EmacsMotion.NextLine),
        _ => null,
    };
}
