namespace TablePro.Core.Shortcuts;

/// <summary>A chord something other than a customizable command already answers to.</summary>
public sealed record ReservedShortcut(KeyChord Chord, string Name);

/// <summary>
/// The chords no command can be bound to, because Windows, the window, the editor or the grid already acts on them and
/// a binding would either never fire or silently take the key from them.
/// </summary>
public static class ReservedShortcuts
{
    /// <summary>
    /// Keys Windows handles before the app sees them, or that every Windows app gives the same meaning. Any chord with
    /// the Windows key is reserved as well; <see cref="IsSystemReserved"/> covers it without listing each one.
    /// </summary>
    public static IReadOnlyList<ReservedShortcut> System { get; } =
    [
        new(KeyChord.Alt(ShortcutKey.F4), "Close Window"),
        new(KeyChord.Alt(ShortcutKey.Tab), "Switch Apps"),
        new(new KeyChord(ShortcutKey.Tab, ShortcutModifiers.Alt | ShortcutModifiers.Shift), "Switch Apps"),
        new(KeyChord.CtrlAlt(ShortcutKey.Tab), "Switch Apps"),
        new(KeyChord.Alt(ShortcutKey.Escape), "Cycle Windows"),
        new(KeyChord.Ctrl(ShortcutKey.Escape), "Start Menu"),
        new(KeyChord.CtrlShift(ShortcutKey.Escape), "Task Manager"),
        new(KeyChord.CtrlAlt(ShortcutKey.Delete), "Security Options"),
        new(KeyChord.Alt(ShortcutKey.Space), "Window Menu"),
        new(KeyChord.Shift(ShortcutKey.F10), "Context Menu"),
        new(new KeyChord(ShortcutKey.F10), "Menu Bar"),
        new(new KeyChord(ShortcutKey.PrintScreen), "Print Screen"),
        new(KeyChord.Alt(ShortcutKey.PrintScreen), "Print Screen"),
    ];

    /// <summary>Keys the workspace window answers to itself, whatever has focus. A new hard-coded window key belongs here too.</summary>
    public static IReadOnlyList<ReservedShortcut> App { get; } = BuildAppShortcuts();

    /// <summary>
    /// Keys the SQL editor keeps for itself. They are not customizable, but a command that can fire while the editor
    /// has focus must not take one from it.
    /// </summary>
    public static IReadOnlyList<ReservedShortcut> EditorBuiltIns { get; } =
    [
        new(KeyChord.Ctrl(ShortcutKey.Space), "Show Completions"),
        new(KeyChord.CtrlShift(ShortcutKey.D), "Duplicate Line"),
        new(KeyChord.Ctrl(ShortcutKey.Z), "Undo"),
        new(KeyChord.Ctrl(ShortcutKey.Y), "Redo"),
        new(KeyChord.CtrlShift(ShortcutKey.Z), "Redo"),

        // The language commands answer to these keys themselves until the user binds the command elsewhere.
        new(new KeyChord(ShortcutKey.F12, ShortcutModifiers.None), "Go to Definition"),
        new(new KeyChord(ShortcutKey.F2, ShortcutModifiers.None), "Rename Symbol"),
        new(new KeyChord(ShortcutKey.F8, ShortcutModifiers.None), "Next Problem"),
        new(KeyChord.Shift(ShortcutKey.F8), "Previous Problem"),
        new(KeyChord.CtrlShift(ShortcutKey.Space), "Quick Info"),
    ];

    /// <summary>The editing keys every Windows text box shares, so the editor and the sidebar filter both rely on them.</summary>
    public static IReadOnlyList<ReservedShortcut> TextEditing { get; } =
    [
        new(KeyChord.Ctrl(ShortcutKey.C), "Copy"),
        new(KeyChord.Ctrl(ShortcutKey.X), "Cut"),
        new(KeyChord.Ctrl(ShortcutKey.V), "Paste"),
        new(KeyChord.Ctrl(ShortcutKey.A), "Select All"),
        new(KeyChord.Ctrl(ShortcutKey.Insert), "Copy"),
        new(KeyChord.Shift(ShortcutKey.Insert), "Paste"),
        new(KeyChord.Shift(ShortcutKey.Delete), "Cut"),
        new(KeyChord.Ctrl(ShortcutKey.Left), "Move Word Left"),
        new(KeyChord.Ctrl(ShortcutKey.Right), "Move Word Right"),
        new(KeyChord.CtrlShift(ShortcutKey.Left), "Select Word Left"),
        new(KeyChord.CtrlShift(ShortcutKey.Right), "Select Word Right"),
        new(KeyChord.Ctrl(ShortcutKey.Up), "Move to Previous Paragraph"),
        new(KeyChord.Ctrl(ShortcutKey.Down), "Move to Next Paragraph"),
        new(KeyChord.Ctrl(ShortcutKey.Home), "Move to Beginning of Document"),
        new(KeyChord.Ctrl(ShortcutKey.End), "Move to End of Document"),
        new(KeyChord.CtrlShift(ShortcutKey.Home), "Select to Beginning of Document"),
        new(KeyChord.CtrlShift(ShortcutKey.End), "Select to End of Document"),
        new(KeyChord.Ctrl(ShortcutKey.Backspace), "Delete Word Backward"),
        new(KeyChord.Ctrl(ShortcutKey.Delete), "Delete Word Forward"),
    ];

    /// <summary>
    /// Keys a table tab's toolbar and grid answer to. They only reach the grid while a table tab is showing, so they
    /// clash with global commands but not with the editor's.
    /// </summary>
    public static IReadOnlyList<ReservedShortcut> DataGridBuiltIns { get; } =
    [
        new(KeyChord.Ctrl(ShortcutKey.R), "Refresh"),
        new(KeyChord.Ctrl(ShortcutKey.I), "Add Row"),
        new(KeyChord.Ctrl(ShortcutKey.S), "Save Changes"),
        new(KeyChord.Ctrl(ShortcutKey.Z), "Undo"),
        new(KeyChord.Ctrl(ShortcutKey.Y), "Redo"),
        new(KeyChord.Ctrl(ShortcutKey.C), "Copy"),
        new(KeyChord.CtrlShift(ShortcutKey.C), "Copy with Headers"),
        new(KeyChord.Ctrl(ShortcutKey.A), "Select All"),
    ];

    /// <summary>Whether Windows owns the chord: any Win chord, and the system keys in <see cref="System"/>.</summary>
    public static bool IsSystemReserved(KeyChord chord) =>
        (chord.Modifiers & ShortcutModifiers.Windows) != 0 || NameIn(System, chord) is not null;

    /// <summary>
    /// The name of the built-in a command in <paramref name="context"/> would shadow, or null. Window keys clash in
    /// every context; the editor's and the text box keys only where the editor can have focus, and the grid's only
    /// where a table tab can.
    /// </summary>
    public static string? ConflictFor(KeyChord chord, ShortcutContext context)
    {
        if (chord.IsEmpty)
        {
            return null;
        }

        if (NameIn(App, chord) is { } app)
        {
            return app;
        }

        if (context is ShortcutContext.Editor or ShortcutContext.Global
            && (NameIn(EditorBuiltIns, chord) ?? NameIn(TextEditing, chord)) is { } editor)
        {
            return editor;
        }

        return context is ShortcutContext.DataGrid or ShortcutContext.Global ? NameIn(DataGridBuiltIns, chord) : null;
    }

    private static string? NameIn(IReadOnlyList<ReservedShortcut> list, KeyChord chord)
    {
        foreach (var reserved in list)
        {
            if (reserved.Chord == chord)
            {
                return reserved.Name;
            }
        }

        return null;
    }

    private static ReservedShortcut[] BuildAppShortcuts()
    {
        var shortcuts = new ReservedShortcut[9];
        for (var n = 1; n <= 9; n++)
        {
            shortcuts[n - 1] = new ReservedShortcut(KeyChord.Ctrl(ShortcutKey.D0 + n), $"Select Tab {n}");
        }

        return shortcuts;
    }
}
