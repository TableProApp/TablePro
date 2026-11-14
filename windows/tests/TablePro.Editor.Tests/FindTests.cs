using TablePro.Testing;
using Windows.System;

namespace TablePro.Editor.Tests;

public sealed class FindTests
{
    // The app's Edit menu sends the editor these same keys.
    [Fact]
    public Task ControlHShowsTheReplaceRowAndControlFHidesIt() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor { Text = "select a, b, a from t" };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
            editor.Model.SetSelection(7, 8);

            Assert.True(editor.HandleKey(VirtualKey.H, control: true, shift: false, alt: false));
            Assert.True(editor.IsFindOpen);
            Assert.True(editor.IsReplaceOpen);

            editor.ReplaceAll();
            Assert.Equal("select , b,  from t", editor.Document.GetText());
            Assert.True(editor.HandleKey(VirtualKey.Z, control: true, shift: false, alt: false));
            Assert.Equal("select a, b, a from t", editor.Document.GetText());

            Assert.True(editor.HandleKey(VirtualKey.F, control: true, shift: false, alt: false));
            Assert.True(editor.IsFindOpen);
            Assert.False(editor.IsReplaceOpen);
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });
}
