using System.Buffers;
using System.Text;
using System.Text.Json;
using TablePro.Core.Localization;

namespace TablePro.Core.Connections;

/// <summary>
/// One SQLite extension a connection loads when its database file opens, in the order the list gives.
/// <see cref="EntryPoint"/> is null to let SQLite derive it from the file name: <c>mod_spatialite.dll</c> gives
/// <c>sqlite3_modspatialite_init</c>. A renamed file, or one exporting several entry points, needs it named.
/// </summary>
public sealed record LoadableExtension
{
    public LoadableExtension(string path, string? entryPoint = null)
    {
        ArgumentNullException.ThrowIfNull(path);
        Path = path.Trim();
        var trimmed = entryPoint?.Trim();
        EntryPoint = string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }

    public string Path { get; }

    public string? EntryPoint { get; }

    /// <summary>
    /// The path with <c>%VARIABLES%</c> expanded, as the database file path is, and a leading <c>~</c> read as the
    /// user's profile folder, so a list written on macOS with <c>~/</c> paths still names the home folder here.
    /// </summary>
    public string ExpandedPath
    {
        get
        {
            var path = Environment.ExpandEnvironmentVariables(Path);
            if (path == "~")
            {
                return Home;
            }

            return path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal)
                ? System.IO.Path.Join(Home, path.AsSpan(2))
                : path;
        }
    }

    public string FileName => System.IO.Path.GetFileName(Path.TrimEnd('/', '\\'));

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>
    /// The entry as it is compared for duplicates and approvals: the expanded, normalized path, case-folded because
    /// Windows names one file however its path is cased.
    /// </summary>
    public LoadableExtension Canonical()
    {
        var expanded = ExpandedPath;
        string normalized;
        try
        {
            normalized = System.IO.Path.IsPathFullyQualified(expanded) ? System.IO.Path.GetFullPath(expanded) : expanded;
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            normalized = expanded;
        }

        return new LoadableExtension(normalized.ToUpperInvariant(), EntryPoint);
    }
}

/// <summary>
/// The stored form of a connection's extension list: a JSON array of <c>{"entryPoint", "path"}</c> objects in one
/// connection option, the macOS app's <c>sqliteExtensions</c> field, so a list travels through exports and the team
/// library with the rest of the connection. An empty list is no option at all rather than <c>[]</c>.
/// </summary>
public static class LoadableExtensionList
{
    public const string OptionKey = "sqliteExtensions";

    private const string LibSqlModeOption = "libsqlMode";

    private static readonly string[] LibSqlUrlOptions = ["databaseUrl", "url"];

    /// <summary>The list in <paramref name="value"/>; nothing for an empty value.</summary>
    /// <exception cref="LoadableExtensionException">The value is not a list of extensions.</exception>
    public static IReadOnlyList<LoadableExtension> Decode(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return [];
        }

        try
        {
            using var document = JsonDocument.Parse(value);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw Malformed();
            }

            var list = new List<LoadableExtension>(document.RootElement.GetArrayLength());
            foreach (var item in document.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object
                    || !item.TryGetProperty("path", out var path) || path.ValueKind != JsonValueKind.String)
                {
                    throw Malformed();
                }

                string? entryPoint = null;
                if (item.TryGetProperty("entryPoint", out var entry))
                {
                    entryPoint = entry.ValueKind switch
                    {
                        JsonValueKind.String => entry.GetString(),
                        JsonValueKind.Null => null,
                        _ => throw Malformed(),
                    };
                }

                list.Add(new LoadableExtension(path.GetString()!, entryPoint));
            }

            return list;
        }
        catch (JsonException)
        {
            throw Malformed();
        }
    }

    /// <summary>The stored value for <paramref name="extensions"/>, keys sorted as the macOS encoder writes them.</summary>
    public static string Encode(IReadOnlyList<LoadableExtension> extensions)
    {
        ArgumentNullException.ThrowIfNull(extensions);
        if (extensions.Count == 0)
        {
            return string.Empty;
        }

        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartArray();
            foreach (var item in extensions)
            {
                writer.WriteStartObject();
                if (item.EntryPoint is { } entryPoint)
                {
                    writer.WriteString("entryPoint", entryPoint);
                }

                writer.WriteString("path", item.Path);
                writer.WriteEndObject();
            }

            writer.WriteEndArray();
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    /// <summary>The list stored on <paramref name="profile"/>, whether or not its engine loads it.</summary>
    public static IReadOnlyList<LoadableExtension> Stored(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        return Decode(profile.AdditionalOptions.GetValueOrDefault(OptionKey));
    }

    /// <summary>
    /// Whether the connection opens a database file through the SQLite driver, the only place a list loads: SQLite
    /// itself, and libSQL or Turso pointed at a local file. A remote libSQL server never loads one, as on macOS, where
    /// the field shows only in local mode.
    /// </summary>
    public static bool AppliesTo(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        return AppliesTo(profile.Engine, profile.Host, profile.AdditionalOptions);
    }

    /// <summary><see cref="AppliesTo(ConnectionProfile)"/> for a connection form's fields before a profile exists.</summary>
    public static bool AppliesTo(DatabaseEngine engine, string? host, IReadOnlyDictionary<string, string> options) => engine switch
    {
        DatabaseEngine.Sqlite => true,
        DatabaseEngine.LibSql or DatabaseEngine.Turso => IsLocalLibSql(host, options),
        _ => false,
    };

    /// <summary>The list the connection loads when it opens: <see cref="Stored"/> where <see cref="AppliesTo(ConnectionProfile)"/> holds, else nothing.</summary>
    public static IReadOnlyList<LoadableExtension> Declared(ConnectionProfile profile) =>
        AppliesTo(profile) ? Stored(profile) : [];

    /// <summary>
    /// The libSQL driver's local-file rule (<c>LibSqlSettings.LocalFile</c>): macOS's <c>libsqlMode=local</c>, or a
    /// <c>file:</c> URL in the URL option or the host field. It is restated here because the app, which decides what
    /// to ask before a connect, references drivers only through Core.
    /// </summary>
    public static bool IsLocalLibSql(string? host, IReadOnlyDictionary<string, string> options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.TryGetValue(LibSqlModeOption, out var mode) && string.Equals(mode?.Trim(), "local", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        var url = LibSqlUrlOptions.Select(k => options.TryGetValue(k, out var v) ? v : null).FirstOrDefault(v => !string.IsNullOrWhiteSpace(v)) ?? host;
        return url?.Trim().StartsWith("file:", StringComparison.OrdinalIgnoreCase) == true;
    }

    private static LoadableExtensionException Malformed() => new(LoadableExtensionFailure.MalformedList);
}

/// <summary>The checks a list passes before SQLite is asked to load any of it; the ones that need no disk.</summary>
public static class LoadableExtensionPreflight
{
    /// <summary>The longest path Windows takes, in UTF-16 units; the app is long-path aware.</summary>
    public const int MaximumPathLength = 32_767;

    /// <exception cref="LoadableExtensionException">The first entry that fails, with the reason.</exception>
    public static void Validate(IReadOnlyList<LoadableExtension> extensions)
    {
        ArgumentNullException.ThrowIfNull(extensions);
        var seen = new HashSet<LoadableExtension>();
        foreach (var item in extensions)
        {
            if (item.Path.Length == 0)
            {
                throw new LoadableExtensionException(LoadableExtensionFailure.MissingPath);
            }

            if (ContainsLineBreakOrControl(item.Path))
            {
                throw new LoadableExtensionException(LoadableExtensionFailure.ControlCharacterInPath);
            }

            var expanded = item.ExpandedPath;
            if (!Path.IsPathFullyQualified(expanded))
            {
                throw new LoadableExtensionException(LoadableExtensionFailure.RelativePath, item);
            }

            if (expanded.Length > MaximumPathLength)
            {
                throw new LoadableExtensionException(LoadableExtensionFailure.PathTooLong, item);
            }

            if (item.EntryPoint is { } entryPoint && !IsCIdentifier(entryPoint))
            {
                throw new LoadableExtensionException(LoadableExtensionFailure.InvalidEntryPoint, item);
            }

            if (!seen.Add(item.Canonical()))
            {
                throw new LoadableExtensionException(LoadableExtensionFailure.Duplicate, item);
            }
        }
    }

    /// <summary>
    /// Control characters, and the Unicode line and paragraph separators a dialog renders as line breaks, so a path
    /// from an import cannot write lines of its own into the prompt that names the code about to run.
    /// </summary>
    public static bool ContainsLineBreakOrControl(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        foreach (var c in text)
        {
            if (char.IsControl(c) || c is '\x2028' or '\x2029' or '\x85')
            {
                return true;
            }
        }

        return false;
    }

    public static bool IsCIdentifier(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        if (name.Length == 0 || !(name[0] == '_' || char.IsAsciiLetter(name[0])))
        {
            return false;
        }

        foreach (var c in name)
        {
            if (c != '_' && !char.IsAsciiLetterOrDigit(c))
            {
                return false;
            }
        }

        return true;
    }
}

/// <summary>Why a connection's extensions did not load; the app words each one for the screen.</summary>
public enum LoadableExtensionFailure
{
    MalformedList,
    MissingPath,
    ControlCharacterInPath,
    RelativePath,
    PathTooLong,
    InvalidEntryPoint,
    Duplicate,
    FileNotFound,
    NotAFile,
    EntryPointNotFound,
    InitializationFailed,
    LibraryNotLoaded,
    LoadingUnavailable,
    LoadingNotClosed,
}

/// <summary>
/// A connection's extensions did not load. Every case fails the connect: a database that needs an extension is not
/// usable without it, and loading part of the list would leave the user reading "no such function" for the rest.
/// </summary>
public sealed class LoadableExtensionException : Exception
{
    public LoadableExtensionException()
        : this(LoadableExtensionFailure.LoadingUnavailable)
    {
    }

    public LoadableExtensionException(string message)
        : base(message)
    {
        Failure = LoadableExtensionFailure.LibraryNotLoaded;
    }

    public LoadableExtensionException(string message, Exception innerException)
        : base(message, innerException)
    {
        Failure = LoadableExtensionFailure.LibraryNotLoaded;
    }

    public LoadableExtensionException(LoadableExtensionFailure failure, LoadableExtension? extension = null, string? detail = null, int? windowsError = null)
        : base(Describe(failure, extension, detail))
    {
        Failure = failure;
        Extension = extension;
        Detail = detail;
        WindowsError = windowsError;
    }

    public LoadableExtensionFailure Failure { get; }

    /// <summary>The entry that failed, or null for a failure of the whole list.</summary>
    public LoadableExtension? Extension { get; }

    /// <summary>SQLite's or Windows' own words: the missing symbol, the initializer's error, or why the library did not open.</summary>
    public string? Detail { get; }

    /// <summary>The Win32 error a library that did not open gave, which picks the advice shown with it.</summary>
    public int? WindowsError { get; }

    /// <summary>ERROR_BAD_EXE_FORMAT: the library is built for another processor.</summary>
    public bool IsWrongArchitecture => WindowsError == 193;

    /// <summary>ERROR_MOD_NOT_FOUND for a file that exists: a DLL the library depends on is missing.</summary>
    public bool IsMissingDependency => WindowsError == 126;

    // The app adds advice on what to do next to its own wording; this message serves every other caller.
    private static string Describe(LoadableExtensionFailure failure, LoadableExtension? item, string? detail)
    {
        var head = item is null
            ? CoreStrings.Get("Extension/CouldNotLoadList")
            : CoreStrings.Format("Extension/CouldNotLoad", item.FileName);
        var reason = failure switch
        {
            LoadableExtensionFailure.MalformedList => CoreStrings.Get("Extension/MalformedList"),
            LoadableExtensionFailure.MissingPath => CoreStrings.Get("Extension/MissingPath"),
            LoadableExtensionFailure.ControlCharacterInPath => CoreStrings.Get("Extension/ControlCharacterInPath"),
            LoadableExtensionFailure.RelativePath => CoreStrings.Format("Extension/RelativePath", item?.Path),
            LoadableExtensionFailure.PathTooLong => CoreStrings.Format("Extension/PathTooLong", item?.Path),
            LoadableExtensionFailure.InvalidEntryPoint => CoreStrings.Format("Extension/InvalidEntryPoint", item?.EntryPoint),
            LoadableExtensionFailure.Duplicate => CoreStrings.Format("Extension/Duplicate", item?.Path),
            LoadableExtensionFailure.FileNotFound => CoreStrings.Format("Extension/FileNotFound", item?.Path),
            LoadableExtensionFailure.NotAFile => CoreStrings.Format("Extension/NotAFile", item?.Path),
            LoadableExtensionFailure.EntryPointNotFound => CoreStrings.Format("Extension/EntryPointNotFound", detail),
            LoadableExtensionFailure.InitializationFailed => CoreStrings.Format("Extension/InitializationFailed", detail),
            LoadableExtensionFailure.LoadingUnavailable => CoreStrings.Get("Extension/LoadingUnavailable"),
            LoadableExtensionFailure.LoadingNotClosed => CoreStrings.Get("Extension/LoadingNotClosed"),
            _ => detail,
        };
        return string.IsNullOrEmpty(reason) ? head : head + " " + reason;
    }
}
