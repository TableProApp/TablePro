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

    // The primary caret in screen pixels, where an input method's candidates or a completion list go.
    public Windows.Graphics.RectInt32 CaretScreenRectangle()
    {
        var rect = ToScreen(CaretRect(_model.Primary.Active));
        return new Windows.Graphics.RectInt32(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
    }

    // WinUI's UIA bridge works in the island's client pixels: it turns the rectangles a text provider returns from
    // client to screen itself, and hands RangeFromPoint a client point (microsoft-ui-xaml,
    // dxaml/xcp/win/shared/UIAPatternProviderWrapper.cpp). Screen coordinates here would be offset twice.
    internal Rect ToUiaClient(Rect rect)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var origin = _panel.TransformToVisual(null).TransformPoint(new Point(rect.X, rect.Y));
        return new Rect(origin.X * scale, origin.Y * scale, rect.Width * scale, rect.Height * scale);
    }

    internal Point FromUiaClient(Point client)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1;
        return _panel.TransformToVisual(null).Inverse.TransformPoint(new Point(client.X / scale, client.Y / scale));
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
