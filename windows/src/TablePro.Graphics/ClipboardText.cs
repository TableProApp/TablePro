using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.Graphics;

// A program holding the clipboard open makes each call throw CLIPBRD_E_CANT_OPEN for a moment, so it is tried again.
internal static class ClipboardText
{
    private const int Attempts = 5;
    private static readonly TimeSpan Pause = TimeSpan.FromMilliseconds(20);

    // False when the clipboard stayed held, and the text never reached it.
    public static bool TrySet(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var package = new DataPackage();
        package.SetText(text);
        if (!Retry(() => Clipboard.SetContent(package)))
        {
            return false;
        }

        // Kept once the app has closed, as a copy is expected to be; the text is on the clipboard either way.
        _ = Retry(Clipboard.Flush);
        return true;
    }

    // Null when there is no text, or the clipboard or the program that put the text there does not answer.
    public static async Task<string?> TryGetAsync()
    {
        DataPackageView? content = null;
        if (!Retry(() => content = Clipboard.GetContent()) || content is null)
        {
            return null;
        }

        try
        {
            return content.Contains(StandardDataFormats.Text) ? await content.GetTextAsync() : null;
        }
        catch (COMException)
        {
            return null;
        }
    }

    private static bool Retry(Action call)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                call();
                return true;
            }
            catch (COMException) when (attempt < Attempts)
            {
                Thread.Sleep(Pause);
            }
            catch (COMException)
            {
                return false;
            }
        }
    }
}
