namespace TablePro.Storage.Library.Git;

/// <summary>Whether a git command only reads the repository or may change it and run the user's hooks.</summary>
public enum GitAccess
{
    Read,

    // Runs the repository's hooks and the user's credential helpers, as git in a terminal does.
    Write,
}

/// <summary>
/// One git invocation: its arguments, where it runs and how long it may take. The factory methods are the only
/// commands the app runs, so every argument list is reviewed here rather than assembled at call sites.
/// </summary>
public sealed record GitCommand(IReadOnlyList<string> Arguments, string WorkingDirectory, GitAccess Access = GitAccess.Read, TimeSpan? Timeout = null)
{
    public static readonly TimeSpan WriteTimeout = TimeSpan.FromMinutes(5);

    public const string HistoryFormat = "%x1e%H%x1f%an%x1f%aI%x1f%s";

    // The same hardening the macOS app passes: no index lock for reads, no pager, no colors, no file system monitor
    // daemon, and pathspecs taken literally so a file named "*.sql" means that file.
    internal static readonly string[] HardeningArguments =
    [
        "--no-optional-locks",
        "--no-pager",
        "--literal-pathspecs",
        "-c", "core.fsmonitor=false",
        "-c", "color.ui=never",
        "-c", "log.showSignature=false",
        "-c", "safe.bareRepository=explicit",
        "-c", "i18n.logOutputEncoding=UTF-8",
    ];

    // A read never needs a hook; pointing the hooks at a folder that cannot exist keeps a cloned repository's hooks
    // from running just because the app looked at its status.
    internal static readonly string[] ReadOnlyArguments = ["-c", "core.hooksPath=/dev/null"];

    internal static readonly IReadOnlyDictionary<string, string> EnvironmentOverrides = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["GIT_OPTIONAL_LOCKS"] = "0",
        ["GIT_TERMINAL_PROMPT"] = "0",
        ["GIT_PAGER"] = "cat",
        ["GIT_NO_LAZY_FETCH"] = "1",
    };

    // Set by a parent git (a hook, a rebase) these would point the child at another repository than the folder's.
    internal static readonly HashSet<string> InheritedRepositoryVariables = new(StringComparer.OrdinalIgnoreCase)
    {
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_NAMESPACE",
        "GIT_CEILING_DIRECTORIES",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
        "GIT_EXTERNAL_DIFF",
    };

    /// <summary>What the process receives: the hardening, the read-only switch for reads, then the command.</summary>
    public IReadOnlyList<string> ProcessArguments =>
        [.. HardeningArguments, .. Access == GitAccess.Read ? ReadOnlyArguments : [], .. Arguments];

    /// <summary>The child's environment: the parent's without repository overrides, plus the non-interactive settings.</summary>
    public static Dictionary<string, string> Environment(IEnumerable<KeyValuePair<string, string>> parent)
    {
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in parent)
        {
            if (!InheritedRepositoryVariables.Contains(key))
            {
                environment[key] = value;
            }
        }

        foreach (var (key, value) in EnvironmentOverrides)
        {
            environment[key] = value;
        }

        return environment;
    }

    public static GitCommand RepositoryInfo(string directory) =>
        new(["rev-parse", "--show-toplevel", "--absolute-git-dir", "--show-prefix"], directory);

    public static GitCommand VerifyHead(string directory) =>
        new(["rev-parse", "--verify", "--quiet", "HEAD"], directory);

    public static GitCommand Status(string directory, string pathspec = ".") =>
        new(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--find-renames", "--", pathspec], directory);

    public static GitCommand TrackedFiles(string directory) =>
        new(["ls-files", "-z", "--full-name", "--", "."], directory);

    public static GitCommand FileHistory(string filePath, int limit) =>
        new(
            [
                "log", "--follow", "-z", "--no-color", "--no-show-signature", "--name-status",
                FormattableString.Invariant($"--max-count={limit}"), "--format=" + HistoryFormat, "--", Path.GetFileName(filePath),
            ],
            Path.GetDirectoryName(Path.GetFullPath(filePath))!);

    /// <summary>A file's bytes at a revision; an empty revision reads the staged version.</summary>
    public static GitCommand Blob(string revision, string path, string directory) =>
        new(["cat-file", "blob", "--end-of-options", revision + ":" + path], directory);

    public static GitCommand CurrentBranch(string directory) =>
        new(["symbolic-ref", "--quiet", "--short", "HEAD"], directory);

    public static GitCommand UpstreamDivergence(string directory) =>
        new(["rev-list", "--left-right", "--count", "--end-of-options", "HEAD...@{upstream}"], directory);

    public static GitCommand ChangedPaths(string oldCommit, string newCommit, string directory) =>
        new(["diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", "--end-of-options", oldCommit, newCommit, "--"], directory);

    public static GitCommand Stage(IReadOnlyList<string> paths, string directory) =>
        new(["add", "--", .. paths], directory, GitAccess.Write, WriteTimeout);

    public static GitCommand Commit(IReadOnlyList<string> paths, string message, string directory) =>
        new(["commit", "--only", "--message=" + message, "--", .. paths], directory, GitAccess.Write, WriteTimeout);

    public static GitCommand Pull(string directory) =>
        new(["pull", "--no-rebase", "--ff-only"], directory, GitAccess.Write, WriteTimeout);

    public static GitCommand Push(string directory) =>
        new(["push"], directory, GitAccess.Write, WriteTimeout);
}
