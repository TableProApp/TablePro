namespace TablePro.Editor.Model.Vim;

public enum VimKey
{
    Other,
    Escape,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    Delete,
    Backspace,
    Enter,
    Tab,
    OpenBracket,
    Letter,
}

// A key press before any character it types; Letter is 'A' to 'Z' for VimKey.Letter.
public readonly record struct VimKeyDown(VimKey Key, char Letter = '\0', bool Control = false, bool Shift = false, bool Alt = false);

public enum VimRouteKind
{
    // The editor's own handling, and the app's accelerators after it.
    Editor,
    Engine,
    Discard,
}

public readonly record struct VimRoute(VimRouteKind Kind, string Key = "")
{
    public static VimRoute Editor { get; } = new(VimRouteKind.Editor);

    public static VimRoute Discard { get; } = new(VimRouteKind.Discard);

    public static VimRoute Engine(string key) => new(VimRouteKind.Engine, key);
}

// Which key presses Vim takes on Windows. Characters are always the engine's first; this decides the keys that type
// none. Ctrl is the Windows shortcut key, so Vim takes only the Ctrl chords it defines, and Alt stays with the menus.
public static class VimKeyRouter
{
    private const string Escape = VimEngine.Escape;

    // Ctrl+A, B, D, E, F, R, U, X and Y, and Ctrl+H, N and P as motions, as the macOS engine has them.
    private const string NormalChords = "ABDEFHNPRUXY";

    // Ctrl+D, T, U and W, as Vim's Insert mode has them.
    private const string InsertChords = "DTUW";

    public static VimRoute Route(VimKeyDown key, VimMode mode, bool pending)
    {
        if (key.Alt)
        {
            return VimRoute.Editor;
        }
        if (key.Control)
        {
            return RouteChord(key, mode);
        }
        if (key.Key == VimKey.Escape)
        {
            // With nothing to cancel, Escape closes find or drops extra carets, as it does without Vim.
            return mode == VimMode.Normal && !pending ? VimRoute.Editor : VimRoute.Engine(Escape);
        }
        return mode switch
        {
            VimMode.Insert => key.Key switch
            {
                VimKey.Enter => VimRoute.Engine("\r"),
                VimKey.Backspace => VimRoute.Engine("\b"),
                VimKey.Tab when !key.Shift => VimRoute.Engine("\t"),
                _ => VimRoute.Editor,
            },
            VimMode.Replace => key.Key switch
            {
                VimKey.Enter => VimRoute.Engine("\r"),
                VimKey.Backspace => VimRoute.Engine("\b"),
                VimKey.Tab when !key.Shift => VimRoute.Engine("\t"),
                _ => VimRoute.Editor,
            },
            VimMode.CommandLine => key.Key switch
            {
                VimKey.Enter => VimRoute.Engine("\r"),
                VimKey.Backspace => VimRoute.Engine("\b"),
                VimKey.Letter or VimKey.OpenBracket or VimKey.Other => VimRoute.Editor,
                _ => VimRoute.Discard,
            },
            _ => key.Key switch
            {
                VimKey.Left => VimRoute.Engine("h"),
                VimKey.Right => VimRoute.Engine("l"),
                VimKey.Up => VimRoute.Engine("k"),
                VimKey.Down => VimRoute.Engine("j"),
                VimKey.Home => VimRoute.Engine("0"),
                VimKey.End => VimRoute.Engine("$"),
                VimKey.PageUp => VimRoute.Engine("\u0002"),
                VimKey.PageDown => VimRoute.Engine("\u0006"),
                VimKey.Delete => VimRoute.Engine("x"),
                VimKey.Backspace => VimRoute.Engine("\b"),
                VimKey.Enter => VimRoute.Engine("\r"),
                VimKey.Tab => VimRoute.Discard,
                _ => VimRoute.Editor,
            },
        };
    }

    private static VimRoute RouteChord(VimKeyDown key, VimMode mode)
    {
        if (key.Shift)
        {
            return VimRoute.Editor;
        }
        // Ctrl+[ is Escape in every mode, as a terminal sends it.
        if (key.Key == VimKey.OpenBracket)
        {
            return VimRoute.Engine(Escape);
        }
        if (key.Key != VimKey.Letter)
        {
            return VimRoute.Editor;
        }
        var control = ((char)(key.Letter - 'A' + 1)).ToString();
        return mode switch
        {
            VimMode.Insert or VimMode.Replace => InsertChords.Contains(key.Letter, StringComparison.Ordinal)
                ? VimRoute.Engine(control)
                : VimRoute.Editor,
            VimMode.CommandLine => key.Letter == 'H' ? VimRoute.Engine("\b") : VimRoute.Discard,
            _ => NormalChords.Contains(key.Letter, StringComparison.Ordinal) ? VimRoute.Engine(control) : VimRoute.Editor,
        };
    }
}
