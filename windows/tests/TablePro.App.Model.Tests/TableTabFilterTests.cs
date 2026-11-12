using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableTabFilterTests
{
    private static readonly TableFilter ByName = new(
        FilterCombinator.And,
        [new FilterRule("Name", FilterOperator.Contains, new FilterValue.One("AC"))],
        null);

    private readonly FakeSession _session = new() { TableRows = 3_503, FilteredRows = 1_200 };
    private readonly FakeTableView _view = new();
    private readonly FakeResults _results = new();
    private readonly TableTab _tab;

    public TableTabFilterTests()
    {
        _tab = New();
    }

    [Fact]
    public async Task AFilterReadsFromTheFirstPageAndCountsTheRowsItPicks()
    {
        await _tab.RunAsync();
        await _tab.NextPageAsync();

        await _tab.ApplyFilterAsync(ByName);

        Assert.Same(ByName, _tab.Filter);
        Assert.Equal(0, _tab.Page.Offset);
        Assert.Equal(0, _session.Queries[^1].Offset);
        Assert.Same(ByName, _session.PageFilters[^1]);
        Assert.Equal<TableFilter?>([null, ByName], _session.CountFilters);
        Assert.Equal(1_200, _tab.Page.Total);

        await _tab.ApplyFilterAsync(null);

        Assert.Null(_tab.Filter);
        Assert.Null(_session.PageFilters[^1]);
        Assert.Equal(3_503, _tab.Page.Total);
    }

    [Fact]
    public async Task AFilterThatPicksLessThanAPageHasItsTotalWithNoCount()
    {
        _session.FilteredRows = 40;
        await _tab.RunAsync();

        await _tab.ApplyFilterAsync(ByName);

        Assert.Equal(40, _tab.Page.Total);
        Assert.Equal<TableFilter?>([null], _session.CountFilters);
        Assert.False(_tab.Page.IsPaged);
    }

    [Fact]
    public async Task AFilterWithNoRuleAndNoSqlReadsTheWholeTable()
    {
        await _tab.ApplyFilterAsync(new TableFilter(FilterCombinator.Or, [], "  "));

        Assert.Null(_tab.Filter);
        Assert.Null(Assert.Single(_session.PageFilters));
        Assert.Null(_tab.Snapshot().Filter);
    }

    [Fact]
    public async Task AFilterAsksBeforeDiscardingPendingEditsAndANoKeepsThemAndTheFilterShown()
    {
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");
        _view.DiscardsForReload = false;

        await _tab.ApplyFilterAsync(ByName);

        Assert.Equal<ReloadReason>([ReloadReason.Filter], _view.ReloadsAsked);
        Assert.Null(_tab.Filter);
        Assert.Single(_session.Queries);
        Assert.True(_tab.HasUnsavedChanges);

        _view.DiscardsForReload = true;
        await _tab.ApplyFilterAsync(ByName);

        Assert.Same(ByName, _tab.Filter);
        Assert.Equal(2, _session.Queries.Count);
        Assert.False(_tab.HasUnsavedChanges);
    }

    [Fact]
    public async Task AFilterTheCoreRefusesKeepsTheOneShownAndSaysWhy()
    {
        await _tab.ApplyFilterAsync(ByName);
        _session.RefusesFilter = true;
        var gone = new TableFilter(
            FilterCombinator.And,
            [new FilterRule("Gone", FilterOperator.Equal, new FilterValue.One("1"))],
            null);

        await _tab.ApplyFilterAsync(gone);

        Assert.Same(ByName, _tab.Filter);
        Assert.Equal("error filter.unknown_column", _results.Shown[^1]);
        Assert.Equal(1_200, _tab.Page.Total);
        Assert.False(_tab.IsRunning);
        Assert.NotNull(_tab.Edits);
        Assert.Equal(FilterText.Of(ByName), FilterText.Of(_tab.Snapshot().Filter?.ToFilter()));
    }

    public static TheoryData<string> EndingsWithNoPage => ["failed", "cancelled", "timed out"];

    [Theory]
    [MemberData(nameof(EndingsWithNoPage))]
    public async Task AFilteredReadThatBringsNoPageLeavesTheFilterAndThePageAsTheyWere(string ending)
    {
        await _tab.ApplyFilterAsync(ByName);
        var shown = _tab.Page;
        _session.FilteredReadEnds = ending switch
        {
            "failed" => new QueryOutcome.Failed(Errors.Of("operation.sql")),
            "cancelled" => new QueryOutcome.Cancelled(),
            _ => new QueryOutcome.TimedOut(ServerCancelled: true),
        };
        var raw = new TableFilter(FilterCombinator.And, [], "no_such_function(Name)");

        await _tab.ApplyFilterAsync(raw);

        Assert.Same(ByName, _tab.Filter);
        Assert.Equal(FilterText.Of(ByName), FilterText.Of(_tab.Snapshot().Filter?.ToFilter()));
        Assert.Equal(shown.Offset, _tab.Page.Offset);
        Assert.Equal(1_200, _tab.Page.Total);
        Assert.False(_tab.IsRunning);

        _session.FilteredReadEnds = null;
        await _tab.RefreshAsync();

        Assert.Equal(FilterText.Of(ByName), FilterText.Of(_session.PageFilters[^1]));
    }

    [Fact]
    public async Task ARestoredFilterIsReadWithAndStaysWhenTheFirstReadRefusesIt()
    {
        var restore = new SessionTab
        {
            Kind = TabKind.Table,
            Title = "Artist",
            Table = "Artist",
            Filter = SavedFilter.From(ByName),
        };
        _session.RefusesFilter = true;
        var tab = New(restore);

        await tab.RunAsync();

        Assert.Equal(FilterText.Of(ByName), FilterText.Of(_session.PageFilters[^1]));
        Assert.Equal(FilterText.Of(ByName), FilterText.Of(tab.Filter));
        Assert.Equal("error filter.unknown_column", _results.Shown[^1]);
    }

    [Fact]
    public async Task AFilterAndTheObjectKindComeBackFromTheSessionFile()
    {
        var filter = new TableFilter(
            FilterCombinator.Or,
            [
                new FilterRule("ArtistId", FilterOperator.Between, new FilterValue.Pair("1", "9")),
                new FilterRule("Name", FilterOperator.In, new FilterValue.List(["AC/DC", "Accept"])),
                new FilterRule("Name", FilterOperator.IsNotNull, null),
            ],
            "length(Name) > 3");
        var saving = New(kind: ObjectKind.View);
        await saving.ApplyFilterAsync(filter);
        var directory = Directory.CreateTempSubdirectory("tablepro-filter-").FullName;
        try
        {
            var store = new SessionStore(Path.Combine(directory, "session.json"));
            var connection = new SessionConnection
            {
                FilePath = @"C:\chinook.db",
                Name = "chinook",
                Tabs = [saving.Snapshot()],
            };
            store.Save(new SessionState { Connections = [connection] });
            var saved = Assert.Single(Assert.Single(store.Load().Connections).Tabs);

            var restored = New(saved, saved.ObjectKindOr(ObjectKind.Table));
            await restored.RunAsync();
            await restored.LoadStructureAsync(refresh: false);

            Assert.Equal(ObjectKind.View, restored.ObjectKind);
            Assert.Equal(FilterText.Of(filter), FilterText.Of(restored.Filter));
            Assert.Same(restored.Filter, _session.PageFilters[^1]);
            Assert.Equal(ObjectKind.View, _session.StructureReads[^1]);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void ATabSavedWithNoKindOrAKindThisBuildDoesNotNameOpensAsTheFallback()
    {
        static ObjectKind Read(string? name) => new SessionTab { ObjectKind = name }.ObjectKindOr(ObjectKind.Table);

        Assert.Equal(ObjectKind.Table, Read(null));
        Assert.Equal(ObjectKind.Table, Read("Hypertable"));
        Assert.Equal(ObjectKind.Table, Read("2"));
        Assert.Equal(ObjectKind.MaterializedView, Read("MaterializedView"));
    }

    [Fact]
    public void ARuleThisBuildCannotReadBackIsLeftOutOfARestoredFilter()
    {
        var saved = new SavedFilter
        {
            Combinator = "Xor",
            Rules =
            [
                new SavedFilterRule { Column = "Name", Operator = "Regex", Values = ["^A"] },
                new SavedFilterRule { Column = "Name", Operator = "1", Values = ["x"] },
                new SavedFilterRule { Column = "ArtistId", Operator = "Between", Values = ["1"] },
                new SavedFilterRule { Column = "", Operator = "Equal", Values = ["7"] },
                new SavedFilterRule { Column = "ArtistId", Operator = "Equal", Values = ["7"] },
            ],
        };

        Assert.Equal("And: ArtistId Equal 7 | ", FilterText.Of(saved.ToFilter()));
        Assert.Null((saved with { Rules = [saved.Rules[0]] }).ToFilter());
    }

    [Fact]
    public async Task TheStructureIsReadOnceAndAgainAfterARefresh()
    {
        await _tab.RunAsync();

        var first = await _tab.LoadStructureAsync(refresh: false);
        var kept = await _tab.LoadStructureAsync(refresh: false);

        Assert.NotNull(first);
        Assert.Same(first, kept);
        Assert.Same(first, _tab.Structure);
        Assert.Equal<ObjectKind>([ObjectKind.Table], _session.StructureReads);

        await _tab.RefreshAsync();
        var afterRefresh = await _tab.LoadStructureAsync(refresh: false);
        var asked = await _tab.LoadStructureAsync(refresh: true);

        Assert.NotSame(first, afterRefresh);
        Assert.NotSame(afterRefresh, asked);
        Assert.Same(asked, _tab.Structure);
        Assert.Equal(3, _session.StructureReads.Count);
    }

    [Fact]
    public async Task AStructureThatCannotBeReadSaysWhyAndIsReadAgainWhenAskedNext()
    {
        _session.StructureFailure = Errors.Of("ffi.not_connected");

        Assert.Null(await _tab.LoadStructureAsync(refresh: false));
        Assert.Equal("ffi.not_connected", Assert.Single(_view.StructureFailures).Code);
        Assert.Null(_tab.Structure);

        _session.StructureFailure = null;

        Assert.NotNull(await _tab.LoadStructureAsync(refresh: false));
        Assert.Equal(2, _session.StructureReads.Count);
    }

    [Fact]
    public async Task AStructureReadNeitherWaitsForThePageNorStopsItAndIsReadOnceForEveryAsk()
    {
        var reading = new Gate();
        _session.ReadingStructure = reading;
        var structure = _tab.LoadStructureAsync(refresh: false);
        var again = _tab.LoadStructureAsync(refresh: false);
        await reading.Reached;

        await _tab.RunAsync();

        Assert.Equal(1_000, _tab.Page.Rows);
        Assert.Equal(0, Assert.Single(_session.Pages).Cancels);
        Assert.False(structure.IsCompleted);

        reading.Open();

        Assert.NotNull(await structure);
        Assert.Same(await structure, await again);
        Assert.Single(_session.StructureReads);
    }

    [Fact]
    public async Task ClosingDuringAStructureReadStopsItAndLetsTheSessionGoOnce()
    {
        var reading = new Gate();
        _session.ReadingStructure = reading;
        var structure = _tab.LoadStructureAsync(refresh: false);
        await reading.Reached;

        await _tab.CloseAsync();

        Assert.Null(await structure);
        Assert.Null(_tab.Structure);
        Assert.Empty(_view.StructureFailures);
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task ACloseWaitsForAStructureReadThatDoesNotStopAndKeepsNothingOfIt()
    {
        var reading = new Gate(honorsCancel: false);
        _session.ReadingStructure = reading;
        var structure = _tab.LoadStructureAsync(refresh: false);
        await reading.Reached;

        var closing = _tab.CloseAsync();
        var waited = !closing.IsCompleted;
        reading.Open();
        await closing;

        Assert.True(waited);
        Assert.Null(await structure);
        Assert.Null(_tab.Structure);
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task FilterChoicesAreReadOnceAndAgainAfterARefresh()
    {
        await _tab.RunAsync();

        var choices = await _tab.LoadFilterChoicesAsync();
        await _tab.LoadFilterChoicesAsync();

        Assert.Same(_session.Choices, choices);
        Assert.Same(choices, _tab.FilterChoices);
        Assert.Equal(1, _session.ChoicesReads);

        await _tab.RefreshAsync();
        await _tab.LoadFilterChoicesAsync();

        Assert.Equal(2, _session.ChoicesReads);
    }

    [Fact]
    public async Task FilterChoicesThatCannotBeReadSayWhy()
    {
        _session.ChoicesFailure = Errors.Of("catalog.columns_unavailable");

        Assert.Null(await _tab.LoadFilterChoicesAsync());
        Assert.Equal("catalog.columns_unavailable", Assert.Single(_view.ChoicesFailures).Code);
    }

    private TableTab New(SessionTab? restore = null, ObjectKind kind = ObjectKind.Table)
    {
        var tab = new TableTab(
            _session,
            _view,
            _results,
            new TableName(null, "Artist"),
            kind,
            () => new AppSettings(),
            restore);
        _view.Tab = tab;
        return tab;
    }
}

// A filter as one line, since its records hold their lists by reference.
internal static class FilterText
{
    public static string Of(TableFilter? filter)
    {
        if (filter is null)
        {
            return "none";
        }

        var rules = filter.Rules.Select(rule => $"{rule.Column} {rule.Operator} {Value(rule.Value)}");
        return $"{filter.Combinator}: {string.Join("; ", rules)} | {filter.RawSql}";
    }

    private static string Value(FilterValue? value) => value switch
    {
        FilterValue.One single => single.Value,
        FilterValue.Pair pair => $"{pair.Low}..{pair.High}",
        FilterValue.List list => $"[{string.Join(", ", list.Values)}]",
        _ => "-",
    };
}
