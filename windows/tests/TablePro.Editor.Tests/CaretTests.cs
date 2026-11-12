using System.Diagnostics;
using Microsoft.UI.Xaml;
using TablePro.Testing;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Editor.Tests;

public sealed class CaretTests
{
    private static readonly TimeSpan LongestTimeout = TimeSpan.FromSeconds(15);

    // A Win32 edit control stops blinking after the caret timeout; the editor drew a frame per blink for ever.
    [Fact]
    public Task TheCaretStopsBlinkingAfterTheCaretTimeoutAndNoFrameFollows()
    {
        var blink = GetCaretBlinkTime();
        Assert.SkipWhen(blink is 0 or uint.MaxValue, "Caret blinking is off on this machine.");
        var timeout = CaretTimeout();
        Assert.SkipWhen(timeout > LongestTimeout, $"The caret timeout here is {timeout}.");
        var cancel = TestContext.Current.CancellationToken;
        return WinUiApp.RunAsync(async () =>
        {
            var editor = new SqlEditor { Text = "SELECT 1;" };
            try
            {
                Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
                WinUiApp.Window.Activate();
                await WinUiApp.NextFrameAsync();
                Assert.True(editor.WatchesWindowActivation, "no InputActivationListener for the editor's window");
                Assert.SkipUnless(editor.IsInActiveWindow, "The test window is not the active window.");
                var frames = 0;
                editor.FramePresented += (_, _) => frames++;

                var focused = Stopwatch.StartNew();
                Assert.True(editor.Focus(FocusState.Programmatic));
                await WinUiApp.NextFrameAsync();
                Assert.True(editor.IsCaretBlinking);
                while (editor.IsCaretBlinking && focused.Elapsed < timeout + TimeSpan.FromSeconds(3))
                {
                    await Task.Delay(50, cancel);
                }

                Assert.False(editor.IsCaretBlinking, $"still blinking {focused.ElapsedMilliseconds} ms after focus");
                Assert.True(focused.Elapsed >= timeout, $"stopped after {focused.ElapsedMilliseconds} ms");
                Assert.True(frames >= 2, $"{frames} frames while it blinked");
                await WinUiApp.NextFrameAsync();
                await WinUiApp.NextFrameAsync();
                frames = 0;
                await Task.Delay(1000, cancel);
                Assert.Equal(0, frames);
            }
            finally
            {
                EditorHost.Clear();
                editor.Dispose();
            }
        });
    }

    private static unsafe TimeSpan CaretTimeout()
    {
        uint milliseconds;
        return SystemParametersInfoW(SPI.SPI_GETCARETTIMEOUT, 0, &milliseconds, 0)
            ? TimeSpan.FromMilliseconds(milliseconds)
            : TimeSpan.FromSeconds(5);
    }
}
