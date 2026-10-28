using System.Text;
using TablePro.Storage.Library;
using TablePro.Storage.Library.Folders;
using TablePro.Storage.Library.Git;
using TablePro.Storage.Library.History;

namespace TablePro.Storage.Tests.Library;

/// <summary>Runs the real git against throwaway repositories. Skipped on a machine without Git for Windows.</summary>
public sealed class GitIntegrationTests : IDisposable
{
    private readonly TempDirectory _temp = new();
    private readonly GitClient? _git = GitClient.Create();

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    public void Dispose()
    {
        // Git writes its objects read-only, which would stop the folder from being deleted.
        foreach (var file in Directory.EnumerateFiles(_temp.Path, "*", SearchOption.AllDirectories))
        {
            File.SetAttributes(file, FileAttributes.Normal);
        }

        _temp.Dispose();
    }

    [Fact]
    public async Task StatusFromALinkedSubfolderMapsPathsIntoTheFolderAndNeverWritesTheIndex()
    {
        var git = RequireGit();
        var repo = await NewRepositoryAsync("repo");
        var folder = Directory.CreateDirectory(Path.Combine(repo, "sql queries")).FullName;
        await File.WriteAllTextAsync(Path.Combine(folder, "a.sql"), "SELECT 1;", Ct);
        await CommitAllAsync(repo, "add a");
        await File.WriteAllTextAsync(Path.Combine(folder, "a.sql"), "SELECT 2;", Ct);
        await File.WriteAllTextAsync(Path.Combine(folder, "new.sql"), "SELECT 3;", Ct);
        var indexTime = File.GetLastWriteTimeUtc(Path.Combine(repo, ".git", "index"));

        var snapshots = await LinkedFolderGitStatus.LoadAsync([new LinkedSqlFolder { Path = folder }], git, cancellationToken: Ct);

        var snapshot = Assert.Single(snapshots.Values);
        Assert.Equal("sql queries/", snapshot.Repository.Prefix);
        Assert.Equal(Path.GetFullPath(repo), snapshot.Repository.TopLevel, ignoreCase: true);
        Assert.Equal(GitBadge.Modified, snapshot.StateOf("a.sql")!.Value.Status!.Value.Badge);
        Assert.Equal(GitBadge.Untracked, snapshot.StateOf("new.sql")!.Value.Status!.Value.Badge);
        Assert.Equal(indexTime, File.GetLastWriteTimeUtc(Path.Combine(repo, ".git", "index")));
    }

    [Fact]
    public async Task AFolderOutsideAnyRepositoryIsNotOneAndItsFilesShowOnlySavedCopies()
    {
        var git = RequireGit();
        var plain = Directory.CreateDirectory(_temp.File("plain")).FullName;
        var path = Path.Combine(plain, "a.sql");
        await File.WriteAllTextAsync(path, "SELECT 1;", Ct);

        Assert.Null(await git.RepositoryInfoAsync(plain, Ct));
        using var store = new LocalSnapshotStore(_temp.Paths);
        var page = await new FileVersionHistoryProvider(path, store, git).LoadHistoryAsync(Ct);
        Assert.True(Assert.Single(page.Entries).IsCurrent);
        Assert.Empty(page.Notices);
    }

    [Fact]
    public async Task HistoryFollowsARenameReadsEachVersionAndRestoresOneIntoTheCurrentFile()
    {
        var git = RequireGit();
        var repo = await NewRepositoryAsync("repo");
        var old = Path.Combine(repo, "old name.sql");
        await File.WriteAllTextAsync(old, "SELECT 1;\n", Ct);
        await CommitAllAsync(repo, "first");
        await File.WriteAllTextAsync(old, "SELECT 2;\n", Ct);
        await CommitAllAsync(repo, "second");
        await RunGitAsync(repo, "mv", "old name.sql", "new name.sql");
        await CommitAllAsync(repo, "rename");
        var current = Path.Combine(repo, "new name.sql");
        await File.WriteAllTextAsync(current, "SELECT 3;\n", Ct);

        var provider = new GitFileHistoryProvider(current, git);
        var page = await provider.LoadHistoryAsync(Ct);

        Assert.True(page.Entries[0].HasUncommittedChanges);
        Assert.Equal(["rename", "second", "first"], page.Entries.Skip(1).Select(e => e.Summary));
        Assert.Equal(["new name.sql", "old name.sql", "old name.sql"], page.Entries.Skip(1).Select(e => ((GitRevisionVersion)e.Reference).Path));
        Assert.Equal("SELECT 1;\n", await provider.ContentAsync(page.Entries[3].Reference, Ct));

        var plan = await provider.PrepareRestoreAsync(page.Entries[3].Reference, Ct);
        Assert.True(plan.ReplacesUncommittedChanges);
        await plan.Apply(Ct);
        Assert.Equal("SELECT 1;\n", await File.ReadAllTextAsync(current, Ct));
    }

    [Fact]
    public async Task SavedCopiesAndCommitsAreListedTogetherNewestFirst()
    {
        var git = RequireGit();
        var repo = await NewRepositoryAsync("repo");
        var path = Path.Combine(repo, "a.sql");
        await File.WriteAllTextAsync(path, "SELECT 1;", Ct);
        await CommitAllAsync(repo, "first");
        using var store = new LocalSnapshotStore(_temp.Paths);
        await store.RecordAsync(LocalSnapshotStore.FileSubject(path), "SELECT 0; -- before the commit", DateTimeOffset.UtcNow.AddDays(-1), Ct);
        await File.WriteAllTextAsync(path, "SELECT 2;", Ct);
        await FileVersionHistoryProvider.RecordFileAsync(store, path, Ct);

        var page = await new FileVersionHistoryProvider(path, store, git).LoadHistoryAsync(Ct);

        Assert.True(page.Entries[0].IsCurrent);
        Assert.True(page.Entries[0].HasUncommittedChanges);
        Assert.IsType<GitRevisionVersion>(page.Entries[1].Reference);
        Assert.IsType<SnapshotVersion>(page.Entries[2].Reference);
        Assert.Equal(3, page.Entries.Count);
    }

    [Fact]
    public async Task DiscardPutsBackTheStagedText()
    {
        var git = RequireGit();
        var repo = await NewRepositoryAsync("repo");
        var path = Path.Combine(repo, "a.sql");
        await File.WriteAllTextAsync(path, "SELECT 1;", Ct);
        await CommitAllAsync(repo, "first");
        await File.WriteAllTextAsync(path, "SELECT 2;", Ct);
        await RunGitAsync(repo, "add", "a.sql");
        await File.WriteAllTextAsync(path, "SELECT 3;", Ct);

        var plan = await new GitFileHistoryProvider(path, git).PrepareDiscardAsync(Ct);
        await plan.Apply(Ct);

        Assert.Equal("SELECT 2;", await File.ReadAllTextAsync(path, Ct));
    }

    [Fact]
    public async Task AGitLfsPointerIsNeverWrittenOverTheFile()
    {
        var git = RequireGit();
        var repo = await NewRepositoryAsync("repo");
        var path = Path.Combine(repo, "big.sql");
        await File.WriteAllTextAsync(path, "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12\n", Ct);
        await CommitAllAsync(repo, "lfs");
        await File.WriteAllTextAsync(path, "SELECT 1;", Ct);
        var provider = new GitFileHistoryProvider(path, git);
        var page = await provider.LoadHistoryAsync(Ct);

        var error = await Assert.ThrowsAsync<VersionHistoryException>(() => provider.PrepareRestoreAsync(page.Entries[1].Reference, Ct));
        Assert.Equal(VersionHistoryError.StoredInLargeFileStorage, error.Error);
    }

    [Fact]
    public async Task ACommitFromALinkedFolderRecordsTheCheckedFilesOnlyAndLeavesOtherStagedWorkStaged()
    {
        RequireGit();
        var repo = await NewRepositoryAsync("repo");
        var folder = Directory.CreateDirectory(Path.Combine(repo, "q")).FullName;
        await File.WriteAllTextAsync(Path.Combine(folder, "a.sql"), "SELECT 1;", Ct);
        await File.WriteAllTextAsync(Path.Combine(repo, "README.md"), "readme", Ct);
        await CommitAllAsync(repo, "first");
        await File.WriteAllTextAsync(Path.Combine(folder, "a.sql"), "SELECT 2;", Ct);
        await File.WriteAllTextAsync(Path.Combine(folder, "b.sql"), "SELECT 3;", Ct);
        await File.WriteAllTextAsync(Path.Combine(folder, "c.sql"), "SELECT 4;", Ct);
        await File.WriteAllTextAsync(Path.Combine(repo, "README.md"), "staged elsewhere", Ct);
        await RunGitAsync(repo, "add", "README.md");

        await using var library = await NewLibraryAsync();
        await library.Folders.AddAsync(folder, cancellationToken: Ct);
        await library.RefreshGitAsync(Ct);
        var linked = library.Folders.Folders.Single();
        var (draft, repository) = (await library.CommitDraftAsync(linked, cancellationToken: Ct))!.Value;
        Assert.Equal(["a.sql", "b.sql", "c.sql"], draft.Entries.Select(e => e.FolderRelativePath));
        draft.SetChecked(draft.Entries.Single(e => e.FolderRelativePath == "c.sql"), false);
        draft.Message = "Update queries";

        await library.CommitAsync(draft, repository, Ct);

        var committed = await RunGitAsync(repo, "show", "--name-only", "--format=%s", "HEAD");
        Assert.Contains("Update queries", committed, StringComparison.Ordinal);
        Assert.Contains("q/a.sql", committed, StringComparison.Ordinal);
        Assert.Contains("q/b.sql", committed, StringComparison.Ordinal);
        Assert.DoesNotContain("c.sql", committed, StringComparison.Ordinal);
        Assert.DoesNotContain("README.md", committed, StringComparison.Ordinal);
        var staged = await RunGitAsync(repo, "diff", "--cached", "--name-only");
        Assert.Contains("README.md", staged, StringComparison.Ordinal);
    }

    [Fact]
    public async Task APreCommitHookRunsAndItsRefusalComesBackWithWhatItPrinted()
    {
        RequireGit();
        var repo = await NewRepositoryAsync("repo");
        await File.WriteAllTextAsync(Path.Combine(repo, "a.sql"), "SELECT 1;", Ct);
        await File.WriteAllTextAsync(Path.Combine(repo, ".git", "hooks", "pre-commit"), "#!/bin/sh\necho 'no commits on Fridays' >&2\nexit 1\n", Ct);

        await using var library = await NewLibraryAsync();
        await library.Folders.AddAsync(repo, cancellationToken: Ct);
        var (draft, repository) = (await library.CommitDraftAsync(library.Folders.Folders.Single(), cancellationToken: Ct))!.Value;
        draft.Message = "try";

        var error = await Assert.ThrowsAsync<GitCommandException>(() => library.CommitAsync(draft, repository, Ct));
        Assert.Contains("no commits on Fridays", error.Output, StringComparison.Ordinal);
        Assert.Null(library.OperationFor(library.Folders.Folders.Single().Id));
    }

    [Fact]
    public async Task PullFastForwardsFromTheUpstreamAndACommitPushedFromTheFolderReachesTheRemote()
    {
        RequireGit();
        var remote = Directory.CreateDirectory(_temp.File("remote.git")).FullName;
        await RunGitAsync(remote, "init", "--bare", "--initial-branch=main");
        var mine = await NewRepositoryAsync("mine");
        await File.WriteAllTextAsync(Path.Combine(mine, "a.sql"), "SELECT 1;", Ct);
        await CommitAllAsync(mine, "first");
        await RunGitAsync(mine, "remote", "add", "origin", remote);
        await RunGitAsync(mine, "push", "-u", "origin", "main");

        var theirs = _temp.File("theirs");
        await RunGitAsync(_temp.Path, "clone", remote, theirs);
        await ConfigureAsync(theirs);
        await File.WriteAllTextAsync(Path.Combine(theirs, "a.sql"), "SELECT 2;", Ct);
        await CommitAllAsync(theirs, "theirs");
        await RunGitAsync(theirs, "push");

        await using var library = await NewLibraryAsync();
        await library.Folders.AddAsync(mine, cancellationToken: Ct);
        await library.RefreshGitAsync(Ct);
        var folder = library.Folders.Folders.Single();

        var changed = await library.PullAsync(folder, Ct);
        Assert.Equal([Path.Combine(mine, "a.sql")], changed, StringComparer.OrdinalIgnoreCase);
        Assert.Equal("SELECT 2;", await File.ReadAllTextAsync(Path.Combine(mine, "a.sql"), Ct));

        await File.WriteAllTextAsync(Path.Combine(mine, "b.sql"), "SELECT 3;", Ct);
        var (draft, repository) = (await library.CommitDraftAsync(folder, cancellationToken: Ct))!.Value;
        draft.Message = "add b";
        await library.CommitAsync(draft, repository, Ct);
        await library.PushAsync(folder, Ct);

        // The hardening refuses to discover a bare repository from its folder, so the remote is named explicitly.
        var log = await RunGitAsync(_temp.Path, "--git-dir=" + remote, "log", "--format=%s", "main");
        Assert.StartsWith("add b", log, StringComparison.Ordinal);
    }

    private GitClient RequireGit()
    {
        Assert.SkipWhen(_git is null, "Git for Windows is not installed.");
        return _git!;
    }

    private async Task<SqlLibrary> NewLibraryAsync()
    {
        var library = new SqlLibrary(new LinkedSqlFolderStore(_temp.Paths), new LocalSnapshotStore(_temp.Paths), _git, null, new NoRecycleBin(), TimeSpan.FromMilliseconds(50));
        await library.StartAsync(Ct);
        return library;
    }

    private async Task<string> NewRepositoryAsync(string name)
    {
        var path = Directory.CreateDirectory(_temp.File(name)).FullName;
        await RunGitAsync(path, "init", "--initial-branch=main");
        await ConfigureAsync(path);
        return path;
    }

    private async Task ConfigureAsync(string repo)
    {
        await RunGitAsync(repo, "config", "user.name", "Ann Author");
        await RunGitAsync(repo, "config", "user.email", "ann@example.com");
        await RunGitAsync(repo, "config", "core.autocrlf", "false");
        await RunGitAsync(repo, "config", "commit.gpgsign", "false");
    }

    private async Task CommitAllAsync(string repo, string message)
    {
        await RunGitAsync(repo, "add", "-A");
        await RunGitAsync(repo, "commit", "-m", message);
    }

    private async Task<string> RunGitAsync(string directory, params string[] arguments)
    {
        var result = await _git!.Runner.RunAsync(new GitCommand(arguments, directory, GitAccess.Write, TimeSpan.FromMinutes(1)), Ct);
        Assert.True(result.Succeeded, $"git {string.Join(' ', arguments)} failed: {result.CombinedOutput}");
        return Encoding.UTF8.GetString(result.StandardOutput);
    }

    private sealed class NoRecycleBin : IRecycleBin
    {
        public void MoveToRecycleBin(string path) => File.Delete(path);
    }
}
