using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableTabServerPagingTests
{
    private static readonly TableFilter ByName = new(
        FilterCombinator.And,
        [new FilterRule("Name", FilterOperator.Contains, new FilterValue.One("AC"))],
        null);

    private readonly FakeSession _session = new() { TableRows = 3_503, FilteredRows = 3_503, PagesOnServer = true };
    private readonly FakeTableView _view = new();
    private readonly FakeResults _results = new();
    private readonly TableTab _tab;
    private AppSettings _settings = new();

    public TableTabServerPagingTests()
    {
        _tab = new TableTab(
            _session,
            _view,
            _results,
            new TableName(null, "Artist"),
            ObjectKind.Table,
            () => _settings);
        _view.Tab = _tab;
    }

    [Fact]
    public async Task NextResumesWhereThePageBeforeStopped()
    {
        await _tab.RunAsync();

        Assert.False(_tab.Page.CanSeek);
        Assert.True(_tab.Page.HasNext);
        Assert.True(_tab.Page.IsPaged);
        Assert.Null(_session.Resumes[0]);

        await _tab.NextPageAsync();
        await _tab.NextPageAsync();

        Assert.Equal<long>([0, 1_000, 2_000], _session.Queries.Select(query => query.Offset));
        Assert.Equal(1_000, Passed(1).Offset);
        Assert.Equal(2_000, Passed(2).Offset);
        Assert.Equal(2_000, _tab.Page.Offset);
        Assert.Equal(1_000, _tab.Page.Rows);
    }

    [Fact]
    public async Task PreviousResumesFromThePageBeforeAndReadsPageOneFromNone()
    {
        await PageToAsync(pages: 3);

        await _tab.PreviousPageAsync();

        Assert.Equal(1_000, _session.Queries[^1].Offset);
        Assert.Same(_session.Resumes[1], _session.Resumes[^1]);
        Assert.False(Passed(1).Disposed);

        await _tab.PreviousPageAsync();

        Assert.Equal(0, _session.Queries[^1].Offset);
        Assert.Null(_session.Resumes[^1]);
        Assert.False(_tab.Page.HasPrevious);
    }

    [Theory]
    [InlineData("sort", 0L)]
    [InlineData("filter", 0L)]
    [InlineData("refresh", 3_000L)]
    [InlineData("reload", 3_000L)]
    [InlineData("size", 3_000L)]
    public async Task AnyReadButAStepLetsGoOfTheResumesAndReadsWithNone(string change, long offset)
    {
        await PageToAsync(pages: 4);
        var handed = Handed();

        await (change switch
        {
            "sort" => _tab.SortAsync(new GridSort(1, SortDirection.Descending)),
            "filter" => _tab.ApplyFilterAsync(ByName),
            "refresh" => _tab.RefreshAsync(),
            "reload" => _tab.RunAsync(),
            _ => _tab.ResizeAsync(500),
        });

        Assert.Equal(3, handed.Count);
        Assert.All(handed, resume => Assert.True(resume.Disposed));
        Assert.Equal(offset, _session.Queries[^1].Offset);
        Assert.Null(_session.Resumes[^1]);
    }

    [Fact]
    public async Task ADefaultSizeChangedInSettingsStepsOnByOffset()
    {
        await PageToAsync(pages: 2);
        var handed = Passed(1);
        _settings = new AppSettings { PageSize = 500 };

        await _tab.NextPageAsync();

        Assert.True(handed.Disposed);
        Assert.Equal((2_000L, 500L), (_session.Queries[^1].Offset, _session.Queries[^1].Limit));
        Assert.Null(_session.Resumes[^1]);
    }

    [Fact]
    public async Task LastPageGoToPageAllRowsAndCountRowsWaitForAnEngineThatSeeks()
    {
        await PageToAsync(pages: 2);

        await _tab.LastPageAsync();
        await _tab.GoToPageAsync(1);
        await _tab.ShowAllRowsAsync();
        await _tab.CountRowsAsync();

        Assert.Equal(2, _session.Queries.Count);
        Assert.False(_tab.Page.HasLast);
        Assert.False(_tab.Page.Accepts(1));
        Assert.Null(_tab.Page.Count);
        Assert.False(_tab.OffersCount);
        Assert.Equal(0, _session.Counts);
        Assert.Equal(0, _session.Estimates);
    }

    [Fact]
    public async Task APageReadThatFailsKeepsTheResumesForTheNextTry()
    {
        await PageToAsync(pages: 3);
        _session.QueryFailure = Errors.Of("ffi.not_connected");

        await _tab.NextPageAsync();

        Assert.Equal(2_000, _tab.Page.Offset);
        Assert.Equal(3_000, Passed(^1).Offset);
        Assert.DoesNotContain(Handed(), resume => resume.Disposed);

        _session.QueryFailure = null;
        await _tab.NextPageAsync();

        Assert.Same(_session.Resumes[^2], _session.Resumes[^1]);
        Assert.Equal(3_000, _tab.Page.Offset);
    }

    [Fact]
    public async Task APageThatIsStoppedKeepsTheResumesOfThePagesBeforeIt()
    {
        await _tab.ApplyFilterAsync(ByName);
        await _tab.NextPageAsync();
        await _tab.NextPageAsync();
        _session.FilteredReadEnds = new QueryOutcome.Cancelled();

        await _tab.NextPageAsync();

        Assert.Equal(2_000, _tab.Page.Offset);
        Assert.False(_tab.Page.CanSeek);
        Assert.DoesNotContain(Handed(), resume => resume.Disposed);

        _session.FilteredReadEnds = null;
        await _tab.PreviousPageAsync();

        Assert.Equal(1_000, _session.Queries[^1].Offset);
        Assert.Same(_session.Resumes[1], _session.Resumes[^1]);
    }

    [Fact]
    public async Task AFullPageTheServerSaysNothingFollowsHasNoNext()
    {
        _session.TableRows = 2_000;

        await PageToAsync(pages: 2);

        Assert.Equal(1_000, _tab.Page.Rows);
        Assert.True(_tab.Page.EndsTable);
        Assert.False(_tab.Page.HasNext);
        Assert.True(_tab.Page.IsPaged);

        _session.TableRows = 1_000;
        await _tab.SortAsync(new GridSort(1, SortDirection.Ascending));

        Assert.Equal(1_000, _tab.Page.Rows);
        Assert.False(_tab.Page.IsPaged);
    }

    [Fact]
    public async Task ClosingTheTabLetsGoOfEveryResume()
    {
        await PageToAsync(pages: 4);

        await _tab.CloseAsync();

        Assert.Equal(3, Handed().Count);
        Assert.All(Handed(), resume => Assert.True(resume.Disposed));
    }

    // The first page, then a step to each page after it.
    private async Task PageToAsync(int pages)
    {
        await _tab.RunAsync();
        for (var page = 1; page < pages; page++)
        {
            await _tab.NextPageAsync();
        }
    }

    private FakeResume Passed(Index read) => Assert.IsType<FakeResume>(_session.Resumes[read]);

    private List<FakeResume> Handed() => [.. _session.Resumes.OfType<FakeResume>().Distinct()];
}
