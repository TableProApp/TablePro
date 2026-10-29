using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;
using SQLitePCL;
using TablePro.Core.Connections;
using TablePro.Core.Localization;

namespace TablePro.Drivers.Sqlite;

/// <summary>
/// Loads a connection's extensions into each SQLite handle it opens, in order, through the C API only.
/// </summary>
/// <remarks>
/// Loading is switched on with <c>SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION</c>, which opens
/// <c>sqlite3_load_extension</c> and leaves the <c>load_extension()</c> SQL function refused, so a statement from the
/// editor, an import or an AI client can never load a library. It is switched off again whatever happened, and a
/// handle that will not switch off fails the connect rather than being handed out with the C API still open.
/// </remarks>
internal static partial class SqliteExtensionLoader
{
    private const uint LoadLibrarySearchDllLoadDir = 0x00000100;
    private const uint LoadLibrarySearchDefaultDirs = 0x00001000;

    // A pooled handle comes back with what was loaded into it, and loading a library into it again would run its
    // initializer a second time; each handle remembers the files it already holds.
    private static readonly ConditionalWeakTable<sqlite3, HashSet<string>> Loaded = [];

    /// <summary>Loads every entry <paramref name="connection"/>'s handle does not hold yet.</summary>
    /// <exception cref="LoadableExtensionException">The first entry that failed; nothing after it is loaded.</exception>
    public static void Load(SqliteConnection connection, IReadOnlyList<LoadableExtension> extensions)
    {
        ArgumentNullException.ThrowIfNull(connection);
        if (extensions.Count == 0)
        {
            return;
        }

        var handle = connection.Handle ?? throw new InvalidOperationException(CoreStrings.Get("Driver/ConnectionNotOpen"));
        var held = Loaded.GetValue(handle, static _ => new HashSet<string>(StringComparer.Ordinal));
        var pending = new List<(LoadableExtension Item, string File, string Key)>(extensions.Count);
        var listed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in extensions)
        {
            var file = ResolveFile(item);
            var key = LoadedFileKey(file, item.EntryPoint);

            // The same library under two spellings, a link beside its target, loads once.
            if (!listed.Add(key))
            {
                throw new LoadableExtensionException(LoadableExtensionFailure.Duplicate, item);
            }

            if (!held.Contains(key))
            {
                pending.Add((item, file, key));
            }
        }

        if (pending.Count == 0)
        {
            return;
        }

        if (!SetLoadingEnabled(handle, true))
        {
            throw new LoadableExtensionException(LoadableExtensionFailure.LoadingUnavailable);
        }

        LoadableExtensionException? failure = null;
        foreach (var (item, file, key) in pending)
        {
            failure = LoadOne(handle, item, file);
            if (failure is not null)
            {
                break;
            }

            held.Add(key);
        }

        var stillEnabled = SetLoadingEnabled(handle, false);
        if (failure is not null)
        {
            throw failure;
        }

        if (stillEnabled)
        {
            throw new LoadableExtensionException(LoadableExtensionFailure.LoadingNotClosed);
        }
    }

    /// <summary>
    /// The file SQLite is handed, which is exactly the path that was approved. SQLite's habit of retrying a path with
    /// ".dll" appended is not repeated: <c>C:\Tools\mod_spatialite</c> names nothing, and the full file name is given.
    /// </summary>
    internal static string ResolveFile(LoadableExtension item)
    {
        var file = item.ExpandedPath;
        if (Directory.Exists(file))
        {
            throw new LoadableExtensionException(LoadableExtensionFailure.NotAFile, item);
        }

        return File.Exists(file) ? Path.GetFullPath(file) : throw new LoadableExtensionException(LoadableExtensionFailure.FileNotFound, item);
    }

    internal static string LoadedFileKey(string file, string? entryPoint)
    {
        string target;
        try
        {
            target = new FileInfo(file).ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? file;
        }
        catch (IOException)
        {
            target = file;
        }

        return Path.GetFullPath(target).ToUpperInvariant() + "\0" + entryPoint;
    }

    /// <summary>
    /// Sets the option and answers whether loading is on afterwards. A call SQLite rejects answers the state that
    /// fails safe: not on after an attempt to switch it on, still on after an attempt to switch it off.
    /// </summary>
    private static bool SetLoadingEnabled(sqlite3 handle, bool enabled) =>
        raw.sqlite3_db_config(handle, raw.SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, enabled ? 1 : 0, out var state) == raw.SQLITE_OK
            ? state == 1
            : !enabled;

    private static LoadableExtensionException? LoadOne(sqlite3 handle, LoadableExtension item, string file)
    {
        // SQLite opens a library with a plain LoadLibrary, which looks for the DLLs it depends on beside the app and on
        // PATH but not beside the library itself, so an extension shipped with its own DLLs (SpatiaLite) would not
        // open. Opening it first with the library's folder in the search keeps it loaded for SQLite's call, which then
        // finds it by path, and tells why when it cannot open. Windows runs a library's start-up code once per process,
        // so this adds no second initialization; SQLite's entry point still runs only in sqlite3_load_extension.
        var module = LoadLibraryEx(file, IntPtr.Zero, LoadLibrarySearchDllLoadDir | LoadLibrarySearchDefaultDirs);
        if (module == IntPtr.Zero)
        {
            var error = Marshal.GetLastPInvokeError();
            return new LoadableExtensionException(LoadableExtensionFailure.LibraryNotLoaded, item, new Win32Exception(error).Message, error);
        }

        try
        {
            var result = raw.sqlite3_load_extension(handle, utf8z.FromString(file), utf8z.FromString(item.EntryPoint), out var message);
            if (result == raw.SQLITE_OK)
            {
                return null;
            }

            // On Windows SQLite replaces its "no entry point" text with the system's "procedure could not be found", which
            // names no function, so the module still held here is asked for the entry point SQLite looked up.
            var text = message.utf8_to_string() ?? raw.sqlite3_errmsg(handle).utf8_to_string() ?? string.Empty;
            return MissingEntryPoint(module, item, file) is { } symbol
                ? new LoadableExtensionException(LoadableExtensionFailure.EntryPointNotFound, item, symbol)
                : Diagnose(item, text);
        }
        finally
        {
            FreeLibrary(module);
        }
    }

    /// <summary>Turns SQLite's error text into the reason the user can act on.</summary>
    internal static LoadableExtensionException Diagnose(LoadableExtension item, string message)
    {
        const string entryPrefix = "no entry point [";
        const string entrySuffix = "] in shared library [";
        if (message.StartsWith(entryPrefix, StringComparison.Ordinal) && message.IndexOf(entrySuffix, StringComparison.Ordinal) is var end and > 0)
        {
            var symbol = message[entryPrefix.Length..end];
            if (symbol.Length > 0)
            {
                return new LoadableExtensionException(LoadableExtensionFailure.EntryPointNotFound, item, symbol);
            }
        }

        const string initializationPrefix = "error during initialization:";
        return message.StartsWith(initializationPrefix, StringComparison.Ordinal)
            ? new LoadableExtensionException(LoadableExtensionFailure.InitializationFailed, item, message[initializationPrefix.Length..].Trim())
            : new LoadableExtensionException(LoadableExtensionFailure.LibraryNotLoaded, item, message);
    }

    /// <summary>
    /// The entry point SQLite could not find in <paramref name="module"/>, or null when it is there. Without a named one
    /// SQLite tries <c>sqlite3_extension_init</c>, then the name it derives from the file and reports that one.
    /// </summary>
    private static string? MissingEntryPoint(IntPtr module, LoadableExtension item, string file)
    {
        if (item.EntryPoint is { } entryPoint)
        {
            return GetProcAddress(module, entryPoint) == IntPtr.Zero ? entryPoint : null;
        }

        var derived = DerivedEntryPoint(file);
        return GetProcAddress(module, "sqlite3_extension_init") == IntPtr.Zero && GetProcAddress(module, derived) == IntPtr.Zero ? derived : null;
    }

    /// <summary>SQLite's rule: "sqlite3_", the file name's letters before its first dot without a leading "lib", lower-cased, then "_init".</summary>
    internal static string DerivedEntryPoint(string file)
    {
        var name = Path.GetFileName(file).AsSpan();
        if (name.StartsWith("lib", StringComparison.OrdinalIgnoreCase))
        {
            name = name[3..];
        }

        var builder = new System.Text.StringBuilder("sqlite3_", name.Length + 13);
        foreach (var c in name)
        {
            if (c == '.')
            {
                break;
            }

            if (char.IsAsciiLetter(c))
            {
                builder.Append(char.ToLowerInvariant(c));
            }
        }

        return builder.Append("_init").ToString();
    }

    [LibraryImport("kernel32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf8)]
    private static partial IntPtr GetProcAddress(IntPtr module, string procName);

    [LibraryImport("kernel32.dll", EntryPoint = "LoadLibraryExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr LoadLibraryEx(string fileName, IntPtr file, uint flags);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool FreeLibrary(IntPtr module);
}
