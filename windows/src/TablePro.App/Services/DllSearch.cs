using System.Runtime.InteropServices;

namespace TablePro.App.Services;

// Excludes the current directory and PATH while retaining registered DLL directories (core ADR 0004).
internal static partial class DllSearch
{
    private const uint LoadLibrarySearchDefaultDirs = 0x00001000;

    public static void Restrict() => _ = SetDefaultDllDirectories(LoadLibrarySearchDefaultDirs);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetDefaultDllDirectories(uint directoryFlags);
}
