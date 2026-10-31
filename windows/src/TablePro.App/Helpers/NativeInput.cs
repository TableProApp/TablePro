using System.Runtime.InteropServices;

namespace TablePro.App.Helpers;

/// <summary>Input settings Windows keeps for the user, which WinUI does not surface.</summary>
internal static partial class NativeInput
{
    /// <summary>The longest gap between the clicks of a double-click, as set in Mouse settings.</summary>
    public static int DoubleClickMilliseconds => (int)GetDoubleClickTime();

    [LibraryImport("user32.dll")]
    private static partial uint GetDoubleClickTime();
}
