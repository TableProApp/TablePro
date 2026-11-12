using System.Runtime.CompilerServices;
using TablePro.Graphics;
using TablePro.Testing;

namespace TablePro.Editor.Tests;

public sealed class LifetimeTests
{
    // UISettings held its ColorValuesChanged handler, and through it the editor of every closed query tab.
    [Fact]
    public Task AnEditorRemovedAndDisposedIsCollected()
    {
        var cancel = TestContext.Current.CancellationToken;
        return WinUiApp.RunAsync(async () =>
        {
            var editor = await ShowAndCloseAsync();
            for (var round = 0; round < 10 && editor.IsAlive; round++)
            {
                await WinUiApp.NextFrameAsync();
                // Off the UI thread, so whatever is released in its apartment can get back to it.
                await Task.Run(() =>
                {
                    GC.Collect();
                    GC.WaitForPendingFinalizers();
                    GC.Collect();
                }, cancel);
            }
            Assert.False(editor.IsAlive, "the editor is still reachable after it was removed and disposed");
        });
    }

    // TabView unloads a tab's content on every switch; each show was a new Direct3D device, factories and swap chain.
    [Fact]
    public Task SwitchingBetweenEditorsMakesOneSwapChainPerShowOnOneDevice() => WinUiApp.RunAsync(async () =>
    {
        string[] texts = ["SELECT 1;", "SELECT 2;", "SELECT 3;"];
        var editors = texts.Select(text => new SqlEditor { Text = text }).ToArray();
        try
        {
            var devices = RenderDevice.CreatedOnThisThread;
            var swapChains = GraphicsDevice.SwapChainsCreated;
            for (var round = 0; round < 10; round++)
            {
                foreach (var editor in editors)
                {
                    Assert.True(await EditorHost.ShowAsync(editor), $"no frame after the switch in round {round}");
                }
            }
            await WinUiApp.NextFrameAsync();
            await WinUiApp.NextFrameAsync();

            // None when an earlier test already made this thread's device.
            Assert.InRange(RenderDevice.CreatedOnThisThread - devices, 0, 1);
            Assert.Equal(30, GraphicsDevice.SwapChainsCreated - swapChains);
            Assert.False(editors[0].HoldsSwapChain);
            Assert.False(editors[1].HoldsSwapChain);
            Assert.True(editors[2].HoldsSwapChain);
        }
        finally
        {
            EditorHost.Clear();
            foreach (var editor in editors)
            {
                editor.Dispose();
            }
        }
    });

    // A driver update or a TDR removes the device while nothing draws, so the next tab shown must not make its swap chain on it.
    [Fact]
    public Task ATabShownAfterTheDeviceWasLostDrawsOnANewDevice() => WinUiApp.RunAsync(async () =>
    {
        var first = new SqlEditor { Text = "SELECT 1;" };
        var second = new SqlEditor { Text = "SELECT 2;" };
        try
        {
            Assert.True(await EditorHost.ShowAsync(first), "no first frame");
            Assert.True(await EditorHost.ShowAsync(second), "no first frame on the second editor");
            var devices = RenderDevice.CreatedOnThisThread;

            GraphicsDevice.SimulateLoss(software: false);

            Assert.True(await EditorHost.ShowAsync(first), "no frame on the tab shown after the loss");
            Assert.Equal(1, RenderDevice.CreatedOnThisThread - devices);
            Assert.True(await EditorHost.ShowAsync(second), "no frame on the other tab after the loss");
            Assert.Equal(1, RenderDevice.CreatedOnThisThread - devices);
        }
        finally
        {
            EditorHost.Clear();
            first.Dispose();
            second.Dispose();
        }
    });

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static async Task<WeakReference> ShowAndCloseAsync()
    {
        var editor = new SqlEditor { Text = "SELECT 1;" };
        Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
        EditorHost.Clear();
        await WinUiApp.NextFrameAsync();
        await WinUiApp.NextFrameAsync();
        editor.Dispose();
        return new WeakReference(editor);
    }
}
