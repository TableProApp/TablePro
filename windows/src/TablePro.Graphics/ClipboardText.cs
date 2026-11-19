using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.Graphics;

// A program holding the clipboard open makes each call throw CLIPBRD_E_CANT_OPEN for a moment, so it is tried again.
internal static class ClipboardText
{
    private const int Attempts = 5;
    private static readonly TimeSpan Pause = TimeSpan.FromMilliseconds(20);

    // False when the clipboard stayed held, and the text never reached it. Text kept out of history skips Win+V's
    // list and other devices, for writes the user did not ask for as a copy.
    public static bool TrySet(string text, bool inHistory = true)
    {
        ArgumentNullException.ThrowIfNull(text);
        var package = new DataPackage();
        package.SetText(text);
        var options = inHistory ? null : new ClipboardContentOptions { IsAllowedInHistory = false, IsRoamable = false };
        // SetContentWithOptions says false where SetContent throws, so a false goes again as a throw does.
        var set = options is null
            ? Retry(() => Clipboard.SetContent(package))
            : Retry(() => Clipboard.SetContentWithOptions(package, options));
        if (!set)
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

    private static bool Retry(Action call) => Retry(() =>
    {
        call();
        return true;
    });

    private static bool Retry(Func<bool> call)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                if (call())
                {
                    return true;
                }
            }
            catch (COMException) when (attempt < Attempts)
            {
                // Held by another program for a moment; the next attempt may get it.
            }
            catch (COMException)
            {
                return false;
            }
            if (attempt >= Attempts)
            {
                return false;
            }
            Thread.Sleep(Pause);
        }
    }
}
