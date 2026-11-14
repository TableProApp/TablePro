using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableTabReferenceTests
{
    private static readonly TableName Artist = new(null, "Artist");

    private static readonly TableFilter ToArtist = new(
        FilterCombinator.And, [new FilterRule("ArtistId", FilterOperator.Equal, new FilterValue.One("1"))], null);

    private static readonly RowReferenceChoice Referenced = new("fk_artist", Artist, ["name"], ToArtist, null, null);

    private static readonly RowReferenceChoice Referencing =
        new("fk_album", new TableName(null, "Album"), ["ArtistId"], ToArtist, null, null);

    private readonly FakeSession _session = new() { TableRows = 3, References = new([Referenced], [Referencing]) };
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
        Assert.True(_tab.ReferencesAt(0, 1).IsEmpty);

        await _tab.RunAsync();
        var references = _tab.ReferencesAt(0, 1);
        await _tab.RunAsync();

        Assert.Same(Referenced, Assert.Single(references.Referenced));
        Assert.Same(Referencing, Assert.Single(references.Referencing));
        var first = Assert.Single(_session.KeyReads);
        Assert.Equal((0L, "name"), Assert.Single(first.Asked));

        await _tab.RefreshAsync();
        Assert.Equal(2, _session.KeyReads.Count);
        Assert.True(first.IsDisposed);

        await _tab.CloseAsync();
        Assert.True(_session.KeyReads[1].IsDisposed);
        Assert.True(_tab.ReferencesAt(0, 1).IsEmpty);
    }

    [Fact]
    public async Task APendingChangeInAKeysColumnHidesThatKeyButNotTheRowsPointingAtTheRow()
    {
        await _tab.RunAsync();

        Assert.Null(_tab.CommitEdit(0, 1, "renamed"));
        var changed = _tab.ReferencesAt(0, 1);
        Assert.Null(_tab.AddRow(out var added));
        Assert.Null(_tab.DeleteRows([2]));

        Assert.Empty(changed.Referenced);
        Assert.Single(changed.Referencing);
        Assert.False(_tab.ReferencesAt(1, 1).IsEmpty);
        Assert.True(_tab.ReferencesAt(added, 1).IsEmpty);
        Assert.True(_tab.ReferencesAt(2, 1).IsEmpty);
        Assert.True(_tab.ReferencesAt(0, 5).IsEmpty);
    }

    [Fact]
    public async Task ARefreshWhoseKeyReadFailsOffersNoneOfTheKeysReadBefore()
    {
        await _tab.RunAsync();
        Assert.False(_tab.ReferencesAt(0, 1).IsEmpty);

        _session.KeysFailure = Errors.Of("driver.connection_lost");
        await _tab.RefreshAsync();

        Assert.True(Assert.Single(_session.KeyReads).IsDisposed);
        Assert.True(_tab.ReferencesAt(0, 1).IsEmpty);
    }

    [Fact]
    public async Task AKeyReadThatFailsLeavesTheRowsWithoutReferences()
    {
        _session.KeysFailure = Errors.Of("driver.unsupported");

        await _tab.RunAsync();

        Assert.Equal(3, _results.RowCount);
        Assert.True(_tab.ReferencesAt(0, 1).IsEmpty);
        Assert.DoesNotContain("error driver.unsupported", _results.Shown);
    }

    [Fact]
    public void AReferenceOpensAsATableTabOnItsFilterWhichATabReadWithTheSameFilterShows()
    {
        var spec = TableTab.TabFor(Referenced)!;
        var refused = Referenced with { Filter = null, Refusal = ReferenceRefusal.ComparedOtherwise, RefusalSubject = "Artist" };
        var shown = new TableTab(_session, _view, _results, Artist, ObjectKind.Table, () => new AppSettings(), spec);
        var other = new TableTab(
            _session,
            _view,
            _results,
            Artist,
            ObjectKind.Table,
            () => new AppSettings(),
            TableTab.TabFor(Referenced with
            {
                Filter = ToArtist with { Rules = [new FilterRule("ArtistId", FilterOperator.Equal, new FilterValue.One("2"))] },
            }));

        Assert.Equal((TabKind.Table, "Artist", (string?)null, "Artist"), (spec.Kind, spec.Table, spec.Schema, spec.Title));
        Assert.True(TableFilters.Same(ToArtist, spec.Filter!.ToFilter()));
        Assert.True(shown.ShowsReference(Referenced));
        Assert.False(other.ShowsReference(Referenced));
        Assert.False(shown.ShowsReference(refused));
        Assert.Null(TableTab.TabFor(refused));
        Assert.False(_tab.ShowsReference(Referenced));
    }

    [Fact]
    public async Task ATabReadingAnotherFilterDoesNotShowAReferenceUntilItsRowsAreRead()
    {
        var view = new FakeTableView();
        var results = new FakeResults();
        var target = new TableTab(
            _session, view, results, Artist, ObjectKind.Table, () => new AppSettings(), TableTab.TabFor(Referenced));
        view.Tab = target;
        await target.RunAsync();
        var second = Referenced with
        {
            Filter = ToArtist with { Rules = [new FilterRule("ArtistId", FilterOperator.Equal, new FilterValue.One("2"))] },
        };
        var querying = new Gate();
        _session.Querying = querying;
        _session.RefusesFilter = true;

        var applying = target.ApplyFilterAsync(second.Filter);
        await querying.Reached;
        var whileReading = (target.ShowsReference(second), target.ShowsReference(Referenced));
        querying.Open();
        await applying;

        Assert.Equal((false, false), whileReading);
        Assert.False(target.ShowsReference(second));
        Assert.True(target.ShowsReference(Referenced));
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
}
