using System.Text;
using TablePro.Storage.Library.Git;

namespace TablePro.Storage.Tests.Library;

public sealed class GitOutputParserTests
{
    private static byte[] Bytes(string text) => Encoding.UTF8.GetBytes(text);

    [Fact]
    public void PorcelainRecordsKeepSpacesAndNonAsciiInPathsAndARenameCarriesItsOriginalPath()
    {
        var output = Bytes(
            "1 .M N... 100644 100644 100644 aaaa bbbb sql queries/a b.sql\0"
            + "1 MM N... 100644 100644 100644 aaaa bbbb sql queries/staged.sql\0"
            + "1 A. N... 000000 100644 100644 0000 bbbb sql queries/added.sql\0"
            + "2 R. N... 100644 100644 100644 aaaa aaaa R100 sql queries/new name.sql\0sql queries/old name.sql\0"
            + "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc sql queries/conflict.sql\0"
            + "? sql queries/日本.sql\0");

        var records = GitStatusParser.Parse(output);

        Assert.Equal(
            ["sql queries/a b.sql", "sql queries/staged.sql", "sql queries/added.sql", "sql queries/new name.sql", "sql queries/conflict.sql", "sql queries/日本.sql"],
            records.Select(r => r.Path));
        Assert.Equal(new GitFileStatus(GitChange.Unmodified, GitChange.Modified), records[0].Status);
        Assert.Equal(new GitFileStatus(GitChange.Modified, GitChange.Modified), records[1].Status);
        Assert.Equal(new GitFileStatus(GitChange.Added, GitChange.Unmodified), records[2].Status);
        Assert.Equal("sql queries/old name.sql", records[3].OriginalPath);
        Assert.Equal(GitChange.Renamed, records[3].Status.Staged);
        Assert.True(records[4].Status.IsConflicted);
        Assert.True(records[5].Status.IsUntracked);
    }

    [Fact]
    public void EveryUnmergedRecordIsAConflictIncludingAddAdd()
    {
        var record = Assert.Single(GitStatusParser.Parse(Bytes("u AA N... 000000 100644 100644 100644 0000 6178 7898 q/c.sql\0")));
        Assert.True(record.Status.IsConflicted);
        Assert.Equal(GitBadge.Conflicted, record.Status.Badge);
        Assert.False(record.Status.CanDiscardChanges);
    }

    [Fact]
    public void AnEmptyStatusIsNoRecords() => Assert.Empty(GitStatusParser.Parse([]));

    [Fact]
    public void AFollowedLogReportsEachCommitWithThePathTheFileHadThen()
    {
        var output = Bytes(
            "\u001e4e3138764045879d706b709d7f4dd42897109548\u001fAnn Author\u001f2026-09-23T10:09:04+07:00"
            + "\u001fsubject with \u001f? no; tab\there\0\nM\0sub dir/new name.sql\0"
            + "\u001e1189ca3714ed5cee0a4b5885a64adb10d8bcb830\u001fAnn Author\u001f2026-09-23T10:09:04+07:00"
            + "\u001frename it\0\nR100\0sub dir/old name.sql\0sub dir/new name.sql\0"
            + "\u001e9362855bae5a38735f19ddcfc763bba0cf5a2df2\u001fAnn Author\u001f2026-09-23T10:09:03+07:00\u001fsecond\0\nM\0sub dir/old name.sql\0"
            + "\u001ed5fc769941d0c335980f7be7b6df3a2bcefdd9fd\u001fAnn Author\u001f2026-09-23T10:09:03+07:00\u001ffirst: add\0\nA\0sub dir/old name.sql\0");

        var commits = GitLogParser.Parse(output);

        Assert.Equal(["4e31", "1189", "9362", "d5fc"], commits.Select(c => c.Hash[..4]));
        Assert.Equal(["sub dir/new name.sql", "sub dir/new name.sql", "sub dir/old name.sql", "sub dir/old name.sql"], commits.Select(c => c.Path));
        Assert.Equal("subject with \u001f? no; tab\there", commits[0].Subject);
        Assert.Equal("first: add", commits[3].Subject);
        Assert.Equal("Ann Author", commits[0].Author);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_790_132_944), commits[0].Date);
    }

    [Fact]
    public void ACommitWithNoFileEntryKeepsItsHeaderAndLeavesThePathUnknown()
    {
        var commit = Assert.Single(GitLogParser.Parse(Bytes("\u001eabcd" + new string('0', 36) + "\u001fAnn\u001f2026-09-23T10:09:04+07:00\u001fmerge\0")));
        Assert.Null(commit.Path);
    }

    [Fact]
    public void ACommitThatDeletedTheFileIsSkipped()
    {
        var deleted = new string('b', 40);
        var added = new string('c', 40);
        var output = Bytes(
            $"\u001e{deleted}\u001fAnn\u001f2026-09-23T10:09:04+07:00\u001fdrop it\0\nD\0q.sql\0"
            + $"\u001e{added}\u001fAnn\u001f2026-09-22T10:09:04+07:00\u001fadd it\0\nA\0q.sql\0");
        Assert.Equal([added], GitLogParser.Parse(output).Select(c => c.Hash));
    }

    [Fact]
    public void AHeaderWhoseHashIsNotACommitIdIsDropped()
    {
        Assert.Empty(GitLogParser.Parse(Bytes("\u001e--batch-check\u001fAnn\u001f2026-09-23T10:09:04+07:00\u001fx\0\nM\0q.sql\0")));
        Assert.True(GitLogParser.IsCommitHash(new string('a', 64)));
        Assert.False(GitLogParser.IsCommitHash("HEAD"));
    }

    [Fact]
    public void RevParseOutputMapsToWindowsPathsAndAPrefixThatIsEmptyAtTheRoot()
    {
        var nested = GitRepositoryInfoParser.Parse(Bytes("C:/repo\nC:/repo/.git\nsql queries/\n"));
        Assert.NotNull(nested);
        Assert.Equal(@"C:\repo", nested.TopLevel);
        Assert.Equal(@"C:\repo\.git", nested.GitDirectory);
        Assert.Equal("sql queries/", nested.Prefix);

        var root = GitRepositoryInfoParser.Parse(Bytes("C:/repo\nC:/repo/.git\n\n"));
        Assert.Equal(string.Empty, root!.Prefix);
        Assert.Null(GitRepositoryInfoParser.Parse([]));
    }

    [Fact]
    public void AFileWithNoStatusIsCleanOnlyWhenTheIndexTracksIt()
    {
        var snapshot = new LinkedFolderGitSnapshot(
            new GitRepositoryInfo(@"C:\r", @"C:\r\.git", string.Empty),
            null,
            new Dictionary<string, GitFileStatus> { ["new.sql"] = GitFileStatus.Untracked },
            new HashSet<string> { "clean.sql" });

        Assert.Equal(LinkedFileGitState.Clean, snapshot.StateOf("clean.sql"));
        Assert.Equal(new LinkedFileGitState(GitFileStatus.Untracked), snapshot.StateOf("new.sql"));
        Assert.Null(snapshot.StateOf("ignored.sql"));
        Assert.Equal(["a.sql"], LinkedFolderGitStatus.FolderRelativePaths(["q/a.sql", "other/b.sql"], "q/"));
    }

    [Fact]
    public void StatusesAreKeyedByThePathInsideTheFolder()
    {
        GitStatusRecord[] records =
        [
            new("sql queries/a.sql", null, GitFileStatus.Untracked),
            new("sql queries/nested/b.sql", null, new GitFileStatus(GitChange.Unmodified, GitChange.Modified)),
            new("other/c.sql", null, GitFileStatus.Untracked),
        ];

        var statuses = LinkedFolderGitStatus.FolderRelativeStatuses(records, "sql queries/");

        Assert.Equal(["a.sql", "nested/b.sql"], statuses.Keys.Order(StringComparer.Ordinal));
    }

    [Fact]
    public void BadgesFollowTheStagedThenTheUnstagedSide()
    {
        Assert.Equal(GitBadge.Untracked, GitFileStatus.Untracked.Badge);
        Assert.Equal(GitBadge.Added, new GitFileStatus(GitChange.Added, GitChange.Modified).Badge);
        Assert.Equal(GitBadge.Renamed, new GitFileStatus(GitChange.Renamed, GitChange.Unmodified).Badge);
        Assert.Equal(GitBadge.Added, new GitFileStatus(GitChange.Unmodified, GitChange.Added).Badge);
        Assert.Equal(GitBadge.Modified, new GitFileStatus(GitChange.Unmodified, GitChange.Modified).Badge);
        Assert.False(new GitFileStatus(GitChange.Unmodified, GitChange.Added).HasCommittedHistory);
        Assert.Equal("Modified, partly staged", new GitFileStatus(GitChange.Modified, GitChange.Modified).AccessibleDescription);
    }

    [Fact]
    public void ReadsRunWithoutHooksOrLocksAndWritesWithTheUsersHooks()
    {
        var read = GitCommand.Status(@"C:\r");
        Assert.Contains("core.hooksPath=/dev/null", read.ProcessArguments);
        Assert.Contains("--no-optional-locks", read.ProcessArguments);
        Assert.Contains("--literal-pathspecs", read.ProcessArguments);

        var commit = GitCommand.Commit(["a.sql"], "--amend", @"C:\r");
        Assert.DoesNotContain("core.hooksPath=/dev/null", commit.ProcessArguments);
        Assert.Contains("--message=--amend", commit.ProcessArguments);
        Assert.Equal(GitCommand.WriteTimeout, commit.Timeout);
    }

    [Fact]
    public void TheChildEnvironmentDropsRepositoryOverridesAndCannotPrompt()
    {
        var environment = GitCommand.Environment(new Dictionary<string, string>
        {
            ["GIT_DIR"] = @"C:\elsewhere\.git",
            ["git_index_file"] = "x",
            ["PATH"] = @"C:\Windows",
            ["GIT_TERMINAL_PROMPT"] = "1",
        });

        Assert.False(environment.ContainsKey("GIT_DIR"));
        Assert.False(environment.ContainsKey("GIT_INDEX_FILE"));
        Assert.Equal(@"C:\Windows", environment["PATH"]);
        Assert.Equal("0", environment["GIT_TERMINAL_PROMPT"]);
    }

    [Fact]
    public void TheLocatorSkipsRelativePathEntriesAndFallsBackToTheInstallerFolders()
    {
        var env = new Dictionary<string, string?>
        {
            ["PATH"] = @".;tools;C:\Tools\bin",
            ["ProgramFiles"] = @"C:\Program Files",
            ["LOCALAPPDATA"] = @"C:\Users\a\AppData\Local",
        };
        var locator = new GitExecutableLocator(p => p == @"C:\Program Files\Git\cmd\git.exe", k => env.GetValueOrDefault(k));

        Assert.Equal(@"C:\Tools\bin\git.exe", locator.Candidates()[0]);
        Assert.DoesNotContain(locator.Candidates(), c => c.StartsWith("tools", StringComparison.OrdinalIgnoreCase) || c.StartsWith('.'));
        Assert.Equal(@"C:\Program Files\Git\cmd\git.exe", locator.Locate());
    }
}
