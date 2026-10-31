using TablePro.Storage.Library.History;

namespace TablePro.Storage.Tests.Library;

public sealed class VersionHistoryTests
{
    [Fact]
    public void EqualTextIsIdenticalAndDifferentTextIsALineDiffThatKeepsBlankLines()
    {
        Assert.IsType<IdenticalVersions>(VersionComparison.Compare("SELECT 1;", "SELECT 1;"));
        var differs = Assert.IsType<DifferingVersions>(VersionComparison.Compare("a\n\nb", "a\n\nc\n"));
        Assert.Equal(
            [new DiffPair("a", "a", DiffKind.Unchanged), new DiffPair(string.Empty, string.Empty, DiffKind.Unchanged), new DiffPair("b", "c", DiffKind.Changed), new DiffPair(null, string.Empty, DiffKind.Added)],
            differs.Pairs);
    }

    [Fact]
    public void TextThatDiffersOnlyInLineEndingsIsIdentical() =>
        Assert.IsType<IdenticalVersions>(VersionComparison.Compare("a\r\nb", "a\nb"));

    [Fact]
    public void TextPastTheLineLimitIsNotDiffed()
    {
        var big = string.Join('\n', Enumerable.Range(0, VersionComparison.MaximumLineCount + 1));
        Assert.IsType<TooLargeToCompare>(VersionComparison.Compare(big, big + "\nmore"));
    }

    [Fact]
    public void TheDiffIsMinimalAndPairsARemovalWithTheInsertionAtTheSameStep()
    {
        var pairs = LineDiff.Split(["select", "from a", "where x", "order by 1"], ["select", "from b", "where x", "group by 1", "order by 1"]);
        Assert.Equal(
            [
                new DiffPair("select", "select", DiffKind.Unchanged),
                new DiffPair("from a", "from b", DiffKind.Changed),
                new DiffPair("where x", "where x", DiffKind.Unchanged),
                new DiffPair(null, "group by 1", DiffKind.Added),
                new DiffPair("order by 1", "order by 1", DiffKind.Unchanged),
            ],
            pairs);

        var unified = LineDiff.Unified(pairs);
        Assert.Equal([UnifiedLineKind.Context, UnifiedLineKind.Removed, UnifiedLineKind.Added, UnifiedLineKind.Context, UnifiedLineKind.Added, UnifiedLineKind.Context], unified.Select(l => l.Kind));
        Assert.Equal((int?)4, unified[4].AfterLineNumber);
        Assert.Equal((int?)4, unified[5].BeforeLineNumber);
    }

    [Fact]
    public void ADiffRebuildsBothSides()
    {
        var random = new Random(7);
        for (var run = 0; run < 50; run++)
        {
            var before = Enumerable.Range(0, random.Next(0, 40)).Select(_ => "l" + random.Next(0, 6)).ToArray();
            var after = Enumerable.Range(0, random.Next(0, 40)).Select(_ => "l" + random.Next(0, 6)).ToArray();
            var pairs = LineDiff.Split(before, after);
            Assert.Equal(before, pairs.Where(p => p.Before is not null).Select(p => p.Before!));
            Assert.Equal(after, pairs.Where(p => p.After is not null).Select(p => p.After!));
        }
    }

    [Fact]
    public void TheCurrentVersionsBaselineIsTheNewestPastVersionAndAPastVersionsIsTheCurrentOne()
    {
        var current = new VersionEntry(VersionReference.Current, null);
        var newest = new VersionEntry(new SnapshotVersion(2), null);
        var older = new VersionEntry(new SnapshotVersion(1), null);
        var page = new VersionPage([current, newest, older], []);
        Assert.Equal(newest, page.BaselineFor(VersionReference.Current));
        Assert.Equal(current, page.BaselineFor(older.Reference));
    }

    [Fact]
    public async Task SnapshotsSkipRepeatsKeepTheLatestFiftyAndFollowARename()
    {
        using var temp = new TempDirectory();
        using var store = new LocalSnapshotStore(temp.Paths);
        var subject = LocalSnapshotStore.FileSubject(temp.File("a.sql"));
        var ct = TestContext.Current.CancellationToken;

        Assert.True(await store.RecordAsync(subject, "v0", cancellationToken: ct));
        Assert.False(await store.RecordAsync(subject, "v0", cancellationToken: ct));
        for (var i = 1; i <= LocalSnapshotStore.RetainedCount + 5; i++)
        {
            await store.RecordAsync(subject, "v" + i, cancellationToken: ct);
        }

        var kept = await store.ListAsync(subject, ct);
        Assert.Equal(LocalSnapshotStore.RetainedCount, kept.Count);
        Assert.Equal("v55", kept[0].Content);

        var renamed = LocalSnapshotStore.FileSubject(temp.File("b.sql"));
        await store.MoveAsync(subject, renamed, ct);
        Assert.Empty(await store.ListAsync(subject, ct));
        Assert.Equal(LocalSnapshotStore.RetainedCount, (await store.ListAsync(renamed, ct)).Count);
        Assert.Equal(LocalSnapshotStore.FileSubject(temp.File("A.SQL")), LocalSnapshotStore.FileSubject(temp.File("a.sql")));
    }

    [Fact]
    public async Task AFileOutsideARepositoryListsItsSavedCopiesNewestFirstWithoutRepeatingTheCurrentText()
    {
        using var temp = new TempDirectory();
        using var store = new LocalSnapshotStore(temp.Paths);
        var path = temp.File("report.sql");
        var ct = TestContext.Current.CancellationToken;
        foreach (var text in new[] { "SELECT 1;", "SELECT 2;", "SELECT 3;" })
        {
            await File.WriteAllTextAsync(path, text, ct);
            await FileVersionHistoryProvider.RecordFileAsync(store, path, ct);
        }

        var provider = new FileVersionHistoryProvider(path, store, git: null);
        var page = await provider.LoadHistoryAsync(ct);

        Assert.True(page.Entries[0].IsCurrent);
        Assert.Equal(["SELECT 3;", "SELECT 2;", "SELECT 1;"], await Task.WhenAll(page.Entries.Select(e => provider.ContentAsync(e.Reference, ct))));
    }

    [Fact]
    public async Task RestoringASavedCopyKeepsTheReplacedTextAndTheFilesEncoding()
    {
        using var temp = new TempDirectory();
        using var store = new LocalSnapshotStore(temp.Paths);
        var path = temp.File("report.sql");
        var ct = TestContext.Current.CancellationToken;
        await File.WriteAllBytesAsync(path, [0xEF, 0xBB, 0xBF, .. "SELECT 1;"u8], ct);
        await FileVersionHistoryProvider.RecordFileAsync(store, path, ct);
        await File.WriteAllBytesAsync(path, [0xEF, 0xBB, 0xBF, .. "SELECT 2; -- typed elsewhere"u8], ct);

        var provider = new FileVersionHistoryProvider(path, store, git: null);
        var browser = new VersionHistoryBrowser(provider);
        await browser.LoadAsync(ct);
        var past = browser.Page.Entries.Single(e => !e.IsCurrent);

        var asked = false;
        var declined = await browser.RestoreAsync(past, () => { asked = true; return Task.FromResult(false); }, ct);
        Assert.True(asked);
        Assert.Equal(VersionRestoreOutcome.Declined, declined.Outcome);
        Assert.EndsWith("typed elsewhere", await File.ReadAllTextAsync(path, ct), StringComparison.Ordinal);

        var restored = await browser.RestoreAsync(past, () => Task.FromResult(true), ct);
        Assert.Equal(VersionRestoreOutcome.Restored, restored.Outcome);
        Assert.Equal([0xEF, 0xBB, 0xBF, .. "SELECT 1;"u8], await File.ReadAllBytesAsync(path, ct));

        // The text the restore replaced is now a version of its own.
        Assert.Contains(await store.ListAsync(provider.Subject, ct), s => s.Content == "SELECT 2; -- typed elsewhere");
        Assert.Equal(VersionReference.Current, browser.Selection);
    }

    [Fact]
    public async Task ARestoreFindingTheFileChangedSinceItWasPreparedReplacesNothing()
    {
        using var temp = new TempDirectory();
        using var store = new LocalSnapshotStore(temp.Paths);
        var path = temp.File("report.sql");
        var ct = TestContext.Current.CancellationToken;
        await File.WriteAllTextAsync(path, "SELECT 1;", ct);
        await FileVersionHistoryProvider.RecordFileAsync(store, path, ct);
        await File.WriteAllTextAsync(path, "SELECT 2;", ct);
        var provider = new FileVersionHistoryProvider(path, store, git: null);
        var page = await provider.LoadHistoryAsync(ct);

        var plan = await provider.PrepareRestoreAsync(page.Entries[1].Reference, ct);
        await File.WriteAllTextAsync(path, "SELECT 3;", ct);

        var error = await Assert.ThrowsAsync<VersionHistoryException>(() => plan.Apply(ct));
        Assert.Equal(VersionHistoryError.FileChangedBeforeWriting, error.Error);
        Assert.Equal("SELECT 3;", await File.ReadAllTextAsync(path, ct));
    }

    [Fact]
    public async Task LoadingSelectsTheCurrentVersionAndComparesItWithTheOneBefore()
    {
        var provider = new FakeProvider();
        var browser = new VersionHistoryBrowser(provider);
        await browser.LoadAsync(TestContext.Current.CancellationToken);

        Assert.Equal(VersionListState.Loaded, browser.ListState);
        Assert.Equal(VersionReference.Current, browser.Selection);
        Assert.Equal(VersionDetailState.Loaded, browser.DetailState);
        var comparison = browser.Detail!.Comparison!;
        Assert.Equal(new SnapshotVersion(2), comparison.Older.Reference);
        Assert.True(comparison.Newer.IsCurrent);
        Assert.False(browser.CanRestoreSelection);

        await browser.SelectAsync(new SnapshotVersion(1));
        Assert.Equal(new SnapshotVersion(1), browser.Detail!.Comparison!.Older.Reference);
        Assert.True(browser.Detail.Comparison.Newer.IsCurrent);
        Assert.True(browser.CanRestoreSelection);
    }

    [Fact]
    public async Task APastVersionIsReadOnceAndTheCurrentTextEveryTime()
    {
        var provider = new FakeProvider();
        var browser = new VersionHistoryBrowser(provider);
        await browser.LoadAsync(TestContext.Current.CancellationToken);
        await browser.SelectAsync(new SnapshotVersion(1));
        await browser.SelectAsync(VersionReference.Current);
        await browser.SelectAsync(new SnapshotVersion(1));

        Assert.Equal(1, provider.Reads.Count(r => r == new SnapshotVersion(1)));
        Assert.True(provider.Reads.Count(r => r is CurrentVersion) >= 3);
    }

    [Fact]
    public async Task AFailedRefreshKeepsWhatIsShownButASubjectThatIsGoneClearsIt()
    {
        var provider = new FakeProvider();
        var browser = new VersionHistoryBrowser(provider);
        await browser.LoadAsync(TestContext.Current.CancellationToken);

        provider.Failure = new VersionHistoryException(VersionHistoryError.CommandFailed, "busy");
        await browser.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(VersionListState.Loaded, browser.ListState);
        Assert.Equal(3, browser.Page.Entries.Count);

        provider.Failure = new VersionHistoryException(VersionHistoryError.SubjectNotFound);
        await browser.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(VersionListState.Failed, browser.ListState);
        Assert.Empty(browser.Page.Entries);
        Assert.Null(browser.Selection);
    }

    private sealed class FakeProvider : IVersionHistoryProvider
    {
        public List<VersionReference> Reads { get; } = [];

        public Exception? Failure { get; set; }

        public Task<VersionPage> LoadHistoryAsync(CancellationToken cancellationToken = default) =>
            Failure is { } failure
                ? Task.FromException<VersionPage>(failure)
                : Task.FromResult(new VersionPage(
                    [new(VersionReference.Current, null), new(new SnapshotVersion(2), null), new(new SnapshotVersion(1), null)],
                    []));

        public Task<string> ContentAsync(VersionReference reference, CancellationToken cancellationToken = default)
        {
            Reads.Add(reference);
            return Task.FromResult(reference switch
            {
                CurrentVersion => "c",
                SnapshotVersion s => "v" + s.Id,
                _ => string.Empty,
            });
        }

        public Task<VersionRestorePlan> PrepareRestoreAsync(VersionReference reference, CancellationToken cancellationToken = default) =>
            Task.FromResult(new VersionRestorePlan(false, _ => Task.CompletedTask));
    }
}
