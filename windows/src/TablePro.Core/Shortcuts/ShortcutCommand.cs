namespace TablePro.Core.Shortcuts;

/// <summary>
/// Where a command can fire. The same chord can mean different things in different places because whatever holds
/// focus resolves it, so two commands only conflict when their contexts can be active at once.
/// </summary>
public enum ShortcutContext
{
    /// <summary>A window accelerator: it fires wherever focus is in the workspace window.</summary>
    Global,

    /// <summary>The SQL editor's key handler dispatches it, only while the editor has focus.</summary>
    Editor,

    /// <summary>A table tab's grid dispatches it, only while the grid or its toolbar is showing.</summary>
    DataGrid,
}

/// <summary>Groups commands in the Keyboard settings page by the surface they act on, in the order the page lists them.</summary>
public enum ShortcutCategory
{
    Editor,
    DataGrid,
    Navigation,
    Connections,
    App,
}

public static class ShortcutContextExtensions
{
    /// <summary>
    /// Global overlaps everything, since a window accelerator also fires while the editor or the grid has focus. The
    /// editor and the grid never hold focus together, so they may share a chord.
    /// </summary>
    public static bool Overlaps(this ShortcutContext context, ShortcutContext other) =>
        context == ShortcutContext.Global || other == ShortcutContext.Global || context == other;

    public static string DisplayName(this ShortcutCategory category) => category switch
    {
        ShortcutCategory.Editor => "Editor & Query",
        ShortcutCategory.DataGrid => "Data Grid",
        ShortcutCategory.Navigation => "Navigation",
        ShortcutCategory.Connections => "Connections",
        _ => "App",
    };
}

/// <summary>
/// One customizable command. <see cref="Id"/> is what the settings file stores; it matches the macOS app's action name
/// where the command is the same, so the two stay recognizable side by side.
/// </summary>
/// <param name="Id">The stable name the settings file keys the override by.</param>
/// <param name="Title">What the settings page and the conflict messages call it.</param>
/// <param name="Category">The settings section it is listed under.</param>
/// <param name="Context">Where it can fire, which decides what it conflicts with and who dispatches it.</param>
/// <param name="DefaultChord">Its chord until the user changes it; <see cref="KeyChord.None"/> ships it unbound.</param>
/// <param name="AllowsBareKey">A chord without Ctrl or Alt is accepted. Only for commands of a focused surface where a single key is the convention.</param>
public sealed record ShortcutCommand(
    string Id,
    string Title,
    ShortcutCategory Category,
    ShortcutContext Context,
    KeyChord DefaultChord,
    bool AllowsBareKey = false)
{
    /// <summary>
    /// A shortcut needs Ctrl or Alt, or a function key, so it never swallows a key that types text. Win chords belong
    /// to Windows and are refused separately as system reserved.
    /// </summary>
    public bool Accepts(KeyChord chord) => !chord.IsEmpty && (chord.HasCommandModifier || chord.IsFunctionKey || AllowsBareKey);
}
