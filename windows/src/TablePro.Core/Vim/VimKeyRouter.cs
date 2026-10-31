namespace TablePro.Core.Vim;

/// <summary>The kind of key pressed, for the keys whose character alone does not say what they are.</summary>
public enum VimKeyKind
{
    /// <summary>A key that types a character, which <see cref="VimKeystroke.Character"/> holds ('\0' for a dead key).</summary>
    Character,
    Escape,
    Enter,
    Tab,
    Backspace,
    Delete,
    Left,
    Right,
    Up,
    Down,

    /// <summary>Navigation, function and other keys that type nothing.</summary>
    Other,
}

/// <summary>
/// A key press as the editor sees it. <see cref="Character"/> is what the key types under the current keyboard layout
/// and modifiers, so Ctrl+D arrives as '\u0004' and AltGr+8 on a German layout as '['.
/// </summary>
public readonly record struct VimKeystroke(VimKeyKind Kind, char Character = '\0', bool Control = false, bool Alt = false, bool Shift = false);

public enum VimKeyRouteKind
{
    /// <summary>The editor handles the key as it would without Vim.</summary>
    Editor,

    /// <summary>The engine gets <see cref="VimKeyRoute.Key"/>; if it declines, the editor handles the key.</summary>
    Engine,

    /// <summary>Nobody handles the key, so it cannot type into the text outside insert mode.</summary>
    Discard,
}

public readonly record struct VimKeyRoute(VimKeyRouteKind Kind, char Key = '\0')
{
    public static VimKeyRoute Editor { get; } = new(VimKeyRouteKind.Editor);

    public static VimKeyRoute Discard { get; } = new(VimKeyRouteKind.Discard);

    public static VimKeyRoute Engine(char key) => new(VimKeyRouteKind.Engine, key);
}

/// <summary>
/// Decides which keys the Vim engine sees. Windows editing shortcuts stay with the editor in every mode (Ctrl+C, V,
/// Z, Y, S, F, H, Enter, Ctrl+/), so Vim only takes the Control chords Windows leaves free in the editor.
/// </summary>
public static class VimKeyRouter
{
    private const char Escape = VimEngine.Escape;

    public static VimKeyRoute Route(VimKeystroke keystroke, VimMode mode)
    {
        if (keystroke.Kind == VimKeyKind.Escape || (keystroke.Control && !keystroke.Alt && keystroke.Character == Escape))
        {
            return VimKeyRoute.Engine(Escape);
        }

        return mode.IsInsert ? RouteInInsertModes(keystroke, mode) : RouteOutsideInsertModes(keystroke, mode);
    }

    private static bool IsAltGr(VimKeystroke keystroke) =>
        keystroke.Control && keystroke.Alt && keystroke.Character != '\0' && !char.IsControl(keystroke.Character);

    private static VimKeyRoute RouteInInsertModes(VimKeystroke keystroke, VimMode mode)
    {
        var replace = mode.Kind == VimModeKind.Replace;
        if (keystroke.Control && !keystroke.Alt)
        {
            return VimEngine.IsInsertControl(keystroke.Character) ? VimKeyRoute.Engine(keystroke.Character) : VimKeyRoute.Editor;
        }

        if (keystroke.Alt && !IsAltGr(keystroke))
        {
            return VimKeyRoute.Editor;
        }

        // Insert mode hands typing to the engine only so a recording macro sees it; the engine passes it back.
        return keystroke.Kind switch
        {
            VimKeyKind.Character when keystroke.Character != '\0' && !char.IsControl(keystroke.Character) => VimKeyRoute.Engine(keystroke.Character),
            VimKeyKind.Enter => VimKeyRoute.Engine('\r'),
            VimKeyKind.Backspace => VimKeyRoute.Engine('\b'),
            VimKeyKind.Tab when !replace && !keystroke.Shift => VimKeyRoute.Engine('\t'),
            _ => VimKeyRoute.Editor,
        };
    }

    private static VimKeyRoute RouteOutsideInsertModes(VimKeystroke keystroke, VimMode mode)
    {
        if (IsAltGr(keystroke))
        {
            return VimKeyRoute.Engine(keystroke.Character);
        }

        if (keystroke.Control)
        {
            return RouteControlChord(keystroke, mode);
        }

        if (keystroke.Alt)
        {
            return VimKeyRoute.Editor;
        }

        var commandLine = mode.IsCommandLine;
        switch (keystroke.Kind)
        {
            case VimKeyKind.Character:
                return keystroke.Character == '\0' || char.IsControl(keystroke.Character)
                    ? VimKeyRoute.Discard
                    : VimKeyRoute.Engine(keystroke.Character);
            case VimKeyKind.Enter:
                return VimKeyRoute.Engine('\r');
            case VimKeyKind.Tab:
                return commandLine ? VimKeyRoute.Discard : VimKeyRoute.Engine('\t');
            case VimKeyKind.Backspace:
                return VimKeyRoute.Engine('\b');
            case VimKeyKind.Delete:
                return commandLine ? VimKeyRoute.Discard : VimKeyRoute.Engine('x');
            case VimKeyKind.Left:
                return commandLine ? VimKeyRoute.Discard : VimKeyRoute.Engine('h');
            case VimKeyKind.Right:
                return commandLine ? VimKeyRoute.Discard : VimKeyRoute.Engine('l');
            case VimKeyKind.Up:
                return commandLine ? VimKeyRoute.Discard : VimKeyRoute.Engine('k');
            case VimKeyKind.Down:
                return commandLine ? VimKeyRoute.Discard : VimKeyRoute.Engine('j');
            default:
                return VimKeyRoute.Editor;
        }
    }

    /// <summary>
    /// Vim's scroll, redo, increment and line-motion chords where the editor has no shortcut of its own. Ctrl+A and
    /// Ctrl+X only replace Select All and Cut in normal mode, where there is no selection to act on.
    /// </summary>
    private static VimKeyRoute RouteControlChord(VimKeystroke keystroke, VimMode mode)
    {
        if (keystroke.Alt)
        {
            return VimKeyRoute.Editor;
        }

        if (keystroke.Kind == VimKeyKind.Character && keystroke.Character == ' ')
        {
            // Completion would type into the text outside insert mode.
            return VimKeyRoute.Discard;
        }

        if (keystroke.Kind != VimKeyKind.Character || mode.IsCommandLine)
        {
            return VimKeyRoute.Editor;
        }

        var claimed = keystroke.Character switch
        {
            '\u0002' or '\u0004' or '\u0015' or '\u000E' or '\u0010' => true,
            '\u0001' or '\u0012' or '\u0018' => mode.Kind == VimModeKind.Normal,
            _ => false,
        };
        return claimed ? VimKeyRoute.Engine(keystroke.Character) : VimKeyRoute.Editor;
    }
}
