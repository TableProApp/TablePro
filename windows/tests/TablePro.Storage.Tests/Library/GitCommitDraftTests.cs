using TablePro.Storage.Library.Git;

namespace TablePro.Storage.Tests.Library;

public sealed class GitCommitDraftTests
{
    private static readonly GitFileStatus Modified = new(GitChange.Unmodified, GitChange.Modified);

    [Fact]
    public void FromTheFolderEveryCommittableFileUnderItIsCheckedSortedByNameAndNothingOutsideIsListed()
    {
        var draft = new GitCommitDraft(
            [new("q/b.sql", null, Modified), new("q/a.sql", null, GitFileStatus.Untracked), new("other/c.sql", null, Modified)],
            "q/");

        Assert.Equal(["a.sql", "b.sql"], draft.Entries.Select(e => e.FolderRelativePath));
        Assert.Equal(2, draft.CheckedEntries.Count);
    }

    [Fact]
    public void FromAFileOnlyThatFileIsChecked()
    {
        var draft = new GitCommitDraft([new("q/a.sql", null, Modified), new("q/b.sql", null, Modified)], "q/", preselecting: "b.sql");
        Assert.Equal(["q/b.sql"], draft.CheckedEntries.Select(e => e.Path));
    }

    [Fact]
    public void AConflictedFileIsListedButCanNeverBeChecked()
    {
        var conflicted = new GitFileStatus(GitChange.Unmerged, GitChange.Unmerged, IsUnmergedEntry: true);
        var draft = new GitCommitDraft([new("q/c.sql", null, conflicted)], "q/");
        var entry = Assert.Single(draft.Entries);

        draft.SetChecked(entry, true);

        Assert.False(draft.IsChecked(entry));
        Assert.Empty(draft.CheckedEntries);
    }

    [Fact]
    public void CommitNeedsACheckedFileAndAMessageThatIsMoreThanWhitespace()
    {
        var draft = new GitCommitDraft([new("q/a.sql", null, Modified)], "q/");
        Assert.False(draft.CanCommit);
        draft.Message = "   ";
        Assert.False(draft.CanCommit);
        draft.Message = "Fix report";
        Assert.True(draft.CanCommit);
        draft.SetChecked(draft.Entries[0], false);
        Assert.False(draft.CanCommit);
    }

    [Fact]
    public void AStagedRenameInsideTheFolderCommitsItsOldPathTooButOneFromOutsideOrListedAgainDoesNot()
    {
        var renamed = new GitFileStatus(GitChange.Renamed, GitChange.Unmodified);
        var inside = new GitCommitDraft([new("q/new.sql", "q/old.sql", renamed)], "q/");
        Assert.Equal(["q/new.sql", "q/old.sql"], inside.CommitPaths);

        var outside = new GitCommitDraft([new("q/new.sql", "elsewhere/old.sql", renamed)], "q/");
        Assert.Equal(["q/new.sql"], outside.CommitPaths);

        var listedAgain = new GitCommitDraft([new("q/new.sql", "q/old.sql", renamed), new("q/old.sql", null, GitFileStatus.Untracked)], "q/");
        listedAgain.SetChecked(listedAgain.Entries.Single(e => e.Path == "q/old.sql"), false);
        Assert.Equal(["q/new.sql"], listedAgain.CommitPaths);
    }

    [Fact]
    public void OnlyCheckedUntrackedFilesAreAddedBeforeTheCommit()
    {
        var draft = new GitCommitDraft([new("q/a.sql", null, GitFileStatus.Untracked), new("q/b.sql", null, GitFileStatus.Untracked), new("q/c.sql", null, Modified)], "q/");
        draft.SetChecked(draft.Entries[1], false);
        Assert.Equal(["q/a.sql"], draft.UntrackedPaths);
    }

    [Fact]
    public void AnIndexDeletionAndAnUntrackedFileAtOnePathAreOneEntry()
    {
        var deleted = new GitFileStatus(GitChange.Deleted, GitChange.Unmodified);
        var draft = new GitCommitDraft([new("q/a.sql", null, GitFileStatus.Untracked), new("q/a.sql", null, deleted)], "q/");
        var entry = Assert.Single(draft.Entries);
        Assert.Equal(GitChange.Deleted, entry.Status.Staged);
    }
}
