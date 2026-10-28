using TablePro.Storage.Library.Folders;
using TablePro.Storage.Library.Git;

namespace TablePro.Storage.Library.History;

/// <summary>
/// A file's versions from Git: the working copy first, then each commit that touched it, following renames, as the
/// macOS app's linked file history does. A restore writes the committed bytes back, so the file keeps its encoding.
/// </summary>
public sealed class GitFileHistoryProvider(string filePath, GitClient? client) : IVersionHistoryProvider
{
    public const int CommitLimit = 200;

    private static readonly byte[] LargeFileStoragePointerPrefix = "version https://git-lfs.github.com/spec/v1"u8.ToArray();

    public string FilePath { get; } = Path.GetFullPath(filePath);

    private string Directory => Path.GetDirectoryName(FilePath)!;

    private string FileName => Path.GetFileName(FilePath);

    // The index path is relative to the file's folder, which is where every command runs.
    private string IndexPath => "./" + FileName;

    public async Task<VersionPage> LoadHistoryAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(FilePath))
        {
            throw new VersionHistoryException(VersionHistoryError.SubjectNotFound);
        }

        var git = Client();
        var info = await Call(() => git.RepositoryInfoAsync(Directory, cancellationToken))
            ?? throw new VersionHistoryException(VersionHistoryError.NotInRepository);
        var records = await Call(() => git.StatusAsync(Directory, FileName, cancellationToken));
        var current = new VersionEntry(VersionReference.Current, File.GetLastWriteTimeUtc(FilePath), HasUncommittedChanges: records.Count > 0);
        if (!await Call(() => git.HasCommitsAsync(Directory, cancellationToken)))
        {
            return new VersionPage([current], []);
        }

        var commits = await Call(() => git.HistoryAsync(FilePath, CommitLimit + 1, cancellationToken));
        var currentPath = info.Prefix + FileName;
        var past = commits.Take(CommitLimit).Select(c => new VersionEntry(new GitRevisionVersion(c.Hash, c.Path ?? currentPath), c.Date, c.Subject, c.Author));
        return new VersionPage([current, .. past], commits.Count > CommitLimit ? [new ShowsLatestCommitsNotice(CommitLimit)] : []);
    }

    public async Task<string> ContentAsync(VersionReference reference, CancellationToken cancellationToken = default)
    {
        switch (reference)
        {
            case CurrentVersion:
                return await ReadCurrentTextAsync(FilePath, cancellationToken);
            case GitRevisionVersion revision:
                var git = Client();
                var data = await Call(() => git.BlobAsync(revision.Commit, revision.Path, Directory, cancellationToken));
                return DecodeText(data);
            default:
                throw new VersionHistoryException(VersionHistoryError.VersionNotFound);
        }
    }

    public async Task<VersionRestorePlan> PrepareRestoreAsync(VersionReference reference, CancellationToken cancellationToken = default)
    {
        if (reference is not GitRevisionVersion revision)
        {
            throw new VersionHistoryException(VersionHistoryError.VersionNotFound);
        }

        var git = Client();
        var current = await CurrentBytesAsync(cancellationToken);
        var replacement = await Call(() => git.BlobAsync(revision.Commit, revision.Path, Directory, cancellationToken));
        RejectLargeFileStoragePointer(replacement);
        var replacesUncommitted = await DiffersFromLastCommitAsync(current, git, cancellationToken);
        return WritePlan(current, replacement, replacesUncommitted, _ => Task.FromResult(true));
    }

    /// <summary>Puts back the staged version of the file (the committed one when nothing is staged), as Discard Changes does.</summary>
    public async Task<VersionRestorePlan> PrepareDiscardAsync(CancellationToken cancellationToken = default)
    {
        var git = Client();
        var current = await CurrentBytesAsync(cancellationToken);
        var staged = await Call(() => git.BlobAsync(string.Empty, IndexPath, Directory, cancellationToken));
        RejectLargeFileStoragePointer(staged);
        return WritePlan(current, staged, true, async ct =>
        {
            try
            {
                return (await git.BlobAsync(string.Empty, IndexPath, Directory, ct)).AsSpan().SequenceEqual(staged);
            }
            catch (GitCommandException)
            {
                return false;
            }
        });
    }

    public static void RejectLargeFileStoragePointer(byte[] data)
    {
        if (data.AsSpan().StartsWith(LargeFileStoragePointerPrefix))
        {
            throw new VersionHistoryException(VersionHistoryError.StoredInLargeFileStorage);
        }
    }

    /// <summary>Text from a past version's bytes. A NUL byte without a byte order mark means a binary file, which has no text to show.</summary>
    public static string DecodeText(byte[] data)
    {
        var hasBom = data.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xFF, 0xFE]) || data.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xFE, 0xFF]);
        if (!hasBom && data.AsSpan().Contains((byte)0))
        {
            throw new VersionHistoryException(VersionHistoryError.UndecodableContent);
        }

        return SqlTextFile.Decode(data).Text;
    }

    internal static async Task<string> ReadCurrentTextAsync(string path, CancellationToken cancellationToken)
    {
        try
        {
            return (await SqlTextFile.ReadAsync(path, cancellationToken)).Text;
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
        {
            throw new VersionHistoryException(VersionHistoryError.SubjectNotFound, innerException: ex);
        }
    }

    internal static VersionRestorePlan WritePlan(string path, byte[] expected, byte[] replacement, bool replacesUncommitted, Func<CancellationToken, Task<bool>> sourceIsUnchanged) =>
        new(replacesUncommitted, async ct =>
        {
            byte[] onDisk;
            try
            {
                onDisk = await File.ReadAllBytesAsync(path, ct);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                throw new VersionHistoryException(VersionHistoryError.FileChangedBeforeWriting, innerException: ex);
            }

            if (!await sourceIsUnchanged(ct) || !onDisk.AsSpan().SequenceEqual(expected))
            {
                throw new VersionHistoryException(VersionHistoryError.FileChangedBeforeWriting);
            }

            try
            {
                await SqlTextFile.WriteBytesAsync(path, replacement, ct);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                throw new VersionHistoryException(VersionHistoryError.RestoreFailed, ex.Message, ex);
            }
        });

    private VersionRestorePlan WritePlan(byte[] expected, byte[] replacement, bool replacesUncommitted, Func<CancellationToken, Task<bool>> sourceIsUnchanged) =>
        WritePlan(FilePath, expected, replacement, replacesUncommitted, sourceIsUnchanged);

    private async Task<byte[]> CurrentBytesAsync(CancellationToken cancellationToken)
    {
        try
        {
            return await File.ReadAllBytesAsync(FilePath, cancellationToken);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new VersionHistoryException(VersionHistoryError.SubjectNotFound, innerException: ex);
        }
    }

    // Git can be told to ignore a file's changes (assume-unchanged); comparing bytes with HEAD catches those too.
    private async Task<bool> DiffersFromLastCommitAsync(byte[] current, GitClient git, CancellationToken cancellationToken)
    {
        var records = await Call(() => git.StatusAsync(Directory, FileName, cancellationToken));
        if (records.Count > 0 || !await Call(() => git.HasCommitsAsync(Directory, cancellationToken)))
        {
            return true;
        }

        try
        {
            return !(await git.BlobAsync("HEAD", IndexPath, Directory, cancellationToken)).AsSpan().SequenceEqual(current);
        }
        catch (GitCommandException)
        {
            return true;
        }
    }

    private GitClient Client() => client ?? throw new VersionHistoryException(VersionHistoryError.GitUnavailable);

    private static async Task<T> Call<T>(Func<Task<T>> operation)
    {
        try
        {
            return await operation();
        }
        catch (GitCommandException ex)
        {
            throw new VersionHistoryException(VersionHistoryError.CommandFailed, ex.Message, ex);
        }
        catch (GitProcessException ex)
        {
            throw new VersionHistoryException(VersionHistoryError.CommandFailed, ex.Failure == GitProcessFailure.OutputTooLarge ? "The file is too large to read from Git." : ex.Message, ex);
        }
    }
}
