using TablePro.Editor.Model.Vim;
using TablePro.Testing;
using Windows.System;

namespace TablePro.Editor.Tests;

// The key routing, block caret and commands around the engine the model's tests cover.
public sealed class VimTests
{
    private static void Type(SqlEditor editor, string text)
    {
        foreach (var c in text)
        {
            if (!editor.RouteVimText(c.ToString(), shift: false))
            {
                editor.TypeText(c.ToString());
            }
        }
    }

    // A change is drawn on a later frame, once the swap chain takes it.
    private static async Task<bool> DrawnAsync(Func<bool> done)
    {
        for (var i = 0; i < 300 && !done(); i++)
        {
            await WinUiApp.NextFrameAsync();
        }
        return done();
    }

    private static bool Key(SqlEditor editor, VirtualKey key, bool control = false) =>
        editor.HandleVimKey(key, control, shift: false, alt: false);

    [Fact]
    public Task NormalModeKeysEditAndInsertModeTypes() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor { Text = "select 1;", IsVimEnabled = true };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
            Assert.True(editor.DrawsBlockCaret);
            Type(editor, "x");
            Assert.Equal("elect 1;", editor.Document.GetText());

            Type(editor, "iS");
            Assert.Equal(VimMode.Insert, editor.Vim!.Mode);
            Assert.False(editor.DrawsBlockCaret);
            Assert.Equal("Select 1;", editor.Document.GetText());

            Assert.True(Key(editor, VirtualKey.Escape));
            Assert.Equal(VimMode.Normal, editor.Vim.Mode);
            Assert.Equal(0, editor.Model.Primary.Active);

            Type(editor, "u");
            Assert.Equal("elect 1;", editor.Document.GetText());
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });

    // An input method commits a word at once; Replace mode overwrites a character for each of its characters.
    [Fact]
    public Task ReplaceModeOverwritesACharacterForEachCommittedOne() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor { Text = "abcd", IsVimEnabled = true };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
            Type(editor, "R");
            Assert.True(editor.RouteVimText("\u4E2D\u6587", shift: false));
            Assert.Equal("\u4E2D\u6587cd", editor.Document.GetText());
            Assert.True(Key(editor, VirtualKey.Back));
            Assert.Equal("\u4E2Dbcd", editor.Document.GetText());
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });

    [Fact]
    public Task VimTakesItsOwnControlChordsAndLeavesTheRest() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor { Text = "select 41;", IsVimEnabled = true };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
            // Ctrl+A is Vim's increment here, not Select All.
            Assert.True(Key(editor, VirtualKey.A, control: true));
            Assert.Equal("select 42;", editor.Document.GetText());
            Assert.True(editor.Model.Primary.IsEmpty);
            Assert.False(Key(editor, VirtualKey.Enter, control: true));
            Assert.True(Key(editor, VirtualKey.Left));
            Assert.Equal(7, editor.Model.Primary.Active);
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });

    [Fact]
    public Task TheBlockCaretCoversTheCharacterUnderIt() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor { Text = "select 1;" };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
            Assert.Equal(0, editor.FirstCaretBlockWidth);

            editor.IsVimEnabled = true;
            Assert.True(await DrawnAsync(() => editor.FirstCaretBlockWidth > 1), "no block caret drawn");

            editor.IsVimEnabled = false;
            Assert.True(await DrawnAsync(() => editor.FirstCaretBlockWidth == 0), "the block stayed after Vim went off");
            Assert.Null(editor.Vim);
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });

    [Fact]
    public Task ExCommandsAndTabKeysReachTheHost() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor { Text = "select 1;", IsVimEnabled = true };
        var commands = new List<string>();
        editor.VimCommand += (_, command) => commands.Add(command);
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
            Type(editor, ":q");
            Assert.Equal(":q", editor.Vim!.ModeLabel);
            Assert.True(Key(editor, VirtualKey.Enter));
            Type(editor, "2gt");
            Assert.Equal(["q", "tabnext 2"], commands);
            Assert.Equal("select 1;", editor.Document.GetText());
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });

    [Fact]
    public Task ZcFoldsAndZoOpensTheRegionAtTheCaret() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor
        {
            Text = "select a,\n  b\nfrom t;\nselect 1;",
            Lexer = new StructureTests.TestLexer(),
            IsVimEnabled = true,
        };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
            Type(editor, "zc");
            Assert.Single(editor.Folds);
            Type(editor, "j");
            Assert.Equal(3, editor.Document.GetLineFromOffset(editor.Model.Primary.Active));
            Type(editor, "kzo");
            Assert.Empty(editor.Folds);
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });
}
