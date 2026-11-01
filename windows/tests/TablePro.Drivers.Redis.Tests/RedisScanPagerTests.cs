using System.Globalization;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisScanPagerTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    /// <summary>A server-side set of <paramref name="count"/> members answered <paramref name="step"/> at a time.</summary>
    private sealed class FakeScan(int count, int step)
    {
        public int Calls { get; private set; }

        public List<string> CursorsSent { get; } = [];

        public Task<(string Cursor, IReadOnlyList<RedisReply> Items)> Step(string cursor, CancellationToken cancellationToken)
        {
            Calls++;
            CursorsSent.Add(cursor);
            var start = int.Parse(cursor, CultureInfo.InvariantCulture);
            var items = Enumerable.Range(start, Math.Max(0, Math.Min(step, count - start)))
                .Select(i => RedisReply.Bulk(string.Create(CultureInfo.InvariantCulture, $"m{i}")))
                .ToArray();
            var next = start + step >= count ? "0" : (start + step).ToString(CultureInfo.InvariantCulture);
            return Task.FromResult<(string, IReadOnlyList<RedisReply>)>((next, items));
        }
    }

    private static string[] Texts(IReadOnlyList<RedisReply> items) => items.Select(i => i.Text!).ToArray();

    [Fact]
    public async Task FirstPageScansUntilFull()
    {
        var pager = new RedisScanPager();
        var scan = new FakeScan(25, 4);

        var (items, more) = await pager.PageAsync(0, "s", "SSCAN", 1, 0, 10, scan.Step, Ct);

        Assert.Equal(Enumerable.Range(0, 10).Select(i => $"m{i}"), Texts(items));
        Assert.True(more);
        Assert.Equal(3, scan.Calls);
    }

    [Fact]
    public async Task NextPageResumesWithoutRescanning()
    {
        var pager = new RedisScanPager();
        var scan = new FakeScan(25, 4);
        await pager.PageAsync(0, "s", "SSCAN", 1, 0, 10, scan.Step, Ct);

        var (items, more) = await pager.PageAsync(0, "s", "SSCAN", 1, 10, 10, scan.Step, Ct);

        Assert.Equal(Enumerable.Range(10, 10).Select(i => $"m{i}"), Texts(items));
        Assert.True(more);
        Assert.Equal(["0", "4", "8", "12", "16"], scan.CursorsSent);
    }

    [Fact]
    public async Task LastPageReportsNoMore()
    {
        var pager = new RedisScanPager();
        var scan = new FakeScan(25, 4);
        await pager.PageAsync(0, "s", "SSCAN", 1, 0, 20, scan.Step, Ct);

        var (items, more) = await pager.PageAsync(0, "s", "SSCAN", 1, 20, 20, scan.Step, Ct);

        Assert.Equal(5, items.Count);
        Assert.False(more);
    }

    [Fact]
    public async Task AnOffsetWithoutASavedCursorScansAndSkips()
    {
        var pager = new RedisScanPager();
        var scan = new FakeScan(25, 4);

        var (items, _) = await pager.PageAsync(0, "s", "SSCAN", 1, 7, 3, scan.Step, Ct);

        Assert.Equal(["m7", "m8", "m9"], Texts(items));
    }

    [Fact]
    public async Task GoingBackScansFromTheStart()
    {
        var pager = new RedisScanPager();
        var scan = new FakeScan(25, 4);
        await pager.PageAsync(0, "s", "SSCAN", 1, 0, 10, scan.Step, Ct);
        await pager.PageAsync(0, "s", "SSCAN", 1, 10, 10, scan.Step, Ct);

        var (items, _) = await pager.PageAsync(0, "s", "SSCAN", 1, 0, 2, scan.Step, Ct);

        Assert.Equal(["m0", "m1"], Texts(items));
    }

    [Fact]
    public async Task PairsStayTogether()
    {
        var pager = new RedisScanPager();
        // A server never splits a field from its value, so each step returns whole pairs.
        var scan = new FakeScan(10, 4);

        var (first, _) = await pager.PageAsync(0, "h", "HSCAN", 2, 0, 2, scan.Step, Ct);
        var (second, _) = await pager.PageAsync(0, "h", "HSCAN", 2, 2, 2, scan.Step, Ct);

        Assert.Equal(["m0", "m1", "m2", "m3"], Texts(first));
        Assert.Equal(["m4", "m5", "m6", "m7"], Texts(second));
    }

    [Fact]
    public async Task ForgetDropsTheSavedCursor()
    {
        var pager = new RedisScanPager();
        var scan = new FakeScan(25, 4);
        await pager.PageAsync(0, "s", "SSCAN", 1, 0, 10, scan.Step, Ct);
        pager.Forget(0, "s");
        scan.CursorsSent.Clear();

        await pager.PageAsync(0, "s", "SSCAN", 1, 10, 2, scan.Step, Ct);

        Assert.Equal("0", scan.CursorsSent[0]);
    }

    [Fact]
    public async Task KeysInOtherDatabasesHaveTheirOwnCursor()
    {
        var pager = new RedisScanPager();
        var scan = new FakeScan(25, 4);
        await pager.PageAsync(0, "s", "SSCAN", 1, 0, 10, scan.Step, Ct);
        scan.CursorsSent.Clear();

        await pager.PageAsync(1, "s", "SSCAN", 1, 10, 2, scan.Step, Ct);

        Assert.Equal("0", scan.CursorsSent[0]);
    }

    [Fact]
    public async Task EmptyKeyIsOneCall()
    {
        var pager = new RedisScanPager();
        var scan = new FakeScan(0, 4);

        var (items, more) = await pager.PageAsync(0, "s", "SSCAN", 1, 0, 10, scan.Step, Ct);

        Assert.Empty(items);
        Assert.False(more);
        Assert.Equal(1, scan.Calls);
    }

    [Theory]
    [InlineData("1700000000000-0", "1700000000000-1")]
    [InlineData("5-9", "5-10")]
    [InlineData("7", "7-1")]
    [InlineData("3-18446744073709551615", "4-0")]
    public void NextStreamIdIsTheSmallestIdAfter(string id, string expected) => Assert.Equal(expected, RedisScanPager.NextStreamId(id));
}
