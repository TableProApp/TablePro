using System.Collections.Frozen;
using System.Diagnostics.CodeAnalysis;
using System.Globalization;

namespace TablePro.Core.Shortcuts;

/// <summary>
/// The modifier keys of a chord. The values are those of <c>Windows.System.VirtualKeyModifiers</c>, so the app converts
/// between the two with a cast and Core still references no UI.
/// </summary>
[Flags]
public enum ShortcutModifiers
{
    None = 0,
    Control = 1,
    Alt = 2,
    Shift = 4,
    Windows = 8,
}

/// <summary>
/// The keys a chord can end in. The values are Win32 virtual-key codes, the same numbers <c>Windows.System.VirtualKey</c>
/// uses, so a recorded key casts straight across. The punctuation keys are named for what they type on a US layout,
/// which is how Windows itself labels them in menus whatever the layout.
/// </summary>
public enum ShortcutKey
{
    None = 0,
    Backspace = 0x08,
    Tab = 0x09,
    Enter = 0x0D,
    Pause = 0x13,
    Escape = 0x1B,
    Space = 0x20,
    PageUp = 0x21,
    PageDown = 0x22,
    End = 0x23,
    Home = 0x24,
    Left = 0x25,
    Up = 0x26,
    Right = 0x27,
    Down = 0x28,
    PrintScreen = 0x2C,
    Insert = 0x2D,
    Delete = 0x2E,
    D0 = 0x30,
    D1,
    D2,
    D3,
    D4,
    D5,
    D6,
    D7,
    D8,
    D9,
    A = 0x41,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,
    Application = 0x5D,
    NumPad0 = 0x60,
    NumPad1,
    NumPad2,
    NumPad3,
    NumPad4,
    NumPad5,
    NumPad6,
    NumPad7,
    NumPad8,
    NumPad9,
    Multiply = 0x6A,
    Add = 0x6B,
    Subtract = 0x6D,
    Decimal = 0x6E,
    Divide = 0x6F,
    F1 = 0x70,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    F13,
    F14,
    F15,
    F16,
    F17,
    F18,
    F19,
    F20,
    F21,
    F22,
    F23,
    F24,
    Semicolon = 0xBA,
    EqualsSign = 0xBB,
    Comma = 0xBC,
    Minus = 0xBD,
    Period = 0xBE,
    Slash = 0xBF,
    Backtick = 0xC0,
    LeftBracket = 0xDB,
    Backslash = 0xDC,
    RightBracket = 0xDD,
    Quote = 0xDE,
}

/// <summary>
/// A key with its modifiers, written as Windows writes shortcuts: <c>Ctrl+Shift+O</c>, modifiers in the order of the
/// Microsoft style guide (Win, Ctrl, Alt, Shift). <see cref="ToString()"/> and <see cref="TryParse(ReadOnlySpan{char}, out KeyChord)"/>
/// round-trip, which is how a chord is stored in settings.
/// </summary>
public readonly record struct KeyChord(ShortcutKey Key, ShortcutModifiers Modifiers = ShortcutModifiers.None)
    : ISpanFormattable, ISpanParsable<KeyChord>
{
    private const int MaxLength = 32;

    private static readonly string?[] Names = BuildNames();

    private static readonly FrozenDictionary<string, ShortcutKey> KeysByName = BuildKeyLookup();

    private static readonly FrozenDictionary<string, ShortcutKey>.AlternateLookup<ReadOnlySpan<char>> KeysBySpan =
        KeysByName.GetAlternateLookup<ReadOnlySpan<char>>();

    /// <summary>No chord: an unbound command, or one the user cleared.</summary>
    public static KeyChord None => default;

    public bool IsEmpty => Key == ShortcutKey.None;

    public bool IsFunctionKey => Key is >= ShortcutKey.F1 and <= ShortcutKey.F24;

    /// <summary>Ctrl or Alt is held. Shift alone only changes what a key types, so it never makes a shortcut on its own.</summary>
    public bool HasCommandModifier => (Modifiers & (ShortcutModifiers.Control | ShortcutModifiers.Alt)) != 0;

    public static KeyChord Ctrl(ShortcutKey key) => new(key, ShortcutModifiers.Control);

    public static KeyChord CtrlShift(ShortcutKey key) => new(key, ShortcutModifiers.Control | ShortcutModifiers.Shift);

    public static KeyChord CtrlAlt(ShortcutKey key) => new(key, ShortcutModifiers.Control | ShortcutModifiers.Alt);

    public static KeyChord Alt(ShortcutKey key) => new(key, ShortcutModifiers.Alt);

    public static KeyChord Shift(ShortcutKey key) => new(key, ShortcutModifiers.Shift);

    /// <summary>The label of a key alone, such as <c>Enter</c> or <c>/</c>; empty for a key this type does not name.</summary>
    public static string KeyName(ShortcutKey key) => (uint)key < (uint)Names.Length ? Names[(int)key] ?? string.Empty : string.Empty;

    /// <summary>Whether a virtual-key code names a key a chord can end in, and not a modifier or an unnamed key.</summary>
    public static bool IsChordKey(int virtualKey) => (uint)virtualKey < (uint)Names.Length && Names[virtualKey] is not null;

    public static KeyChord Parse(string s) => Parse(s, null);

    public static KeyChord Parse(string s, IFormatProvider? provider) =>
        TryParse(s.AsSpan(), out var chord) ? chord : throw new FormatException($"'{s}' is not a keyboard shortcut.");

    public static KeyChord Parse(ReadOnlySpan<char> s, IFormatProvider? provider) =>
        TryParse(s, out var chord) ? chord : throw new FormatException($"'{s}' is not a keyboard shortcut.");

    public static bool TryParse([NotNullWhen(true)] string? s, IFormatProvider? provider, out KeyChord result) =>
        TryParse(s.AsSpan(), out result);

    public static bool TryParse(ReadOnlySpan<char> s, IFormatProvider? provider, out KeyChord result) => TryParse(s, out result);

    /// <summary>
    /// Reads <c>Ctrl+Shift+O</c>, ignoring case and spaces around each part. <c>Control</c>, <c>Win</c> and key aliases
    /// such as <c>Return</c>, <c>Esc</c>, <c>Del</c> and <c>Plus</c> are accepted too, since people edit the settings
    /// file by hand.
    /// </summary>
    public static bool TryParse(ReadOnlySpan<char> s, out KeyChord result)
    {
        result = default;
        s = s.Trim();
        if (s.IsEmpty)
        {
            return false;
        }

        // The key may itself be '+' (Ctrl++), so the delimiter before it is the last '+' short of the final character.
        var split = s[..^1].LastIndexOf('+');
        var keyText = s[(split + 1)..].Trim();
        if (!KeysBySpan.TryGetValue(keyText, out var key))
        {
            return false;
        }

        var modifiers = ShortcutModifiers.None;
        var rest = split < 0 ? ReadOnlySpan<char>.Empty : s[..split];
        while (split >= 0)
        {
            var next = rest.IndexOf('+');
            var token = (next < 0 ? rest : rest[..next]).Trim();
            var modifier = ModifierOf(token);
            if (modifier == ShortcutModifiers.None || (modifiers & modifier) != 0)
            {
                return false;
            }

            modifiers |= modifier;
            if (next < 0)
            {
                break;
            }

            rest = rest[(next + 1)..];
        }

        result = new KeyChord(key, modifiers);
        return true;
    }

    public override string ToString()
    {
        if (IsEmpty)
        {
            return string.Empty;
        }

        Span<char> buffer = stackalloc char[MaxLength];
        return TryFormat(buffer, out var written) ? new string(buffer[..written]) : string.Empty;
    }

    public string ToString(string? format, IFormatProvider? formatProvider) => ToString();

    public bool TryFormat(Span<char> destination, out int charsWritten, ReadOnlySpan<char> format = default, IFormatProvider? provider = null)
    {
        charsWritten = 0;
        if (IsEmpty)
        {
            return true;
        }

        var name = KeyName(Key);
        if (name.Length == 0)
        {
            return false;
        }

        var written = 0;
        if (!Append(destination, ref written, (Modifiers & ShortcutModifiers.Windows) != 0 ? "Win+" : string.Empty)
            || !Append(destination, ref written, (Modifiers & ShortcutModifiers.Control) != 0 ? "Ctrl+" : string.Empty)
            || !Append(destination, ref written, (Modifiers & ShortcutModifiers.Alt) != 0 ? "Alt+" : string.Empty)
            || !Append(destination, ref written, (Modifiers & ShortcutModifiers.Shift) != 0 ? "Shift+" : string.Empty)
            || !Append(destination, ref written, name))
        {
            return false;
        }

        charsWritten = written;
        return true;
    }

    private static bool Append(Span<char> destination, ref int written, string text)
    {
        if (!text.AsSpan().TryCopyTo(destination[written..]))
        {
            return false;
        }

        written += text.Length;
        return true;
    }

    private static ShortcutModifiers ModifierOf(ReadOnlySpan<char> token)
    {
        if (token.Equals("Ctrl", StringComparison.OrdinalIgnoreCase) || token.Equals("Control", StringComparison.OrdinalIgnoreCase))
        {
            return ShortcutModifiers.Control;
        }

        if (token.Equals("Alt", StringComparison.OrdinalIgnoreCase) || token.Equals("Menu", StringComparison.OrdinalIgnoreCase))
        {
            return ShortcutModifiers.Alt;
        }

        if (token.Equals("Shift", StringComparison.OrdinalIgnoreCase))
        {
            return ShortcutModifiers.Shift;
        }

        return token.Equals("Win", StringComparison.OrdinalIgnoreCase) || token.Equals("Windows", StringComparison.OrdinalIgnoreCase)
            ? ShortcutModifiers.Windows
            : ShortcutModifiers.None;
    }

    private static string?[] BuildNames()
    {
        var names = new string?[0xDF];
        names[(int)ShortcutKey.Backspace] = "Backspace";
        names[(int)ShortcutKey.Tab] = "Tab";
        names[(int)ShortcutKey.Enter] = "Enter";
        names[(int)ShortcutKey.Pause] = "Pause";
        names[(int)ShortcutKey.Escape] = "Esc";
        names[(int)ShortcutKey.Space] = "Space";
        names[(int)ShortcutKey.PageUp] = "Page Up";
        names[(int)ShortcutKey.PageDown] = "Page Down";
        names[(int)ShortcutKey.End] = "End";
        names[(int)ShortcutKey.Home] = "Home";
        names[(int)ShortcutKey.Left] = "Left";
        names[(int)ShortcutKey.Up] = "Up";
        names[(int)ShortcutKey.Right] = "Right";
        names[(int)ShortcutKey.Down] = "Down";
        names[(int)ShortcutKey.PrintScreen] = "Print Screen";
        names[(int)ShortcutKey.Insert] = "Insert";
        names[(int)ShortcutKey.Delete] = "Delete";
        names[(int)ShortcutKey.Application] = "Menu";
        for (var c = '0'; c <= '9'; c++)
        {
            names[c] = c.ToString();
            names[(int)ShortcutKey.NumPad0 + (c - '0')] = "Num " + c;
        }

        for (var c = 'A'; c <= 'Z'; c++)
        {
            names[c] = c.ToString();
        }

        for (var i = 0; i < 24; i++)
        {
            names[(int)ShortcutKey.F1 + i] = "F" + (i + 1).ToString(CultureInfo.InvariantCulture);
        }

        names[(int)ShortcutKey.Multiply] = "Num *";
        names[(int)ShortcutKey.Add] = "Num +";
        names[(int)ShortcutKey.Subtract] = "Num -";
        names[(int)ShortcutKey.Decimal] = "Num .";
        names[(int)ShortcutKey.Divide] = "Num /";
        names[(int)ShortcutKey.Semicolon] = ";";
        names[(int)ShortcutKey.EqualsSign] = "=";
        names[(int)ShortcutKey.Comma] = ",";
        names[(int)ShortcutKey.Minus] = "-";
        names[(int)ShortcutKey.Period] = ".";
        names[(int)ShortcutKey.Slash] = "/";
        names[(int)ShortcutKey.Backtick] = "`";
        names[(int)ShortcutKey.LeftBracket] = "[";
        names[(int)ShortcutKey.Backslash] = "\\";
        names[(int)ShortcutKey.RightBracket] = "]";
        names[(int)ShortcutKey.Quote] = "'";
        return names;
    }

    private static FrozenDictionary<string, ShortcutKey> BuildKeyLookup()
    {
        var lookup = new Dictionary<string, ShortcutKey>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < Names.Length; i++)
        {
            if (Names[i] is { } name)
            {
                lookup[name] = (ShortcutKey)i;
                if (name.Contains(' ', StringComparison.Ordinal))
                {
                    lookup[name.Replace(" ", string.Empty, StringComparison.Ordinal)] = (ShortcutKey)i;
                }
            }
        }

        lookup["Return"] = ShortcutKey.Enter;
        lookup["Escape"] = ShortcutKey.Escape;
        lookup["Del"] = ShortcutKey.Delete;
        lookup["Ins"] = ShortcutKey.Insert;
        lookup["PgUp"] = ShortcutKey.PageUp;
        lookup["PgDn"] = ShortcutKey.PageDown;
        lookup["Back"] = ShortcutKey.Backspace;
        lookup["Plus"] = ShortcutKey.EqualsSign;
        lookup["+"] = ShortcutKey.EqualsSign;
        lookup["Minus"] = ShortcutKey.Minus;
        lookup["Comma"] = ShortcutKey.Comma;
        lookup["Period"] = ShortcutKey.Period;
        lookup["Slash"] = ShortcutKey.Slash;
        lookup["Backslash"] = ShortcutKey.Backslash;
        lookup["Semicolon"] = ShortcutKey.Semicolon;
        lookup["Quote"] = ShortcutKey.Quote;
        lookup["Backtick"] = ShortcutKey.Backtick;
        lookup["PrtScn"] = ShortcutKey.PrintScreen;
        lookup["Apps"] = ShortcutKey.Application;
        for (var i = 0; i < 10; i++)
        {
            lookup["NumPad" + i.ToString(CultureInfo.InvariantCulture)] = ShortcutKey.NumPad0 + i;
        }

        return lookup.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase);
    }
}
