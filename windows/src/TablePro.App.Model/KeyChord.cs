using TablePro.Interop;

namespace TablePro.App.Model;

// A key with its modifiers, the key named as keymaps.json names it ("f", "enter", "f5", ","). Windows has no Command.
public sealed record KeyChord(string Key, bool Control, bool Alt, bool Shift)
{
    private static readonly HashSet<string> NamedKeys = new(StringComparer.Ordinal)
    {
        "left", "up", "right", "down", "pageup", "pagedown", "home", "end",
        "tab", "enter", "escape", "space", "backspace", "delete", "insert",
    };

    private static readonly HashSet<string> Punctuation = new(StringComparer.Ordinal)
    {
        "`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/",
    };

    public bool IsFunctionKey => Key.Length > 1 && Key[0] == 'f' && int.TryParse(Key.AsSpan(1), out var number)
        && number is >= 1 and <= 24;

    public bool IsLetter => Key.Length == 1 && Key[0] is >= 'a' and <= 'z';

    public bool IsDigit => Key.Length == 1 && Key[0] is >= '0' and <= '9';

    public bool IsPunctuation => Punctuation.Contains(Key);

    // Modifiers in any order, then the key; "cmd" is the Windows key, which no chord here takes.
    public static bool TryParse(string text, out KeyChord? chord)
    {
        chord = null;
        if (string.IsNullOrEmpty(text))
        {
            return false;
        }

        // A shifted glyph is its base key with shift, so no key is "+" and every token has text.
        var tokens = text.ToLowerInvariant().Split('+');
        if (tokens.Any(token => token.Length == 0))
        {
            return false;
        }

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

        var key = tokens[^1];
        var candidate = new KeyChord(key, control, alt, shift);
        if (!candidate.IsLetter && !candidate.IsDigit && !candidate.IsFunctionKey && !candidate.IsPunctuation
            && !NamedKeys.Contains(key))
        {
            return false;
        }

        chord = candidate;
        return true;
    }

    public static KeyChord Parse(string text) =>
        TryParse(text, out var chord) ? chord! : throw new FormatException($"Not a key chord: {text}");

    public static KeyChord From(KeymapBinding binding)
    {
        ArgumentNullException.ThrowIfNull(binding);
        return new KeyChord(binding.Key.ToLowerInvariant(), binding.Control, binding.Alt, binding.Shift);
    }

    // As keymaps.json writes it: ctrl, shift, alt, then the key.
    public override string ToString() =>
        (Control ? "ctrl+" : string.Empty) + (Shift ? "shift+" : string.Empty) + (Alt ? "alt+" : string.Empty) + Key;
}
