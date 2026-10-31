namespace TablePro.Storage.Library.Git;

/// <summary>How far a branch is ahead of and behind its upstream.</summary>
public readonly record struct GitUpstreamDivergence(int Ahead, int Behind)
{
    public bool HasDiverged => Ahead > 0 && Behind > 0;
}

/// <summary>
/// The git operations linked folders and file history need, over the git executable the user installed, as the macOS
/// app does. Reads never take the index lock and never run hooks; commit, pull and push run as the user's own git.
/// </summary>
public sealed class GitClient(IGitProcessRunner runner)
{
    public IGitProcessRunner Runner { get; } = runner;

    /// <summary>A client over the git found on this machine, or null when there is none.</summary>
    public static GitClient? Create(GitExecutableLocator? locator = null) =>
        (locator ?? GitExecutableLocator.System).Locate() is { } path ? new GitClient(new GitProcessRunner(path)) : null;

    /// <summary>Where <paramref name="directory"/> sits in its repository, or null when it is in none.</summary>
    public async Task<GitRepositoryInfo?> RepositoryInfoAsync(string directory, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.RepositoryInfo(directory), cancellationToken);
        return result.Succeeded ? GitRepositoryInfoParser.Parse(result.StandardOutput) : null;
    }

    public async Task<string?> HeadCommitAsync(string directory, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.VerifyHead(directory), cancellationToken);
        return result.Succeeded ? result.OutputText : null;
    }

    public async Task<bool> HasCommitsAsync(string directory, CancellationToken cancellationToken = default) =>
        await HeadCommitAsync(directory, cancellationToken) is not null;

    public async Task<IReadOnlyList<GitStatusRecord>> StatusAsync(string directory, string pathspec = ".", CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.Status(directory, pathspec), cancellationToken);
        return result.Succeeded ? GitStatusParser.Parse(result.StandardOutput) : throw ReadFailure(result);
    }

    public async Task<IReadOnlyList<string>> TrackedFilesAsync(string directory, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.TrackedFiles(directory), cancellationToken);
        return result.Succeeded
            ? [.. GitOutputTokens.Split(result.StandardOutput, 0).Where(p => p.Length > 0)]
            : throw ReadFailure(result);
    }

    public async Task<IReadOnlyList<GitCommitRecord>> HistoryAsync(string filePath, int limit, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.FileHistory(filePath, limit), cancellationToken);
        return result.Succeeded ? GitLogParser.Parse(result.StandardOutput) : throw ReadFailure(result);
    }

    /// <summary>A file's bytes at <paramref name="revision"/>; an empty revision reads the staged version.</summary>
    public async Task<byte[]> BlobAsync(string revision, string path, string directory, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.Blob(revision, path, directory), cancellationToken);
        return result.Succeeded ? result.StandardOutput : throw ReadFailure(result);
    }

    public async Task<string?> CurrentBranchAsync(string directory, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.CurrentBranch(directory), cancellationToken);
        return result.Succeeded && result.OutputText.Length > 0 ? result.OutputText : null;
    }

    public async Task<GitUpstreamDivergence?> UpstreamDivergenceAsync(string directory, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.UpstreamDivergence(directory), cancellationToken);
        if (!result.Succeeded)
        {
            return null;
        }

        var counts = result.OutputText.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return counts.Length == 2 && int.TryParse(counts[0], out var ahead) && int.TryParse(counts[1], out var behind)
            ? new GitUpstreamDivergence(ahead, behind)
            : null;
    }

    public async Task<IReadOnlyList<string>> ChangedPathsAsync(string oldCommit, string newCommit, string directory, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.ChangedPaths(oldCommit, newCommit, directory), cancellationToken);
        return result.Succeeded
            ? [.. GitOutputTokens.Split(result.StandardOutput, 0).Where(p => p.Length > 0)]
            : throw ReadFailure(result);
    }

    /// <summary>
    /// Commits the working-tree state of <paramref name="paths"/> only and keeps whatever else is staged in the index.
    /// <c>commit --only</c> reaches every tracked path itself; an untracked one has to be added first.
    /// </summary>
    public async Task CommitAsync(IReadOnlyList<string> paths, IReadOnlyList<string> untrackedPaths, string message, string directory, CancellationToken cancellationToken = default)
    {
        if (paths.Count == 0)
        {
            return;
        }

        if (untrackedPaths.Count > 0)
        {
            var staged = await Runner.RunAsync(GitCommand.Stage(untrackedPaths, directory), cancellationToken);
            if (!staged.Succeeded)
            {
                throw WriteFailure(staged);
            }
        }

        var committed = await Runner.RunAsync(GitCommand.Commit(paths, message, directory), cancellationToken);
        if (!committed.Succeeded)
        {
            throw WriteFailure(committed);
        }
    }

    public async Task PullAsync(string directory, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.Pull(directory), cancellationToken);
        if (result.Succeeded)
        {
            return;
        }

        var failure = WriteFailure(result);
        if (await UpstreamDivergenceAsync(directory, cancellationToken) is { HasDiverged: true })
        {
            throw new GitPullDivergedException(result.ExitCode, failure.Output);
        }

        throw failure;
    }

    public async Task PushAsync(string directory, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(GitCommand.Push(directory), cancellationToken);
        if (!result.Succeeded)
        {
            throw WriteFailure(result);
        }
    }

    private static GitCommandException ReadFailure(GitProcessResult result) => new(result.ExitCode, result.ErrorMessage);

    private static GitCommandException WriteFailure(GitProcessResult result) => new(result.ExitCode, result.CombinedOutput);
}
