using System.Diagnostics;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.Testing;
using TerraFX.Interop.Windows;
using Windows.Graphics;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Editor.Tests;

public sealed class CaretTests
{
    private static readonly TimeSpan LongestTimeout = TimeSpan.FromSeconds(15);

    // A Win32 edit control stops blinking after the caret timeout; each blink of the editor's caret drew a whole frame.
    [Fact]
    public Task TheCaretBlinksWithNoFrameAndStopsAfterTheCaretTimeout()
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
                // Past any frame the show still had queued, so what is counted is the blink's.
                await WinUiApp.NextFrameAsync();
                await WinUiApp.NextFrameAsync();
                await WinUiApp.NextFrameAsync();
                Assert.True(editor.WatchesWindowActivation, "no InputActivationListener for the editor's window");
                Assert.SkipUnless(editor.IsInActiveWindow, "The test window is not the active window.");
                var frames = 0;
                editor.FramePresented += (_, _) => frames++;

                var focused = Stopwatch.StartNew();
                Assert.True(editor.Focus(FocusState.Programmatic));
                await WinUiApp.NextFrameAsync();
                Assert.True(editor.IsCaretBlinking);
                Assert.True(editor.IsCaretShown, "no caret shown after focus");
                var toggles = editor.CaretToggles;
                var undisturbed = true;
                while (editor.IsCaretBlinking && focused.Elapsed < timeout + TimeSpan.FromSeconds(3))
                {
                    await Task.Delay(20, cancel);
                    undisturbed &= editor.IsInActiveWindow && editor.FocusState != FocusState.Unfocused;
                }

                // Before desktop.ps1 runs, a runner's own windows take the activation now and then, which stops the blink too.
                Assert.SkipUnless(
                    undisturbed && editor.IsInActiveWindow && editor.FocusState != FocusState.Unfocused,
                    $"The window lost activation or the editor its focus {focused.ElapsedMilliseconds} ms after focus.");
                Assert.False(editor.IsCaretBlinking, $"still blinking {focused.ElapsedMilliseconds} ms after focus");
                Assert.True(focused.Elapsed >= timeout, $"stopped after {focused.ElapsedMilliseconds} ms");
                var toggled = editor.CaretToggles - toggles;
                Assert.True(toggled >= 2, $"the caret toggled {toggled} times");
                Assert.True(editor.IsCaretShown, "the caret is hidden after the timeout");
                Assert.Equal(0, frames);
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

    // Focus leaving the editor drew a whole frame though nothing on the swap chain changed.
    [Fact]
    public Task FocusLeavingTheEditorAndComingBackDrawsNoFrame()
    {
        return WinUiApp.RunAsync(async () =>
        {
            var editor = new SqlEditor { Text = "SELECT 1;" };
            var other = new Button
            {
                Content = "Other",
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
            };
            try
            {
                Assert.True(await EditorHost.ShowAsync(editor, other), "the editor drew no frame");
                WinUiApp.Window.Activate();
                await FramesAsync(3);
                Assert.SkipUnless(editor.IsInActiveWindow, "The test window is not the active window.");
                Assert.True(editor.Focus(FocusState.Programmatic));
                await FramesAsync(3);
                Assert.True(editor.IsCaretShown, "no caret shown after focus");
                var frames = 0;
                editor.FramePresented += (_, _) => frames++;

                Assert.True(other.Focus(FocusState.Programmatic));
                await FramesAsync(3);
                Assert.Equal(FocusState.Unfocused, editor.FocusState);
                Assert.False(editor.IsCaretShown, "the caret is shown after focus left");
                Assert.True(editor.Focus(FocusState.Programmatic));
                await FramesAsync(3);
                Assert.True(editor.IsCaretShown, "no caret shown after focus came back");
                Assert.Equal(0, frames);
            }
            finally
            {
                EditorHost.Clear();
                editor.Dispose();
            }
        });
    }

    // Another test process opening its window took the activation and drew a frame in the timeout test.
    [Fact]
    public Task AnotherWindowTakingTheActivationDrawsNoFrame()
    {
        return WinUiApp.RunAsync(async () =>
        {
            var editor = new SqlEditor { Text = "SELECT 1;" };
            try
            {
                Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
                WinUiApp.Window.Activate();
                await FramesAsync(3);
                Assert.SkipUnless(editor.IsInActiveWindow, "The test window is not the active window.");
                Assert.True(editor.Focus(FocusState.Programmatic));
                await FramesAsync(3);
                var frames = 0;
                editor.FramePresented += (_, _) => frames++;

                var other = new Window { Title = "Other" };
                other.AppWindow.MoveAndResize(new RectInt32(120, 120, 480, 320));
                try
                {
                    other.Activate();
                    await UntilAsync(() => !editor.IsInActiveWindow);
                    Assert.SkipWhen(editor.IsInActiveWindow, "The other window did not take the activation.");
                    await FramesAsync(3);
                    Assert.False(editor.IsCaretShown, "the caret is shown in an inactive window");
                }
                finally
                {
                    other.Close();
                }
                WinUiApp.Window.Activate();
                await UntilAsync(() => editor.IsInActiveWindow);
                Assert.SkipUnless(editor.IsInActiveWindow, "The test window did not get the activation back.");
                await FramesAsync(3);
                Assert.True(editor.IsCaretShown, "no caret shown once the window was active again");
                Assert.Equal(0, frames);
            }
            finally
            {
                EditorHost.Clear();
                editor.Dispose();
            }
        });
    }

    // Read from the screen: the caret's visual draws over the swap chain and the blink hides it.
    [Fact]
    public Task TheCaretShowsOverTheTextAndTheBlinkHidesIt()
    {
        var blink = GetCaretBlinkTime();
        Assert.SkipWhen(blink is 0 or uint.MaxValue, "Caret blinking is off on this machine.");
        Assert.SkipWhen(
            CaretTimeout() < TimeSpan.FromMilliseconds(blink * 3), "The caret timeout here ends the blink too soon.");
        return WinUiApp.RunAsync(async () =>
        {
            // Empty, so only the current line band lies under the caret.
            var editor = new SqlEditor();
            try
            {
                Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
                WinUiApp.Window.Activate();
                await WinUiApp.NextFrameAsync();
                Assert.SkipUnless(editor.IsInActiveWindow, "The test window is not the active window.");
                Assert.True(editor.Focus(FocusState.Programmatic));
                await WinUiApp.NextFrameAsync();
                var caret = editor.CaretScreenRectangle();
                var x = caret.X;
                var y = caret.Y + caret.Height / 2;
                Assert.SkipUnless(ShowsWindow(editor, x, y), "Another window covers the caret.");

                var shown = await ReadScreenAsync(editor, shown: true, x, y);
                var hidden = await ReadScreenAsync(editor, shown: false, x, y);

                Assert.SkipUnless(
                    shown is not null && hidden is not null && editor.IsInActiveWindow && ShowsWindow(editor, x, y),
                    "The blink or the window's activation changed while the screen was read.");
                // The caret is one pixel wide, and the pixel either side covers a rounding of its place.
                var differs = shown!.Zip(hidden!, Distance).Max();
                Assert.True(differs > 90,
                    $"around ({x}, {y}) the screen holds {Hex(shown!)} with the caret shown, {Hex(hidden!)} hidden");
            }
            finally
            {
                EditorHost.Clear();
                editor.Dispose();
            }
        });
    }

    private static async Task FramesAsync(int count)
    {
        for (var i = 0; i < count; i++)
        {
            await WinUiApp.NextFrameAsync();
        }
    }

    private static async Task UntilAsync(Func<bool> condition)
    {
        var cancel = TestContext.Current.CancellationToken;
        var waited = Stopwatch.StartNew();
        while (!condition() && waited.Elapsed < TimeSpan.FromSeconds(5))
        {
            await Task.Delay(20, cancel);
        }
    }

    // Once the compositor has had time to show the caret's state; null when a blink changed it meanwhile.
    private static async Task<uint[]?> ReadScreenAsync(SqlEditor editor, bool shown, int x, int y)
    {
        var cancel = TestContext.Current.CancellationToken;
        var waited = Stopwatch.StartNew();
        while (editor.IsCaretBlinking && waited.Elapsed < TimeSpan.FromSeconds(4))
        {
            if (editor.IsCaretShown == shown)
            {
                var toggles = editor.CaretToggles;
                await WinUiApp.NextFrameAsync();
                await WinUiApp.NextFrameAsync();
                await Task.Delay(50, cancel);
                var pixels = ScreenPixels(x, y);
                if (pixels is not null && editor.CaretToggles == toggles && editor.IsCaretShown == shown)
                {
                    return pixels;
                }
            }
            await Task.Delay(10, cancel);
        }
        return null;
    }

    private static bool ShowsWindow(SqlEditor editor, int x, int y) =>
        GetAncestor(WindowFromPoint(new POINT { x = x, y = y }), GA.GA_ROOT) == editor.WindowHandle;

    private static uint[]? ScreenPixels(int x, int y)
    {
        var screen = GetDC(HWND.NULL);
        try
        {
            var pixels = new uint[3];
            for (var i = 0; i < pixels.Length; i++)
            {
                pixels[i] = (uint)GetPixel(screen, x - 1 + i, y);
                // CLR_INVALID: the point is off the screen.
                if (pixels[i] == uint.MaxValue)
                {
                    return null;
                }
            }
            return pixels;
        }
        finally
        {
            _ = ReleaseDC(HWND.NULL, screen);
        }
    }

    private static string Hex(uint[] pixels) =>
        string.Join(' ', pixels.Select(pixel => pixel.ToString("X6", CultureInfo.InvariantCulture)));

    private static int Distance(uint a, uint b) =>
        Math.Abs((int)(a & 0xFF) - (int)(b & 0xFF))
        + Math.Abs((int)((a >> 8) & 0xFF) - (int)((b >> 8) & 0xFF))
        + Math.Abs((int)((a >> 16) & 0xFF) - (int)((b >> 16) & 0xFF));

    private static unsafe TimeSpan CaretTimeout()
    {
        uint milliseconds;
        return SystemParametersInfoW(SPI.SPI_GETCARETTIMEOUT, 0, &milliseconds, 0)
            ? TimeSpan.FromMilliseconds(milliseconds)
            : TimeSpan.FromSeconds(5);
    }
}
