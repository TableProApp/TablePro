using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using TablePro.Storage.Localization;

namespace TablePro.Storage.Library.Folders;

/// <summary>Moves files somewhere they can be recovered from, rather than deleting them.</summary>
public interface IRecycleBin
{
    void MoveToRecycleBin(string path);
}

/// <summary>
/// The Windows Recycle Bin through <c>SHFileOperationW</c> with undo allowed, the call Explorer's Delete makes. It
/// shows no confirmation and no progress, since the app asks first in its own words. The struct layout is the 64-bit
/// one, the only kind of build the app ships.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed partial class ShellRecycleBin : IRecycleBin
{
    private const uint FoDelete = 0x0003;
    private const ushort FofSilent = 0x0004;
    private const ushort FofNoConfirmation = 0x0010;
    private const ushort FofAllowUndo = 0x0040;
    private const ushort FofNoErrorUi = 0x0400;
    private const ushort FofWantNukeWarning = 0x4000;

    public static ShellRecycleBin Instance { get; } = new();

    public unsafe void MoveToRecycleBin(string path)
    {
        var full = Path.GetFullPath(path);
        if (!File.Exists(full) && !Directory.Exists(full))
        {
            throw new FileNotFoundException(StorageStrings.Get("Library/FileNoLongerExists"), full);
        }

        // pFrom is a list of paths, each NUL-terminated, ending with an extra NUL.
        var from = full + "\0\0";
        fixed (char* fromPointer = from)
        {
            var operation = new FileOperation
            {
                Function = FoDelete,
                From = fromPointer,

                // Without the nuke warning a file on a drive with no Recycle Bin (a network share) would be deleted
                // for good without a word; with it the shell asks first, and a refusal comes back as aborted.
                Flags = (ushort)(FofAllowUndo | FofNoConfirmation | FofSilent | FofNoErrorUi | FofWantNukeWarning),
            };
            var result = SHFileOperationW(&operation);
            if (result != 0 || operation.AnyOperationsAborted != 0)
            {
                throw new IOException(StorageStrings.Get("Library/RecycleBinFailed"), new Win32Exception(result));
            }
        }
    }

    [LibraryImport("shell32.dll")]
    private static unsafe partial int SHFileOperationW(FileOperation* operation);

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct FileOperation
    {
        public nint Window;
        public uint Function;
        public char* From;
        public char* To;
        public ushort Flags;
        public int AnyOperationsAborted;
        public nint NameMappings;
        public char* ProgressTitle;
    }
}
