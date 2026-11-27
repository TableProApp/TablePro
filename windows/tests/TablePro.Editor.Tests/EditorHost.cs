using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.Testing;

[assembly: CollectionBehavior(CollectionBehavior.CollectionPerAssembly)]

namespace TablePro.Editor.Tests;

// The editor's side of the shared WinUI app in tests/Shared/WinUiApp.cs; one panel swaps its child as TabView does.
internal static class EditorHost
{
    private static Grid? s_host;

    // False when the editor drew no frame.
    public static async Task<bool> ShowAsync(SqlEditor editor, UIElement? beside = null)
    {
        var presented = false;
        void OnFrame(object? sender, EditorFrame frame) => presented = true;
        editor.FramePresented += OnFrame;
        try
        {
            var host = Host();
            host.Children.Clear();
            host.Children.Add(editor);
            if (beside is not null)
            {
                host.Children.Add(beside);
            }
            for (var i = 0; i < 300 && !presented; i++)
            {
                await WinUiApp.NextFrameAsync();
            }
            return presented;
        }
        finally
        {
            editor.FramePresented -= OnFrame;
        }
    }

    public static void Clear() => Host().Children.Clear();

    private static Grid Host()
    {
        if (s_host is null || !ReferenceEquals(WinUiApp.Window.Content, s_host))
        {
            s_host = new Grid
            {
                Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"],
            };
            WinUiApp.Window.Content = s_host;
        }
        return s_host;
    }
}
