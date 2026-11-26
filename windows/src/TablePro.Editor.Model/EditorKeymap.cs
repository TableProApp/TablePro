using System.Globalization;

namespace TablePro.Editor.Model;

// A key as the core's keymaps.json names it ("f", "enter", "/"), with its modifiers.
public readonly record struct EditorKey(string Key, bool Control, bool Alt, bool Shift)
{
    // Windows virtual-key codes by keymaps.json name; the OEM codes are the US layout's, as the editor reads them.
    private static readonly Dictionary<string, int> Codes = BuildCodes();

    private static readonly Dictionary<int, string> Names = Codes.ToDictionary(pair => pair.Value, pair => pair.Key);

    public static EditorKey? FromVirtualKey(int code, bool control, bool alt, bool shift) =>
        Names.TryGetValue(code, out var name) ? new EditorKey(name, control, alt, shift) : null;

    public static int? VirtualKeyOf(string key) =>
        key is not null && Codes.TryGetValue(key.ToLowerInvariant(), out var code) ? code : null;

    // "ctrl+shift+f": modifiers in any order, then a key VirtualKeyOf knows.
    public static bool TryParse(string text, out EditorKey key)
    {
        key = default;
        if (string.IsNullOrEmpty(text))
        {
            return false;
        }

        var tokens = text.ToLowerInvariant().Split('+');
        bool control = false, alt = false, shift = false;
        foreach (var token in tokens[..^1])
        {
            switch (token)
            {
                case "ctrl" when !control:
                    control = true;
                    break;
                case "alt" when !alt:
                    alt = true;
                    break;
                case "shift" when !shift:
                    shift = true;
                    break;
                default:
                    return false;
            }
        }

        if (!Codes.ContainsKey(tokens[^1]))
        {
            return false;
        }

        key = new EditorKey(tokens[^1], control, alt, shift);
        return true;
    }

    public static EditorKey Parse(string text) =>
        TryParse(text, out var key) ? key : throw new FormatException($"Not an editor key: {text}");

    public override string ToString() =>
        (Control ? "ctrl+" : string.Empty) + (Shift ? "shift+" : string.Empty) + (Alt ? "alt+" : string.Empty) + Key;

    private static Dictionary<string, int> BuildCodes()
    {
        var codes = new Dictionary<string, int>(StringComparer.Ordinal)
        {
            ["backspace"] = 0x08,
            ["tab"] = 0x09,
            ["enter"] = 0x0D,
            ["escape"] = 0x1B,
            ["space"] = 0x20,
            ["pageup"] = 0x21,
            ["pagedown"] = 0x22,
            ["end"] = 0x23,
            ["home"] = 0x24,
            ["left"] = 0x25,
            ["up"] = 0x26,
            ["right"] = 0x27,
            ["down"] = 0x28,
            ["insert"] = 0x2D,
            ["delete"] = 0x2E,
            [";"] = 0xBA,
            ["="] = 0xBB,
            [","] = 0xBC,
            ["-"] = 0xBD,
            ["."] = 0xBE,
            ["/"] = 0xBF,
            ["`"] = 0xC0,
            ["["] = 0xDB,
            ["\\"] = 0xDC,
            ["]"] = 0xDD,
            ["'"] = 0xDE,
        };
        for (var letter = 'a'; letter <= 'z'; letter++)
        {
            codes[letter.ToString()] = 0x41 + (letter - 'a');
        }

        for (var digit = 0; digit <= 9; digit++)
        {
            codes[digit.ToString(CultureInfo.InvariantCulture)] = 0x30 + digit;
        }

        for (var number = 1; number <= 24; number++)
        {
            codes["f" + number.ToString(CultureInfo.InvariantCulture)] = 0x6F + number;
        }

        return codes;
    }
}

// Which command a key runs in the editor; Default holds the keys of windows/docs/decisions/0002-sql-editor-control.md.
public sealed class EditorKeymap
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

    private readonly Dictionary<EditorCommand, List<EditorKey>> _keys;
    private readonly Dictionary<EditorKey, EditorCommand> _commands = [];

    private EditorKeymap(Dictionary<EditorCommand, List<EditorKey>> keys)
    {
        _keys = keys;
        foreach (var (command, list) in keys)
        {
            foreach (var key in list)
            {
                _commands[key] = command;
            }
        }
    }

    // Shift leaves most of these alone, as the editor has always read them.
    public static EditorKeymap Default { get; } = new(new Dictionary<EditorCommand, List<EditorKey>>
    {
        [EditorCommand.Undo] = Keys("ctrl+z"),
        [EditorCommand.Redo] = Keys("ctrl+y", "ctrl+shift+z", "ctrl+shift+y"),
        [EditorCommand.Cut] = Keys("ctrl+x", "ctrl+shift+x"),
        [EditorCommand.Copy] = Keys("ctrl+c", "ctrl+shift+c"),
        [EditorCommand.Paste] = Keys("ctrl+v", "ctrl+shift+v"),
        [EditorCommand.SelectAll] = Keys("ctrl+a", "ctrl+shift+a"),
        [EditorCommand.Find] = Keys("ctrl+f"),
        [EditorCommand.Replace] = Keys("ctrl+h"),
        [EditorCommand.FormatQuery] = Keys("ctrl+shift+f"),
        [EditorCommand.ToggleComment] = Keys("ctrl+/", "ctrl+shift+/"),
        [EditorCommand.DeleteLine] = Keys("ctrl+shift+k"),
        [EditorCommand.NextOccurrence] = Keys("ctrl+d", "ctrl+shift+d"),
        [EditorCommand.Fold] = Keys("ctrl+shift+["),
        [EditorCommand.Unfold] = Keys("ctrl+shift+]"),
    });

    // The caret, selection and text box keys SqlEditor.HandleKey answers itself, before its keymap and any accelerator.
    public static bool IsBuiltIn(EditorKey key) => key.Key switch
    {
        "left" or "right" or "up" or "down" or "home" or "end" or "pageup" or "pagedown" or "backspace" or "delete"
            or "escape" or "f3" => true,
        "enter" or "tab" => !key.Control && !key.Alt,
        "insert" => key.Control != key.Shift,
        "space" or "[" or "]" => key.Control && !key.Alt && !key.Shift,
        "=" or "-" or "0" => key.Control && !key.Alt,
        _ => false,
    };

    public EditorCommand? CommandFor(EditorKey key) => _commands.TryGetValue(key, out var command) ? command : null;

    public IReadOnlyList<EditorKey> KeysOf(EditorCommand command) =>
        _keys.TryGetValue(command, out var keys) ? keys : [];

    // Each command named takes exactly the keys its rows give; a key it takes leaves the command that had it.
    public EditorKeymap With(IReadOnlyList<(EditorCommand Command, EditorKey Key)> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var keys = _keys.ToDictionary(pair => pair.Key, pair => pair.Value.ToList());
        foreach (var command in rows.Select(row => row.Command).Distinct())
        {
            keys[command] = [];
        }

        foreach (var (command, key) in rows)
        {
            foreach (var list in keys.Values)
            {
                list.Remove(key);
            }

            keys[command].Add(key);
        }

        return new EditorKeymap(keys);
    }

    public EditorKeymap Without(IEnumerable<EditorCommand> commands)
    {
        ArgumentNullException.ThrowIfNull(commands);
        var keys = _keys.ToDictionary(pair => pair.Key, pair => pair.Value.ToList());
        foreach (var command in commands)
        {
            keys[command] = [];
        }

        return new EditorKeymap(keys);
    }

    // The first key as Windows words it, empty for none; word gives Ctrl, Alt, Shift, Join and the key names.
    public string Label(EditorCommand command, Func<string, string> word)
    {
        ArgumentNullException.ThrowIfNull(word);
        if (KeysOf(command) is not [var key, ..])
        {
            return string.Empty;
        }

        var parts = new List<string>();
        if (key.Control)
        {
            parts.Add(word("Ctrl"));
        }

        if (key.Alt)
        {
            parts.Add(word("Alt"));
        }

        if (key.Shift)
        {
            parts.Add(word("Shift"));
        }

        parts.Add(KeyWords.TryGetValue(key.Key, out var name) ? word(name) : key.Key.ToUpperInvariant());
        var join = word("Join");
        return parts.Aggregate((text, part) => string.Format(CultureInfo.CurrentCulture, join, text, part));
    }

    private static List<EditorKey> Keys(params string[] texts) => [.. texts.Select(EditorKey.Parse)];
}
