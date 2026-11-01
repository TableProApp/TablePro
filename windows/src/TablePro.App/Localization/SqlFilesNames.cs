using TablePro.Storage.Library.Folders;
using TablePro.Storage.Library.Git;
using TablePro.Storage.Library.History;

namespace TablePro.App.Localization;

/// <summary>
/// The SQL files pane's text for values the library describes in English: a file's Git state, a rejected file name,
/// a failed Git command and the version history notices.
/// </summary>
internal static class SqlFilesNames
{
    public static string GitBadgeLabel(GitBadge badge) => badge switch
    {
        GitBadge.Modified => Strings.Get("SqlFiles/GitModified"),
        GitBadge.Added => Strings.Get("SqlFiles/GitAdded"),
        GitBadge.Renamed => Strings.Get("SqlFiles/GitRenamed"),
        GitBadge.Untracked => Strings.Get("SqlFiles/GitUntracked"),
        _ => Strings.Get("SqlFiles/GitConflicted"),
    };

    public static string GitStatus(GitFileStatus status)
    {
        var label = GitBadgeLabel(status.Badge);
        if (status.IsUntracked || status.IsConflicted)
        {
            return label;
        }

        return (status.HasStagedChanges, status.Unstaged != GitChange.Unmodified) switch
        {
            (true, false) => Strings.Format("SqlFiles/GitStaged", label),
            (true, true) => Strings.Format("SqlFiles/GitPartlyStaged", label),
            _ => label,
        };
    }

    public static string FileNameProblem(SqlFileNameProblem problem) => problem switch
    {
        SqlFileNameProblem.Empty => Strings.Get("SqlFiles/NameEmpty"),
        SqlFileNameProblem.InvalidCharacters => Strings.Get("SqlFiles/NameInvalidCharacters"),
        SqlFileNameProblem.Reserved => Strings.Get("SqlFiles/NameReserved"),
        SqlFileNameProblem.AlreadyExists => Strings.Get("SqlFiles/NameAlreadyExists"),
        _ => string.Empty,
    };

    public static string GitError(Exception error) => error switch
    {
        GitPullDivergedException => Strings.Get("SqlFiles/GitPullDiverged"),
        GitCommandException => Strings.Get("SqlFiles/GitCommandFailed"),
        GitProcessException { Failure: GitProcessFailure.TimedOut } => Strings.Get("SqlFiles/GitTimedOut"),
        GitProcessException { Failure: GitProcessFailure.OutputTooLarge } => Strings.Get("SqlFiles/GitOutputTooLarge"),
        GitUnavailableException => Strings.Get("SqlFiles/GitUnavailable"),
        _ => error.Message,
    };

    public static string Notice(VersionHistoryNotice notice) => notice switch
    {
        KeepsLatestSnapshotsNotice keeps => Strings.Plural("SqlFiles/KeepsLatestSnapshots", keeps.Count),
        ShowsLatestCommitsNotice shows => Strings.Plural("SqlFiles/ShowsLatestCommits", shows.Count),
        _ => notice.Text,
    };
}
