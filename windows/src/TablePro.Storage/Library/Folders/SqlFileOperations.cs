using TablePro.Storage.Localization;

namespace TablePro.Storage.Library.Folders;

/// <summary>Why a file name was refused.</summary>
public enum SqlFileNameProblem
{
    None,
    Empty,
    InvalidCharacters,
    Reserved,
    AlreadyExists,
}

/// <summary>Creating, renaming and editing the files in a linked folder.</summary>
public static class SqlFileOperations
{
    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>The name a file gets: <paramref name="name"/> trimmed, with <c>.sql</c> added unless it already ends in a SQL extension.</summary>
    public static string NormalizedFileName(string name)
    {
        var trimmed = name.Trim().TrimEnd('.');
        return SqlFolderScanner.IsSqlFile(trimmed) ? trimmed : trimmed + ".sql";
    }

    /// <summary>Checks a new name for a file in <paramref name="directory"/>; <paramref name="currentPath"/> is the file being renamed, if any.</summary>
    public static SqlFileNameProblem Validate(string directory, string name, string? currentPath = null)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Trim().TrimEnd('.').Length == 0)
        {
            return SqlFileNameProblem.Empty;
        }

        var fileName = NormalizedFileName(name);
        if (fileName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
        {
            return SqlFileNameProblem.InvalidCharacters;
        }

        var stem = Path.GetFileNameWithoutExtension(fileName);
        var device = stem.Contains('.', StringComparison.Ordinal) ? stem[..stem.IndexOf('.', StringComparison.Ordinal)] : stem;
        if (ReservedNames.Contains(device.TrimEnd()))
        {
            return SqlFileNameProblem.Reserved;
        }

        var target = Path.Combine(directory, fileName);

        // A rename that only changes letter case targets the file itself, which Windows reports as existing.
        var isSelf = currentPath is not null && string.Equals(Path.GetFullPath(currentPath), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase);
        return !isSelf && (File.Exists(target) || Directory.Exists(target)) ? SqlFileNameProblem.AlreadyExists : SqlFileNameProblem.None;
    }

    public static string Describe(SqlFileNameProblem problem) => problem switch
    {
        SqlFileNameProblem.Empty => StorageStrings.Get("Library/NameEmpty"),
        SqlFileNameProblem.InvalidCharacters => StorageStrings.Get("Library/NameInvalidCharacters"),
        SqlFileNameProblem.Reserved => StorageStrings.Get("Library/NameReserved"),
        SqlFileNameProblem.AlreadyExists => StorageStrings.Get("Library/NameAlreadyExists"),
        _ => string.Empty,
    };

    /// <summary>
    /// A name in <paramref name="directory"/> no file has yet: <c>Untitled.sql</c>, then <c>Untitled 2.sql</c> and on, with
    /// "Untitled" in the UI language unless <paramref name="baseName"/> is given.
    /// </summary>
    public static string UniqueFileName(string directory, string? baseName = null)
    {
        var name = NormalizedFileName(baseName ?? StorageStrings.Get("Library/UntitledFile"));
        var stem = Path.GetFileNameWithoutExtension(name);
        var extension = Path.GetExtension(name);
        for (var n = 1; ; n++)
        {
            var candidate = n == 1 ? name : FormattableString.Invariant($"{stem} {n}{extension}");
            var path = Path.Combine(directory, candidate);
            if (!File.Exists(path) && !Directory.Exists(path))
            {
                return candidate;
            }
        }
    }

    /// <summary>Creates a new SQL file in <paramref name="directory"/> and returns its path. The file is never overwritten if it appeared meanwhile.</summary>
    public static async Task<string> CreateAsync(string directory, string? name = null, string content = "", CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(directory);
        var fileName = name is null ? UniqueFileName(directory) : NormalizedFileName(name);
        var problem = Validate(directory, fileName);
        if (problem != SqlFileNameProblem.None)
        {
            throw new IOException(Describe(problem));
        }

        var path = Path.Combine(directory, fileName);
        var bytes = SqlTextFile.Encode(content, new System.Text.UTF8Encoding(false), withByteOrderMark: false);
        await using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.Asynchronous);
        await stream.WriteAsync(bytes, cancellationToken);
        return path;
    }

    /// <summary>Renames a file in place, keeping its folder, and returns the new path.</summary>
    public static string Rename(string path, string newName)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        var problem = Validate(directory, newName, path);
        if (problem != SqlFileNameProblem.None)
        {
            throw new IOException(Describe(problem));
        }

        var target = Path.Combine(directory, NormalizedFileName(newName));
        if (!string.Equals(Path.GetFullPath(path), target, StringComparison.Ordinal))
        {
            File.Move(path, target, overwrite: false);
        }

        return target;
    }

    /// <summary>Writes the header keys the app owns into a file, keeping every other byte of its header and its encoding.</summary>
    public static async Task WriteMetadataAsync(string path, SqlFileMetadata metadata, CancellationToken cancellationToken = default)
    {
        var original = await SqlTextFile.ReadAsync(path, cancellationToken);
        var rewritten = SqlFrontmatter.Rewrite(original.Text, metadata);
        var encoded = SqlTextFile.Encode(rewritten, original.Encoding, original.HasByteOrderMark);

        // Latin-1 turns what it cannot hold into '?'; writing that would silently corrupt the name.
        if (original.Encoding.GetString(original.Encoding.GetBytes(rewritten)) != rewritten)
        {
            throw new IOException(StorageStrings.Format("Library/EncodingCannotHold", original.EncodingName));
        }

        await SqlTextFile.WriteBytesAsync(path, encoded, cancellationToken);
    }
}
