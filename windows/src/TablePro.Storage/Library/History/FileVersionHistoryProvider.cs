using TablePro.Storage.Library.Folders;
using TablePro.Storage.Library.Git;
using TablePro.Storage.Localization;

namespace TablePro.Storage.Library.History;

/// <summary>
/// A file's versions from both sources: the copies the app kept each time it saved the file, and the file's commits
/// when it sits in a Git repository, merged newest first. A file outside a repository, or a machine without Git,
/// simply shows the saved copies.
/// </summary>
public sealed class FileVersionHistoryProvider(string filePath, LocalSnapshotStore snapshots, GitClient? git) : IVersionHistoryProvider
{
    public string FilePath { get; } = Path.GetFullPath(filePath);

    public string Subject => LocalSnapshotStore.FileSubject(FilePath);

    private GitFileHistoryProvider Git { get; } = new(filePath, git);

    public async Task<VersionPage> LoadHistoryAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(FilePath))
        {
            throw new VersionHistoryException(VersionHistoryError.SubjectNotFound);
        }

        var currentText = await GitFileHistoryProvider.ReadCurrentTextAsync(FilePath, cancellationToken);
        var kept = await snapshots.ListAsync(Subject, cancellationToken);

        // The newest copy is usually the text on disk, saved a moment ago; listing it again would be a version
        // identical to Current.
        var past = kept.SkipWhile((s, i) => i == 0 && string.Equals(s.Content, currentText, StringComparison.Ordinal))
            .Select(s => new VersionEntry(new SnapshotVersion(s.Id), s.SavedAt, StorageStrings.Get("Library/SavedInTablePro")))
            .ToList();
        var notices = new List<VersionHistoryNotice>();
        if (kept.Count >= LocalSnapshotStore.RetainedCount)
        {
            notices.Add(new KeepsLatestSnapshotsNotice(LocalSnapshotStore.RetainedCount));
        }

        var current = new VersionEntry(VersionReference.Current, File.GetLastWriteTimeUtc(FilePath));
        try
        {
            var page = await Git.LoadHistoryAsync(cancellationToken);
            current = page.Current ?? current;
            past.AddRange(page.Entries.Where(e => !e.IsCurrent));
            notices.AddRange(page.Notices);
        }
        catch (VersionHistoryException ex) when (ex.Error is VersionHistoryError.NotInRepository or VersionHistoryError.GitUnavailable)
        {
        }
        catch (VersionHistoryException ex) when (ex.Error == VersionHistoryError.CommandFailed)
        {
            notices.Add(new GitHistoryUnavailableNotice(StorageStrings.Format("Library/GitHistoryUnavailable", ex.Message)));
        }

        var ordered = past.OrderByDescending(e => e.Date ?? DateTimeOffset.MinValue).ToList();
        return new VersionPage([current, .. ordered], notices);
    }

    public async Task<string> ContentAsync(VersionReference reference, CancellationToken cancellationToken = default) => reference switch
    {
        CurrentVersion => await GitFileHistoryProvider.ReadCurrentTextAsync(FilePath, cancellationToken),
        SnapshotVersion snapshot => (await Snapshot(snapshot, cancellationToken)).Content,
        GitRevisionVersion => await Git.ContentAsync(reference, cancellationToken),
        _ => throw new VersionHistoryException(VersionHistoryError.VersionNotFound),
    };

    /// <summary>
    /// A restore from either source first keeps the text it replaces as a saved copy, so a restore can itself be undone
    /// from the same list.
    /// </summary>
    public async Task<VersionRestorePlan> PrepareRestoreAsync(VersionReference reference, CancellationToken cancellationToken = default)
    {
        byte[] current;
        try
        {
            current = await File.ReadAllBytesAsync(FilePath, cancellationToken);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new VersionHistoryException(VersionHistoryError.SubjectNotFound, innerException: ex);
        }

        var currentText = SqlTextFile.Decode(current);
        VersionRestorePlan plan;
        switch (reference)
        {
            case SnapshotVersion snapshot:
                var kept = await Snapshot(snapshot, cancellationToken);
                var replacement = SqlTextFile.Encode(kept.Content, currentText.Encoding, currentText.HasByteOrderMark);
                var all = await snapshots.ListAsync(Subject, cancellationToken);
                var newest = all.Count > 0 ? all[0] : null;
                var unsaved = newest is null || !string.Equals(newest.Content, currentText.Text, StringComparison.Ordinal);
                plan = GitFileHistoryProvider.WritePlan(FilePath, current, replacement, unsaved, _ => Task.FromResult(true));
                break;
            case GitRevisionVersion:
                plan = await Git.PrepareRestoreAsync(reference, cancellationToken);
                break;
            default:
                throw new VersionHistoryException(VersionHistoryError.VersionNotFound);
        }

        return plan with
        {
            Apply = async ct =>
            {
                await snapshots.RecordAsync(Subject, currentText.Text, cancellationToken: ct);
                await plan.Apply(ct);
                await RecordFileAsync(snapshots, FilePath, ct);
            },
        };
    }

    /// <summary>Keeps the file's text as it is on disk now as a saved copy. This is what runs after the editor saves a file.</summary>
    public static async Task<bool> RecordFileAsync(LocalSnapshotStore store, string path, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(store);
        try
        {
            var content = await SqlTextFile.ReadAsync(path, cancellationToken);
            return await store.RecordAsync(LocalSnapshotStore.FileSubject(path), content.Text, cancellationToken: cancellationToken);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private async Task<LocalSnapshot> Snapshot(SnapshotVersion version, CancellationToken cancellationToken) =>
        await snapshots.GetAsync(version.Id, cancellationToken) is { } snapshot && snapshot.Subject == Subject
            ? snapshot
            : throw new VersionHistoryException(VersionHistoryError.VersionNotFound);
}
