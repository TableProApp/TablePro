using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableTabReferenceTests
{
    private static readonly TableName Artist = new(null, "Artist");

    private static readonly TableFilter ToArtist = new(
        FilterCombinator.And, [new FilterRule("ArtistId", FilterOperator.Equal, new FilterValue.One("1"))], null);

    private static readonly FollowedReference.Rows ArtistRows = new(Artist, ToArtist);

    private static readonly RowReferenceChoice Referenced = new(0, false, "fk_artist", Artist, ["name"]);

    private static readonly RowReferenceChoice Referencing = new(0, true, "fk_album", new TableName(null, "Album"), ["ArtistId"]);

    private readonly FakeSession _session = new()
    {
        TableRows = 3,
        References = new([Referenced], [Referencing]),
        Followed = ArtistRows,
    };

    private readonly FakeTableView _view = new();
    private readonly FakeResults _results = new();
    private readonly TableTab _tab;

    public TableTabReferenceTests()
    {
        _tab = new TableTab(_session, _view, _results, new TableName(null, "Album"), ObjectKind.Table, () => new AppSettings());
        _view.Tab = _tab;
    }

    [Fact]
    public async Task TheKeysAreReadOnceThePageShowsAndAgainAfterARefreshAndGoWithTheTab()
    {
        Assert.True(_tab.ReferencesAt(0, 1).References.IsEmpty);

        await _tab.RunAsync();
        var menu = _tab.ReferencesAt(0, 1);
        await _tab.RunAsync();

        Assert.Same(Referenced, Assert.Single(menu.References.Referenced));
        Assert.Same(Referencing, Assert.Single(menu.References.Referencing));
        var first = Assert.Single(_session.KeyReads);
        Assert.Equal((0L, "name"), Assert.Single(first.Asked));

        await _tab.RefreshAsync();
        Assert.Equal(2, _session.KeyReads.Count);
        Assert.True(first.IsDisposed);

        await _tab.CloseAsync();
        Assert.True(_session.KeyReads[1].IsDisposed);
        Assert.True(_tab.ReferencesAt(0, 1).References.IsEmpty);
    }

    [Fact]
    public async Task AChosenKeyIsFollowedFromTheRowItsMenuOpenedOnUntilThePageChanges()
    {
        await _tab.RunAsync();
        var menu = _tab.ReferencesAt(2, 1);

        var followed = _tab.Follow(menu, Referencing);
        await _tab.RefreshAsync();
        var stale = _tab.Follow(menu, Referencing);

        Assert.Same(ArtistRows, followed);
        Assert.Equal((2L, Referencing), Assert.Single(_session.KeyReads[0].Follows));
        Assert.Null(stale);
        Assert.Null(_tab.Follow(ReferenceMenu.None, Referencing));
    }

    [Fact]
    public async Task APendingChangeInAKeysColumnHidesThatKeyButNotTheRowsPointingAtTheRow()
    {
        await _tab.RunAsync();

        Assert.Null(_tab.CommitEdit(0, 1, "renamed"));
        var changed = _tab.ReferencesAt(0, 1).References;
        Assert.Null(_tab.AddRow(out var added));
        Assert.Null(_tab.DeleteRows([2]));

        Assert.Empty(changed.Referenced);
        Assert.Single(changed.Referencing);
        Assert.False(_tab.ReferencesAt(1, 1).References.IsEmpty);
        Assert.True(_tab.ReferencesAt(added, 1).References.IsEmpty);
        Assert.True(_tab.ReferencesAt(2, 1).References.IsEmpty);
        Assert.True(_tab.ReferencesAt(0, 5).References.IsEmpty);
    }

    [Fact]
    public async Task ARefreshWhoseKeyReadFailsOffersNoneOfTheKeysReadBefore()
    {
        await _tab.RunAsync();
        Assert.False(_tab.ReferencesAt(0, 1).References.IsEmpty);

        _session.KeysFailure = Errors.Of("driver.connection_lost");
        await _tab.RefreshAsync();

        Assert.True(Assert.Single(_session.KeyReads).IsDisposed);
        Assert.True(_tab.ReferencesAt(0, 1).References.IsEmpty);
    }

    [Fact]
    public async Task AKeyReadThatFailsLeavesTheRowsWithoutReferences()
    {
        _session.KeysFailure = Errors.Of("driver.unsupported");

        await _tab.RunAsync();

        Assert.Equal(3, _results.RowCount);
        Assert.True(_tab.ReferencesAt(0, 1).References.IsEmpty);
        Assert.DoesNotContain("error driver.unsupported", _results.Shown);
    }

    [Fact]
    public void AReferenceOpensAsATableTabOnItsFilterWhichATabReadWithTheSameFilterShows()
    {
        var spec = TableTab.TabFor(ArtistRows);
        var shown = new TableTab(_session, _view, _results, Artist, ObjectKind.Table, () => new AppSettings(), spec);
        var other = new TableTab(
            _session,
            _view,
            _results,
            Artist,
            ObjectKind.Table,
            () => new AppSettings(),
            TableTab.TabFor(ArtistRows with { Filter = SecondArtist }));

        Assert.Equal((TabKind.Table, "Artist", (string?)null, "Artist"), (spec.Kind, spec.Table, spec.Schema, spec.Title));
        Assert.True(TableFilters.Same(ToArtist, spec.Filter!.ToFilter()));
        Assert.True(shown.ShowsReference(ArtistRows));
        Assert.False(other.ShowsReference(ArtistRows));
        Assert.False(_tab.ShowsReference(ArtistRows));
    }

    [Fact]
    public async Task ATabReadingAnotherFilterDoesNotShowAReferenceUntilItsRowsAreRead()
    {
        var view = new FakeTableView();
        var results = new FakeResults();
        var target = new TableTab(
            _session, view, results, Artist, ObjectKind.Table, () => new AppSettings(), TableTab.TabFor(ArtistRows));
        view.Tab = target;
        await target.RunAsync();
        var second = ArtistRows with { Filter = SecondArtist };
        var querying = new Gate();
        _session.Querying = querying;
        _session.RefusesFilter = true;

        var applying = target.ApplyFilterAsync(second.Filter);
        await querying.Reached;
        var whileReading = (target.ShowsReference(second), target.ShowsReference(ArtistRows));
        querying.Open();
        await applying;

        Assert.Equal((false, false), whileReading);
        Assert.False(target.ShowsReference(second));
        Assert.True(target.ShowsReference(ArtistRows));
    }

    [Fact]
    public void FiltersCompareByTheirRulesNotTheListsHoldingThem()
    {
        var copy = new TableFilter(FilterCombinator.And, [.. ToArtist.Rules], null);
        var list = new TableFilter(FilterCombinator.And, [new FilterRule("id", FilterOperator.In, new FilterValue.List(["1", "2"]))], null);

        Assert.True(TableFilters.Same(ToArtist, copy));
        Assert.True(TableFilters.Same(list, list with { Rules = [new FilterRule("id", FilterOperator.In, new FilterValue.List(["1", "2"]))] }));
        Assert.False(TableFilters.Same(ToArtist, copy with { Combinator = FilterCombinator.Or }));
        Assert.False(TableFilters.Same(ToArtist, copy with { RawSql = "1 = 1" }));
        Assert.False(TableFilters.Same(ToArtist, null));
        Assert.True(TableFilters.Same(null, null));
    }

    private static TableFilter SecondArtist =>
        ToArtist with { Rules = [new FilterRule("ArtistId", FilterOperator.Equal, new FilterValue.One("2"))] };
}
