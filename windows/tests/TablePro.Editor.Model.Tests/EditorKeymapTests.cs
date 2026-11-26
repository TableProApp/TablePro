using TablePro.Editor.Model;

namespace TablePro.Editor.Model.Tests;

public sealed class EditorKeymapTests
{
    private static readonly string[] Modifiers = ["", "ctrl+", "ctrl+shift+", "shift+", "alt+", "ctrl+alt+", "ctrl+shift+alt+"];

    private static readonly Dictionary<string, string> English = new(StringComparer.Ordinal)
    {
        ["Ctrl"] = "Ctrl",
        ["Alt"] = "Alt",
        ["Shift"] = "Shift",
        ["Join"] = "{0}+{1}",
        ["Enter"] = "Enter",
    };

    // What SqlEditor.HandleKey's switch ran for these commands before the keymap took them over.
    private static EditorCommand? BeforeTheKeymap(EditorKey key)
    {
        if (!key.Control || key.Alt)
        {
            return null;
        }

        return key.Key switch
        {
            "a" => EditorCommand.SelectAll,
            "c" => EditorCommand.Copy,
            "x" => EditorCommand.Cut,
            "v" => EditorCommand.Paste,
            "z" when key.Shift => EditorCommand.Redo,
            "y" => EditorCommand.Redo,
            "z" => EditorCommand.Undo,
            "d" => EditorCommand.NextOccurrence,
            "f" when key.Shift => EditorCommand.FormatQuery,
            "f" => EditorCommand.Find,
            "h" when !key.Shift => EditorCommand.Replace,
            "k" when key.Shift => EditorCommand.DeleteLine,
            "/" => EditorCommand.ToggleComment,
            "[" when key.Shift => EditorCommand.Fold,
            "]" when key.Shift => EditorCommand.Unfold,
            _ => null,
        };
    }

    [Fact]
    public void TheDefaultRunsWhatTheEditorsSwitchRan()
    {
        var keys = Enumerable.Range(0, 256)
            .SelectMany(code => Modifiers.Select(modifiers => (code, modifiers)))
            .Select(pair => EditorKey.FromVirtualKey(
                pair.code,
                pair.modifiers.Contains("ctrl", StringComparison.Ordinal),
                pair.modifiers.Contains("alt", StringComparison.Ordinal),
                pair.modifiers.Contains("shift", StringComparison.Ordinal)))
            .OfType<EditorKey>()
            .ToList();

        Assert.NotEmpty(keys);
        Assert.All(keys, key => Assert.Equal(BeforeTheKeymap(key), EditorKeymap.Default.CommandFor(key)));
    }

    [Theory]
    [InlineData("left")]
    [InlineData("right")]
    [InlineData("up")]
    [InlineData("down")]
    [InlineData("home")]
    [InlineData("end")]
    [InlineData("pageup")]
    [InlineData("pagedown")]
    [InlineData("backspace")]
    [InlineData("delete")]
    [InlineData("escape")]
    [InlineData("f3")]
    public void TheEditorAnswersItsCaretAndDeleteKeysWhateverTheModifiers(string name)
    {
        string[] modifiers = ["", "ctrl+", "shift+", "alt+", "ctrl+shift+", "ctrl+alt+", "shift+alt+", "ctrl+shift+alt+"];

        Assert.All(modifiers, prefix =>
            Assert.True(EditorKeymap.IsBuiltIn(EditorKey.Parse(prefix + name)), prefix + name));
    }

    [Theory]
    [InlineData("enter", true)]
    [InlineData("shift+enter", true)]
    [InlineData("ctrl+enter", false)]
    [InlineData("alt+enter", false)]
    [InlineData("tab", true)]
    [InlineData("shift+tab", true)]
    [InlineData("ctrl+tab", false)]
    [InlineData("ctrl+insert", true)]
    [InlineData("ctrl+alt+insert", true)]
    [InlineData("shift+insert", true)]
    [InlineData("ctrl+shift+insert", false)]
    [InlineData("alt+insert", false)]
    [InlineData("ctrl+space", true)]
    [InlineData("ctrl+shift+space", false)]
    [InlineData("ctrl+]", true)]
    [InlineData("ctrl+[", true)]
    [InlineData("ctrl+shift+[", false)]
    [InlineData("ctrl+=", true)]
    [InlineData("ctrl+shift+-", true)]
    [InlineData("ctrl+0", true)]
    [InlineData("ctrl+alt+0", false)]
    [InlineData("ctrl+f", false)]
    [InlineData("ctrl+f5", false)]
    public void TheEditorAnswersOtherKeysOnlyWithTheModifiersItsSwitchReads(string text, bool answers)
    {
        Assert.Equal(answers, EditorKeymap.IsBuiltIn(EditorKey.Parse(text)));
    }

    [Fact]
    public void NoKeyOfTheDefaultKeymapIsBuiltIn()
    {
        var keys = Enum.GetValues<EditorCommand>().SelectMany(command => EditorKeymap.Default.KeysOf(command)).ToList();

        Assert.NotEmpty(keys);
        Assert.All(keys, key => Assert.False(EditorKeymap.IsBuiltIn(key), key.ToString()));
    }

    [Theory]
    [InlineData(0x46, "f")]
    [InlineData(0x0D, "enter")]
    [InlineData(0xBF, "/")]
    [InlineData(0xDB, "[")]
    [InlineData(0x74, "f5")]
    [InlineData(0x30, "0")]
    public void AVirtualKeyNamesItsKeyBothWays(int code, string name)
    {
        Assert.Equal(name, EditorKey.FromVirtualKey(code, control: true, alt: false, shift: false)?.Key);
        Assert.Equal(code, EditorKey.VirtualKeyOf(name));
    }

    [Fact]
    public void AMovedCommandTakesItsNewKeyFromWhoeverHadIt()
    {
        var keymap = EditorKeymap.Default.With(
        [
            (EditorCommand.Replace, EditorKey.Parse("ctrl+r")),
            (EditorCommand.FormatQuery, EditorKey.Parse("ctrl+d")),
        ]);

        Assert.Equal(EditorCommand.Replace, keymap.CommandFor(EditorKey.Parse("ctrl+r")));
        Assert.Null(keymap.CommandFor(EditorKey.Parse("ctrl+h")));
        Assert.Equal(EditorCommand.FormatQuery, keymap.CommandFor(EditorKey.Parse("ctrl+d")));
        Assert.Null(keymap.CommandFor(EditorKey.Parse("ctrl+shift+f")));
        Assert.Equal([EditorKey.Parse("ctrl+shift+d")], keymap.KeysOf(EditorCommand.NextOccurrence));
        Assert.Equal(EditorCommand.Find, keymap.CommandFor(EditorKey.Parse("ctrl+f")));
    }

    [Fact]
    public void ACommandLeftWithNoKeyRunsFromNoKey()
    {
        var keymap = EditorKeymap.Default.Without([EditorCommand.Find]);

        Assert.Null(keymap.CommandFor(EditorKey.Parse("ctrl+f")));
        Assert.Empty(keymap.KeysOf(EditorCommand.Find));
        Assert.Equal(string.Empty, keymap.Label(EditorCommand.Find, word => English[word]));
    }

    [Fact]
    public void ALabelNamesTheFirstKeyAsWindowsWordsIt()
    {
        string Word(string id) => English[id];

        Assert.Equal("Ctrl+Shift+F", EditorKeymap.Default.Label(EditorCommand.FormatQuery, Word));
        Assert.Equal("Ctrl+Y", EditorKeymap.Default.Label(EditorCommand.Redo, Word));
        Assert.Equal("Ctrl+/", EditorKeymap.Default.Label(EditorCommand.ToggleComment, Word));
        Assert.Equal("Ctrl+Shift+[", EditorKeymap.Default.Label(EditorCommand.Fold, Word));
    }
}
