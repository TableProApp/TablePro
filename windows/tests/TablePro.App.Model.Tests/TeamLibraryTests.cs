using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TeamLibraryTests
{
    private const string Team = "team_01h455vb4pex5vsknk084sn02q";

    private readonly FakeTeamCalls _calls = new();
    private string? _session = "session-1";

    private static readonly DateTimeOffset Monday = new(2026, 11, 23, 9, 0, 0, TimeSpan.Zero);

    private TeamLibraryModel Library() => new(() => Task.FromResult<ITeamCalls>(_calls), () => _session);

    private static TeamLibraryTeam Data(bool canWrite = true) => new(
        Team,
        "Data",
        canWrite ? TeamRole.Editor : TeamRole.Member,
        canWrite,
        [
            new TeamItem(
                TeamItemKind.Query,
                "Q-2",
                """{"name":"Orders by day","query":"SELECT 1","folder_client_id":"F-1","sort_order":2}""",
                "Ana",
                Monday),
            new TeamItem(TeamItemKind.Query, "Q-1", """{"name":"Top users","query":"SELECT 2","sort_order":1}""", null, null),
            new TeamItem(TeamItemKind.Folder, "F-1", """{"name":"Reports","sort_order":0}""", "Ben", Monday),
            new TeamItem(TeamItemKind.Connection, "C-1", """{"name":"Prod"}""", null, null),
            new TeamItem(TeamItemKind.Query, "Q-9", "not json", null, null),
        ]);

    [Fact]
    public async Task TheTeamsQueriesAndFoldersAreReadInOrderWithWhoLastChangedThem()
    {
        _calls.Teams = [Data()];
        var library = Library();

        await library.RefreshAsync();

        var team = Assert.Single(library.Teams);
        Assert.Equal(["Top users", "Orders by day"], team.Queries.Select(query => query.Name));
        Assert.Equal("F-1", team.Queries[1].FolderId);
        Assert.Equal("Ana", team.Queries[1].UpdatedBy);
        Assert.Equal("Reports", Assert.Single(team.Folders).Name);
        Assert.Equal(1, team.Connections);
        Assert.Equal("Ben", library.Writer(new SyncRecord(Team, "library_folder", "f-1")));
    }

    [Fact]
    public async Task APublishGoesOutOnlyUnderTheSignInTheTeamWasPickedUnder()
    {
        _calls.Teams = [Data()];
        var library = Library();
        await library.RefreshAsync();
        var picked = library.Destination(Team);

        _session = "session-2";
        var outcome = await library.PublishSavedQueriesAsync(picked, [], []);

        Assert.Same(TeamPublishOutcome.SignedOut.Instance, outcome);
        Assert.DoesNotContain(_calls.Calls, call => call.StartsWith("publish", StringComparison.Ordinal));
    }

    [Fact]
    public async Task APublishToATeamThisAccountReadsOnlyIsRefusedBeforeItGoes()
    {
        _calls.Teams = [Data(canWrite: false)];
        var library = Library();
        await library.RefreshAsync();

        var outcome = await library.PublishSavedQueriesAsync(library.Destination(Team), [], []);

        Assert.Same(TeamPublishOutcome.NotWritable.Instance, outcome);
    }

    [Fact]
    public async Task EveryPublishOutcomeIsTheEnginesAnswer()
    {
        _calls.Teams = [Data()];
        var library = Library();
        await library.RefreshAsync();
        var folders = new[] { new TeamFolderEdit("F-1", "Reports", null, 0) };
        var queries = new[] { new TeamQueryEdit("Q-1", "Top users", "SELECT 2", null, "F-1", null, 1) };

        var published = await library.PublishSavedQueriesAsync(library.Destination(Team), folders, queries);

        Assert.Equal(new TeamPublishOutcome.Published(2), published);
        Assert.Contains($"publish {Team} 1 folders 1 queries", _calls.Calls);
        Assert.Same(TeamPublishOutcome.Unchanged.Instance, TeamLibraryModel.Outcome(new TeamPublish(0, 0, 0, null)));
        Assert.Equal(new TeamPublishOutcome.Conflicts(1), TeamLibraryModel.Outcome(new TeamPublish(1, 1, 0, null)));
        Assert.Equal(
            new TeamPublishOutcome.Queued("sync.network"),
            TeamLibraryModel.Outcome(new TeamPublish(0, 0, 1, "sync.network")));
        Assert.Equal(
            new TeamPublishOutcome.Failed("sync.validation_failed"),
            TeamLibraryModel.Outcome(new TeamPublish(0, 0, 1, "sync.validation_failed")));
    }

    [Fact]
    public void EverySavedQueryAndFolderGoesUpWithUpperCaseIds()
    {
        var folder = Guid.NewGuid();
        var connection = Guid.NewGuid();
        var contents = new SavedQueryContents(
            [new StoredSavedQuery(Guid.Empty, "Top", "SELECT 1", string.Empty, connection, folder, 3)],
            [new StoredSavedQueryFolder(folder, "Reports", connection, null, 0)]);

        var (folders, queries) = TeamItems.Edits(contents);

        var query = Assert.Single(queries);
        Assert.Equal(folder.ToString().ToUpperInvariant(), query.FolderId);
        Assert.Equal(connection.ToString().ToUpperInvariant(), query.ConnectionId);
        Assert.Null(query.Keyword);
        Assert.Null(Assert.Single(folders).ParentId);
    }

    [Fact]
    public async Task AConflictAPullReplacedIsShownAgainWithWhy()
    {
        var record = new SyncRecord(Team, "library_query", "Q-1");
        var conflict = new TeamConflict(record, ["name"], "\"Mine\"", "\"Theirs\"", "ab");
        _calls.Conflicts.Add(conflict);
        _calls.Fails["resolve"] = SyncErrors.Of("sync.changed");
        var library = Library();
        await library.RefreshAsync();

        await library.ResolveAsync(conflict, ConflictChoice.KeepMine);
        var failure = library.ConflictFailure;
        await library.ResolveAsync(conflict, ConflictChoice.KeepTheirs);

        Assert.Equal("sync.changed", failure?.Error.Code);
        Assert.Empty(library.Conflicts);
        Assert.Null(library.ConflictFailure);
        Assert.Contains("resolve Q-1 KeepTheirs", _calls.Calls);
    }

    [Fact]
    public async Task SignOutAsksAboutUnsentEditsUploadsAndAsksAgainWhenTheyStay()
    {
        _calls.Unsent.Add(new UnsentTeamEdit(Team, new TeamItemRef(TeamItemKind.Query, "Q-1"), "Top users", false,
            UnsentTeamEditState.Pending, null));
        _calls.UploadSends = false;
        var asked = new List<(IReadOnlyList<string> Names, string? Failure)>();
        var answers = new Queue<TeamSignOutAnswer>([TeamSignOutAnswer.Upload, TeamSignOutAnswer.Discard]);

        var proceed = await TeamSignOut.SettleUnsentAsync(_calls, (names, failure) =>
        {
            asked.Add((names, failure));
            return Task.FromResult(answers.Dequeue());
        });

        Assert.True(proceed);
        Assert.Equal(["Top users"], asked[0].Names);
        Assert.Null(asked[0].Failure);
        Assert.NotNull(asked[1].Failure);
        Assert.Equal(["unsent", "sync now", "unsent", "discard all"], _calls.Calls);
    }

    [Fact]
    public async Task SignOutWithNothingUnsentAsksNothingAndCancelKeepsTheSignIn()
    {
        var nothing = await TeamSignOut.SettleUnsentAsync(_calls, (_, _) => Task.FromResult(TeamSignOutAnswer.Cancel));
        _calls.Unsent.Add(new UnsentTeamEdit(Team, new TeamItemRef(TeamItemKind.Folder, "F-1"), null, true,
            UnsentTeamEditState.Refused, "sync.validation_failed"));
        var kept = await TeamSignOut.SettleUnsentAsync(_calls, (_, _) => Task.FromResult(TeamSignOutAnswer.Cancel));
        _calls.Fails["delete"] = SyncErrors.Of("sync.team_library.delete_failed");
        var deleted = await TeamSignOut.DeleteDataAsync(_calls);

        Assert.True(nothing);
        Assert.False(kept);
        Assert.Equal("sync.team_library.delete_failed", deleted?.Code);
        Assert.Equal("F-1", TeamLibraryModel.Name(_calls.Unsent[0]));
    }

    [Fact]
    public void AConflictSaysWhichSideDeletedAndShowsEachFieldsValue()
    {
        var record = new SyncRecord(Team, "library_query", "Q-1");
        var both = new TeamConflict(record, ["query"], """{"name":"Top","query":"SELECT 1","sort_order":2}""",
            """{"name":"Top","query":"SELECT 2"}""", "ab");
        var deleted = both with { Theirs = null };
        var gone = both with { Mine = null };

        Assert.Equal(TeamConflictCase.BothChanged, TeamConflicts.Case(both));
        Assert.Equal(TeamConflictCase.DeletedFromTeam, TeamConflicts.Case(deleted));
        Assert.Equal(TeamConflictCase.ChangedAfterYouDeleted, TeamConflicts.Case(gone));
        Assert.Equal("Top", TeamConflicts.Name(gone));
        Assert.Equal("SELECT 1", TeamConflicts.Value(both.Mine, "query"));
        Assert.Equal("2", TeamConflicts.Value(both.Mine, "sort_order"));
        Assert.Null(TeamConflicts.Value(both.Theirs, "sort_order"));
        Assert.Null(TeamConflicts.Value("not json", "query"));
    }
}
