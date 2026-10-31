using System.Globalization;
using System.Text;

namespace TablePro.Storage.Library.Git;

/// <summary>One path in <c>git status</c>, relative to the repository's top level with forward slashes.</summary>
public sealed record GitStatusRecord(string Path, string? OriginalPath, GitFileStatus Status);

/// <summary>Where a folder sits in its repository. <see cref="Prefix"/> is the folder's path from the top level, ending in a slash, or empty at the root.</summary>
public sealed record GitRepositoryInfo(string TopLevel, string GitDirectory, string Prefix);

/// <summary>A commit that touched a file, with the path the file had in it.</summary>
public sealed record GitCommitRecord(string Hash, string Author, DateTimeOffset? Date, string Subject, string? Path);

public static class GitOutputTokens
{
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>Splits on a byte, keeping empty pieces. A piece that is not UTF-8 is read as Latin-1 rather than lost.</summary>
    public static IReadOnlyList<string> Split(ReadOnlySpan<byte> data, byte separator)
    {
        var tokens = new List<string>();
        while (true)
        {
            var index = data.IndexOf(separator);
            var piece = index < 0 ? data : data[..index];
            tokens.Add(Decode(piece));
            if (index < 0)
            {
                return tokens;
            }

            data = data[(index + 1)..];
        }
    }

    public static string Decode(ReadOnlySpan<byte> bytes)
    {
        try
        {
            return StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return Encoding.Latin1.GetString(bytes);
        }
    }
}

public static class GitStatusParser
{
    public static IReadOnlyList<GitStatusRecord> Parse(ReadOnlySpan<byte> data)
    {
        var tokens = GitOutputTokens.Split(data, 0);
        var records = new List<GitStatusRecord>();
        var index = 0;
        while (index < tokens.Count)
        {
            var token = tokens[index++];
            if (token.Length == 0)
            {
                continue;
            }

            switch (token[0])
            {
                case '1':
                    Add(records, Tracked(token, 8));
                    break;
                case '2':
                    // A rename's original path is the next NUL-separated token.
                    var original = index < tokens.Count ? tokens[index] : null;
                    index++;
                    Add(records, Tracked(token, 9, original));
                    break;
                case 'u':
                    Add(records, Tracked(token, 10, isUnmergedEntry: true));
                    break;
                case '?':
                    if (token.Length > 2)
                    {
                        records.Add(new GitStatusRecord(token[2..], null, GitFileStatus.Untracked));
                    }

                    break;
            }
        }

        return records;
    }

    private static void Add(List<GitStatusRecord> records, GitStatusRecord? record)
    {
        if (record is not null)
        {
            records.Add(record);
        }
    }

    private static GitStatusRecord? Tracked(string token, int fieldCount, string? originalPath = null, bool isUnmergedEntry = false)
    {
        // The path is the last field and may itself contain spaces, so only the fields before it are split.
        var fields = token.Split(' ', fieldCount + 1);
        if (fields.Length != fieldCount + 1 || fields[fieldCount].Length == 0)
        {
            return null;
        }

        return new GitStatusRecord(fields[fieldCount], originalPath, GitFileStatus.FromCode(fields[1], isUnmergedEntry));
    }
}

public static class GitRepositoryInfoParser
{
    public static GitRepositoryInfo? Parse(ReadOnlySpan<byte> data)
    {
        var lines = GitOutputTokens.Decode(data).Split('\n');
        if (lines.Length < 2 || lines[0].TrimEnd('\r').Length == 0 || lines[1].TrimEnd('\r').Length == 0)
        {
            return null;
        }

        // Git for Windows prints C:/x/y; the rest of the app compares paths in their Windows form.
        return new GitRepositoryInfo(
            NativePath(lines[0].TrimEnd('\r')),
            NativePath(lines[1].TrimEnd('\r')),
            lines.Length > 2 ? lines[2].TrimEnd('\r') : string.Empty);
    }

    private static string NativePath(string path) =>
        Path.IsPathRooted(path) ? Path.GetFullPath(path) : path;
}

public static class GitLogParser
{
    private const char RecordSeparator = '\u001e';
    private const char FieldSeparator = '\u001f';

    public static IReadOnlyList<GitCommitRecord> Parse(ReadOnlySpan<byte> data)
    {
        var commits = new List<GitCommitRecord>();
        string[]? header = null;
        var paths = new List<string>();
        var changeStatus = string.Empty;
        var expectsStatus = false;

        void Flush()
        {
            // A commit that deleted the file has no version of it to show.
            if (header is not { Length: >= 3 } || !IsCommitHash(header[0]) || changeStatus.StartsWith('D'))
            {
                return;
            }

            DateTimeOffset? date = DateTimeOffset.TryParse(header[2], CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed) ? parsed : null;
            commits.Add(new GitCommitRecord(header[0], header[1], date, header.Length > 3 ? header[3] : string.Empty, paths.Count > 0 ? paths[^1] : null));
        }

        foreach (var token in GitOutputTokens.Split(data, 0))
        {
            if (token.Length > 0 && token[0] == RecordSeparator)
            {
                Flush();
                header = token[1..].Split(FieldSeparator, 4);
                paths.Clear();
                changeStatus = string.Empty;
                expectsStatus = true;
                continue;
            }

            var trimmed = token.Trim('\n', '\r');
            if (trimmed.Length == 0)
            {
                continue;
            }

            if (expectsStatus)
            {
                expectsStatus = false;
                changeStatus = trimmed;
                continue;
            }

            paths.Add(trimmed);
        }

        Flush();
        return commits;
    }

    /// <summary>
    /// A SHA-1 or SHA-256 object id. Only these reach a <c>cat-file</c> argument, so a crafted header can never become
    /// an option.
    /// </summary>
    public static bool IsCommitHash(string value) =>
        value.Length is 40 or 64 && value.All(char.IsAsciiHexDigit);
}
