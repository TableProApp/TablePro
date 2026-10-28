using TablePro.Core.Shortcuts;

namespace TablePro.Core.Tests.Shortcuts;

public sealed class KeyChordTests
{
    [Theory]
    [InlineData(ShortcutKey.O, ShortcutModifiers.Control | ShortcutModifiers.Shift, "Ctrl+Shift+O")]
    [InlineData(ShortcutKey.Enter, ShortcutModifiers.Control, "Ctrl+Enter")]
    [InlineData(ShortcutKey.F5, ShortcutModifiers.None, "F5")]
    [InlineData(ShortcutKey.Slash, ShortcutModifiers.Control, "Ctrl+/")]
    [InlineData(ShortcutKey.Comma, ShortcutModifiers.Control, "Ctrl+,")]
    [InlineData(ShortcutKey.EqualsSign, ShortcutModifiers.Control, "Ctrl+=")]
    [InlineData(ShortcutKey.Minus, ShortcutModifiers.Control | ShortcutModifiers.Alt, "Ctrl+Alt+-")]
    [InlineData(ShortcutKey.Escape, ShortcutModifiers.None, "Esc")]
    [InlineData(ShortcutKey.PageDown, ShortcutModifiers.Control, "Ctrl+Page Down")]
    [InlineData(ShortcutKey.D7, ShortcutModifiers.Alt, "Alt+7")]
    [InlineData(ShortcutKey.Add, ShortcutModifiers.Control, "Ctrl+Num +")]
    [InlineData(ShortcutKey.Backslash, ShortcutModifiers.Control, "Ctrl+\\")]
    public void FormatsAsWindowsWritesShortcutsAndParsesBack(ShortcutKey key, ShortcutModifiers modifiers, string text)
    {
        var chord = new KeyChord(key, modifiers);
        Assert.Equal(text, chord.ToString());
        Assert.True(KeyChord.TryParse(text, out var parsed));
        Assert.Equal(chord, parsed);
    }

    [Fact]
    public void ModifiersFollowTheStyleGuideOrderWhateverOrderTheyWereGivenIn()
    {
        var chord = new KeyChord(ShortcutKey.K, ShortcutModifiers.Shift | ShortcutModifiers.Alt | ShortcutModifiers.Control | ShortcutModifiers.Windows);
        Assert.Equal("Win+Ctrl+Alt+Shift+K", chord.ToString());
        Assert.Equal(chord, KeyChord.Parse("shift+alt+win+ctrl+k"));
    }

    [Theory]
    [InlineData("ctrl+shift+o", ShortcutKey.O, ShortcutModifiers.Control | ShortcutModifiers.Shift)]
    [InlineData(" Control + Return ", ShortcutKey.Enter, ShortcutModifiers.Control)]
    [InlineData("Ctrl++", ShortcutKey.EqualsSign, ShortcutModifiers.Control)]
    [InlineData("Ctrl+Plus", ShortcutKey.EqualsSign, ShortcutModifiers.Control)]
    [InlineData("Alt+Del", ShortcutKey.Delete, ShortcutModifiers.Alt)]
    [InlineData("Ctrl+PgDn", ShortcutKey.PageDown, ShortcutModifiers.Control)]
    [InlineData("Ctrl+PageDown", ShortcutKey.PageDown, ShortcutModifiers.Control)]
    [InlineData("Ctrl+NumPad3", ShortcutKey.NumPad3, ShortcutModifiers.Control)]
    [InlineData("Ctrl+Num+", ShortcutKey.Add, ShortcutModifiers.Control)]
    [InlineData("Escape", ShortcutKey.Escape, ShortcutModifiers.None)]
    [InlineData("f12", ShortcutKey.F12, ShortcutModifiers.None)]
    public void ParsesTheSpellingsPeopleTypeByHand(string text, ShortcutKey key, ShortcutModifiers modifiers) =>
        Assert.Equal(new KeyChord(key, modifiers), KeyChord.Parse(text));

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("Ctrl+")]
    [InlineData("Ctrl")]
    [InlineData("Ctrl+Ctrl+A")]
    [InlineData("Hyper+A")]
    [InlineData("Ctrl+Shift+Banana")]
    [InlineData("Ctrl+F25")]
    public void RejectsWhatIsNotAShortcut(string text)
    {
        Assert.False(KeyChord.TryParse(text, out var chord));
        Assert.True(chord.IsEmpty);
        Assert.Throws<FormatException>(() => KeyChord.Parse(text));
    }

    [Fact]
    public void AnEmptyChordFormatsAsNothing()
    {
        Assert.True(KeyChord.None.IsEmpty);
        Assert.Equal(string.Empty, KeyChord.None.ToString());
    }

    [Fact]
    public void FormatsIntoASpanWithoutAllocatingAndReportsWhenItDoesNotFit()
    {
        var chord = KeyChord.CtrlShift(ShortcutKey.Enter);
        Span<char> buffer = stackalloc char[32];
        Assert.True(chord.TryFormat(buffer, out var written));
        Assert.Equal("Ctrl+Shift+Enter", buffer[..written].ToString());

        Span<char> tooSmall = stackalloc char[6];
        Assert.False(chord.TryFormat(tooSmall, out _));
    }

    [Fact]
    public void ModifierKeysAreNotChordKeys()
    {
        Assert.False(KeyChord.IsChordKey(0x10));
        Assert.False(KeyChord.IsChordKey(0x11));
        Assert.False(KeyChord.IsChordKey(0x12));
        Assert.False(KeyChord.IsChordKey(0x5B));
        Assert.False(KeyChord.IsChordKey(-1));
        Assert.False(KeyChord.IsChordKey(0x1000));
        Assert.True(KeyChord.IsChordKey((int)ShortcutKey.A));
        Assert.True(KeyChord.IsChordKey((int)ShortcutKey.Slash));
    }

    [Fact]
    public void OnlyCtrlAndAltMakeACommandModifier()
    {
        Assert.True(KeyChord.Ctrl(ShortcutKey.A).HasCommandModifier);
        Assert.True(KeyChord.Alt(ShortcutKey.A).HasCommandModifier);
        Assert.False(KeyChord.Shift(ShortcutKey.A).HasCommandModifier);
        Assert.False(new KeyChord(ShortcutKey.A, ShortcutModifiers.Windows).HasCommandModifier);
        Assert.True(new KeyChord(ShortcutKey.F24).IsFunctionKey);
        Assert.False(new KeyChord(ShortcutKey.Escape).IsFunctionKey);
    }

    [Fact]
    public void ValuesMatchWindowsVirtualKeysSoTheAppCanCast()
    {
        Assert.Equal(0x0D, (int)ShortcutKey.Enter);
        Assert.Equal(0x74, (int)ShortcutKey.F5);
        Assert.Equal(0xBF, (int)ShortcutKey.Slash);
        Assert.Equal(1, (int)ShortcutModifiers.Control);
        Assert.Equal(2, (int)ShortcutModifiers.Alt);
        Assert.Equal(4, (int)ShortcutModifiers.Shift);
        Assert.Equal(8, (int)ShortcutModifiers.Windows);
    }
}
