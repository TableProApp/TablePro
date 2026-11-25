using System.Globalization;
using TablePro.Editor.Model;
using TablePro.Interop;

namespace TablePro.App.Model;

// The editor answers its keys in KeyDown, before any accelerator; a preset neither takes nor moves a Fixed key.
public enum CommandOwner
{
    MenuAccelerator,
    Editor,
    Fixed,
}

// Where a key reaches: two commands meet only when one press can reach both.
public enum CommandScope
{
    Global,
    Workspace,
    QueryTab,
    TableTab,
    Editor,
    Grid,
}

// One default key of a command; a command with several keys has a row per key.
public sealed record KeymapCommand(string Action, KeyChord? Default, CommandOwner Owner, CommandScope Scope);

// TablePro's keys and the shortcut presets laid over them (core 0057, windows/docs/decisions/0025).
public static class Keymap
{
    public const string TablePro = "tablepro";

    // WinUI refuses them as accelerator keys (KeyboardAcceleratorUtility::IsKeyValidForAccelerators).
    private static readonly HashSet<string> NotAcceleratorKeys =
        new(StringComparer.Ordinal) { "`", "[", "]", "\\", "'" };

    // The editor commands a preset may move; the editor's other commands keep the keys EditorKeymap.Default gives them.
    public static IReadOnlyList<(string Action, EditorCommand Command)> EditorActions { get; } =
    [
        ("find", EditorCommand.Find),
        ("findAndReplace", EditorCommand.Replace),
        ("formatQuery", EditorCommand.FormatQuery),
    ];

    public static IReadOnlyList<KeymapCommand> Commands { get; } = BuildCommands();

    // Null is TablePro's own keys; a preset row wins over the command it displaces, and a refused row is dropped.
    public static EffectiveKeymap Resolve(IReadOnlyList<KeymapBinding>? preset)
    {
        var keys = new Dictionary<string, List<KeyChord>>(StringComparer.Ordinal);
        var commands = new Dictionary<string, KeymapCommand>(StringComparer.Ordinal);
        foreach (var command in Commands)
        {
            if (!keys.TryGetValue(command.Action, out var list))
            {
                keys[command.Action] = list = [];
                commands[command.Action] = command;
            }

            if (command.Default is { } chord)
            {
                list.Add(chord);
            }
        }

        if (preset is null)
        {
            return new EffectiveKeymap(keys, []);
        }

        var accepted = new List<(KeymapCommand Command, KeyChord Chord)>();
        foreach (var binding in preset)
        {
            if (!commands.TryGetValue(binding.Action, out var command) || command.Owner == CommandOwner.Fixed
                || binding.Command)
            {
                continue;
            }

            var chord = KeyChord.From(binding);
            if (!Refused(chord, command) && !HeldByFixed(chord, command.Scope) && !HeldByEditor(chord, command.Scope))
            {
                accepted.Add((command, chord));
            }
        }

        var moved = accepted.Select(row => row.Command.Action).ToHashSet(StringComparer.Ordinal);
        var before = keys.Where(pair => pair.Value.Count > 0).Select(pair => pair.Key).ToList();
        foreach (var (command, chord) in accepted)
        {
            foreach (var other in commands.Values.Where(other => other.Owner != CommandOwner.Fixed
                && !moved.Contains(other.Action) && Overlaps(other.Scope, command.Scope)))
            {
                keys[other.Action].Remove(chord);
            }
        }

        foreach (var group in accepted.GroupBy(row => row.Command.Action, StringComparer.Ordinal))
        {
            keys[group.Key] = [.. group.Select(row => row.Chord)];
        }

        var displaced = before.Where(action => !moved.Contains(action) && keys[action].Count == 0).ToList();
        return new EffectiveKeymap(keys, displaced);
    }

    public static bool Overlaps(CommandScope first, CommandScope second) =>
        first == second
        || first is CommandScope.Global or CommandScope.Workspace
        || second is CommandScope.Global or CommandScope.Workspace
        || (first, second) is (CommandScope.QueryTab, CommandScope.Editor) or (CommandScope.Editor, CommandScope.QueryTab)
                or (CommandScope.QueryTab, CommandScope.Grid) or (CommandScope.Grid, CommandScope.QueryTab)
                or (CommandScope.TableTab, CommandScope.Grid) or (CommandScope.Grid, CommandScope.TableTab);

    // The Win32 keyboard guide: Ctrl+Alt reads as AltGr in some languages and Alt with a letter is an access key.
    private static bool Refused(KeyChord chord, KeymapCommand command) =>
        (chord.Control && chord.Alt)
        || (chord.Alt && (chord.IsLetter || chord.IsDigit))
        || (!chord.Control && !chord.Alt && !chord.IsFunctionKey)
        || (command.Owner == CommandOwner.MenuAccelerator && NotAcceleratorKeys.Contains(chord.Key));

    private static bool HeldByFixed(KeyChord chord, CommandScope scope) => Commands.Any(command =>
        command.Owner == CommandOwner.Fixed && command.Default == chord && Overlaps(command.Scope, scope));

    // The editor's KeyDown runs before any accelerator: its built-in keys and those of the commands no preset moves.
    private static bool HeldByEditor(KeyChord chord, CommandScope scope)
    {
        var key = new EditorKey(chord.Key, chord.Control, chord.Alt, chord.Shift);
        return Overlaps(scope, CommandScope.Editor)
            && (EditorKeymap.IsBuiltIn(key)
                || (EditorKeymap.Default.CommandFor(key) is { } command
                    && !EditorActions.Any(pair => pair.Command == command)));
    }

    private static List<KeymapCommand> BuildCommands()
    {
        var rows = new List<KeymapCommand>();
        void Menu(string action, string? key, CommandScope scope) => rows.Add(
            new KeymapCommand(action, key is null ? null : KeyChord.Parse(key), CommandOwner.MenuAccelerator, scope));
        void Fixed(string action, CommandScope scope, params string[] keys) => rows.AddRange(
            keys.Select(key => new KeymapCommand(action, KeyChord.Parse(key), CommandOwner.Fixed, scope)));

        // The menu bar's keys, windows/docs/decisions/0004-app-shell.md, Commands and keys.
        Menu("newConnection", "ctrl+n", CommandScope.Global);
        Menu("openFile", "ctrl+o", CommandScope.Global);
        Menu("newTab", "ctrl+t", CommandScope.Workspace);
        Menu("closeTab", "ctrl+w", CommandScope.Workspace);
        Menu("reopenClosedTab", "ctrl+shift+t", CommandScope.Workspace);
        Menu("saveChanges", "ctrl+s", CommandScope.Workspace);
        Menu("saveAs", "ctrl+shift+s", CommandScope.Workspace);
        Menu("discardChanges", null, CommandScope.Workspace);
        Menu("exportResults", "ctrl+shift+e", CommandScope.Workspace);
        Menu("showSettings", null, CommandScope.Global);
        Menu("addRow", "ctrl+shift+n", CommandScope.Grid);
        Menu("duplicateRow", "ctrl+shift+d", CommandScope.Grid);
        Menu("previewSQL", "ctrl+shift+p", CommandScope.Grid);
        Menu("manageConnections", "ctrl+shift+h", CommandScope.Global);
        Menu("toggleTableBrowser", "ctrl+b", CommandScope.Workspace);
        Menu("focusSidebarSearch", "ctrl+p", CommandScope.Workspace);
        Menu("toggleHistory", null, CommandScope.Workspace);
        Menu("refresh", "f5", CommandScope.Workspace);
        Menu("openDatabase", "ctrl+k", CommandScope.Workspace);
        // Run takes the selection or the whole text, and a table tab's Run reads its page again.
        Menu("executeAllStatements", "ctrl+enter", CommandScope.Workspace);
        Menu("executeQuery", "ctrl+shift+enter", CommandScope.QueryTab);
        Menu("cancelQuery", "shift+f5", CommandScope.Workspace);
        Menu("toggleFilters", "ctrl+shift+f", CommandScope.TableTab);

        // The editor's own keys a preset may move, windows/docs/decisions/0002-sql-editor-control.md, Input.
        foreach (var (action, command) in EditorActions)
        {
            rows.AddRange(EditorKeymap.Default.KeysOf(command).Select(key => new KeymapCommand(
                action,
                new KeyChord(key.Key, key.Control, key.Alt, key.Shift),
                CommandOwner.Editor,
                CommandScope.Editor)));
        }

        // Windows' well-known keys, which the editor, the grid and every text box answer; HeldByEditor has the rest.
        Fixed("undo", CommandScope.Global, "ctrl+z");
        Fixed("redo", CommandScope.Global, "ctrl+y");
        Fixed("cut", CommandScope.Global, "ctrl+x");
        Fixed("copy", CommandScope.Global, "ctrl+c");
        Fixed("paste", CommandScope.Global, "ctrl+v");
        Fixed("selectAll", CommandScope.Global, "ctrl+a");
        Fixed("delete", CommandScope.Grid, "delete");
        Fixed("help", CommandScope.Global, "f1");
        Fixed("menuBar", CommandScope.Global, "f10");
        Fixed("exit", CommandScope.Global, "alt+f4");

        Fixed("showNextTab", CommandScope.Workspace, "ctrl+tab");
        Fixed("showPreviousTab", CommandScope.Workspace, "ctrl+shift+tab");
        Fixed("closeTabView", CommandScope.Workspace, "ctrl+f4");
        Fixed("selectTab", CommandScope.Workspace, [.. Enumerable.Range(1, 9).Select(number => "ctrl+" + number)]);
        Fixed("renameTab", CommandScope.Workspace, "f2");

        Fixed("moveColumn", CommandScope.Grid, "alt+left", "alt+right");
        Fixed("editCell", CommandScope.Grid, "f2");
        return rows;
    }
}

public sealed class EffectiveKeymap
{
    private static readonly Dictionary<string, string> KeyWords = new(StringComparer.Ordinal)
    {
        ["enter"] = "Enter",
        ["escape"] = "Escape",
        ["space"] = "Space",
        ["tab"] = "Tab",
        ["backspace"] = "Backspace",
        ["delete"] = "Delete",
        ["insert"] = "Insert",
        ["left"] = "Left",
        ["up"] = "Up",
        ["right"] = "Right",
        ["down"] = "Down",
        ["pageup"] = "PageUp",
        ["pagedown"] = "PageDown",
        ["home"] = "Home",
        ["end"] = "End",
    };

    private readonly Dictionary<string, List<KeyChord>> _keys;

    internal EffectiveKeymap(Dictionary<string, List<KeyChord>> keys, IReadOnlyList<string> displaced)
    {
        _keys = keys;
        Displaced = displaced;
    }

    public static EffectiveKeymap TablePro { get; } = Keymap.Resolve(null);

    // Commands that had a key and lost it to a preset row, in the order Keymap.Commands lists them.
    public IReadOnlyList<string> Displaced { get; }

    public IReadOnlyList<KeyChord> KeysOf(string action) =>
        _keys.TryGetValue(action, out var keys) ? keys : [];

    // A single space for none: an empty override lets a menu item keep the text it showed before.
    public string Label(string action, Func<string, string> word)
    {
        ArgumentNullException.ThrowIfNull(word);
        return KeysOf(action) is [var first, ..] ? Text(first, word) : " ";
    }

    public static string Text(KeyChord chord, Func<string, string> word)
    {
        ArgumentNullException.ThrowIfNull(chord);
        ArgumentNullException.ThrowIfNull(word);
        var parts = new List<string>();
        if (chord.Control)
        {
            parts.Add(word("Ctrl"));
        }

        if (chord.Alt)
        {
            parts.Add(word("Alt"));
        }

        if (chord.Shift)
        {
            parts.Add(word("Shift"));
        }

        parts.Add(KeyWords.TryGetValue(chord.Key, out var name) ? word(name) : chord.Key.ToUpperInvariant());
        var join = word("Join");
        return parts.Aggregate((text, part) => string.Format(CultureInfo.CurrentCulture, join, text, part));
    }
}
