namespace TablePro.App.Model.Tests;

public sealed class SessionShareTests
{
    [Fact]
    public async Task TheLastHolderToLetGoDisposesTheSessionOnce()
    {
        var database = new FakeDatabase();
        var share = new SessionShare<FakeDatabase>(database);

        Assert.Same(share, share.Hold());
        share.Hold();
        await share.ReleaseAsync();
        await share.ReleaseAsync();

        Assert.Equal(0, database.Disposals);
        Assert.Equal(1, share.Holders);

        await share.ReleaseAsync();

        Assert.Equal(1, database.Disposals);
        Assert.Equal(0, share.Holders);
    }
}
