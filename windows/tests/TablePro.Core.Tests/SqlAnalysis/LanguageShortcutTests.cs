using TablePro.Core.Shortcuts;

namespace TablePro.Core.Tests.SqlAnalysis;

/// <summary>
/// The editor's language commands are listed for rebinding but ship unbound: the editor answers to F12, F2, F8,
/// Shift+F8 and Ctrl+Shift+Space itself, so no default can fight a binding the catalogue already has.
/// </summary>
public sealed class LanguageShortcutTests
{
    [Theory]
    [InlineData(ShortcutIds.GoToDefinition, "Go to Definition")]
    [InlineData(ShortcutIds.RenameSymbol, "Rename Symbol")]
    [InlineData(ShortcutIds.NextQueryIssue, "Next Query Issue")]
    [InlineData(ShortcutIds.PreviousQueryIssue, "Previous Query Issue")]
    [InlineData(ShortcutIds.ShowQuickInfo, "Show Quick Info")]
    public void LanguageCommandsAreEditorCommandsWithoutADefaultChord(string id, string title)
    {
        var command = ShortcutCatalog.Get(id);
        Assert.Equal(title, command.Title);
        Assert.True(command.DefaultChord.IsEmpty);
        Assert.Equal(ShortcutContext.Editor, command.Context);
        Assert.Equal(ShortcutCategory.Editor, command.Category);
        Assert.Null(ShortcutMap.Default.CommandFor(new KeyChord(ShortcutKey.F12), ShortcutContext.Editor));
    }
}
