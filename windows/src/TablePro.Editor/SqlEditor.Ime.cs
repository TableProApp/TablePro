using Microsoft.UI;
using TablePro.Editor.Input;
using TerraFX.Interop.Windows;
using Windows.Foundation;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Editor;

public sealed partial class SqlEditor
{
    // The top-level window that holds the editor.
    internal HWND WindowHandle
    {
        get
        {
            var id = XamlRoot?.ContentIslandEnvironment?.AppWindowId;
            return id is { } windowId ? (HWND)Win32Interop.GetWindowFromWindowId(windowId) : HWND.NULL;
        }
    }

    // A panel rectangle in DIPs to screen pixels, as TSF and UIA want them.
    internal RECT ToScreen(Rect rect)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var origin = _panel.TransformToVisual(null).TransformPoint(new Point(rect.X, rect.Y));
        var client = new POINT
        {
            x = (int)Math.Round(origin.X * scale),
            y = (int)Math.Round(origin.Y * scale),
        };
        unsafe
        {
            ClientToScreen(WindowHandle, &client);
        }
        return new RECT
        {
            left = client.x,
            top = client.y,
            right = client.x + (int)Math.Round(rect.Width * scale),
            bottom = client.y + (int)Math.Round(rect.Height * scale),
        };
    }

    internal Point FromScreen(Point screen)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var client = new POINT { x = (int)screen.X, y = (int)screen.Y };
        unsafe
        {
            ScreenToClient(WindowHandle, &client);
        }
        var inverse = _panel.TransformToVisual(null).Inverse;
        return inverse.TransformPoint(new Point(client.x / scale, client.y / scale));
    }

    private sealed class TsfHost(SqlEditor editor) : ITsfHost
    {
        public HWND Window => editor.WindowHandle;

        // Where the composition starts, as Terminal reports it: candidate lists line up with the composed text.
        public RECT CaretScreenRect() => editor.ToScreen(editor.CaretRect(editor._model.Primary.Active));

        public RECT ViewScreenRect() => editor.ToScreen(new Rect(0, 0, editor.ViewWidth, editor.ViewHeight));

        public void Commit(string text)
        {
            editor._composition = string.Empty;
            editor.TypeText(text);
            editor.CompositionCommitted?.Invoke(editor, text);
        }

        public void ShowComposition(string text, int caret, IReadOnlyList<CompositionRun> runs)
        {
            editor._composition = text;
            editor._compositionCaret = caret;
            editor._compositionRuns = runs;
            editor.RestartBlink();
            editor.Invalidate();
            editor.CompositionChanged?.Invoke(editor, text);
        }
    }

    // For the gate harness: what the IME is composing, and what it handed over.
    public event EventHandler<string>? CompositionChanged;

    public event EventHandler<string>? CompositionCommitted;

    public string CompositionText => _composition;

    public string? TextServicesFailure => _tsf?.FailureReason;
}
