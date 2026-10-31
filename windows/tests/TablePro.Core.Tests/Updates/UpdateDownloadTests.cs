using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using TablePro.Core.Updates;

namespace TablePro.Core.Tests.Updates;

public sealed class UpdateDownloadTests
{
    private static readonly byte[] Payload = Encoding.UTF8.GetBytes("TablePro release payload");

    [Fact]
    public async Task AcceptsTheBytesTheFeedDescribes()
    {
        Assert.True(await UpdateDownload.MatchesAsync(new MemoryStream(Payload), Asset(Payload), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task AcceptsAnUppercaseDigest()
    {
        var asset = Asset(Payload) with { Sha256 = Asset(Payload).Sha256.ToUpperInvariant() };

        Assert.True(await UpdateDownload.MatchesAsync(new MemoryStream(Payload), asset, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task RefusesChangedBytes()
    {
        var tampered = (byte[])Payload.Clone();
        tampered[0] ^= 1;

        Assert.False(await UpdateDownload.MatchesAsync(new MemoryStream(tampered), Asset(Payload), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task RefusesATruncatedOrLongerDownload()
    {
        Assert.False(await UpdateDownload.MatchesAsync(new MemoryStream(Payload[..^1]), Asset(Payload), TestContext.Current.CancellationToken));
        Assert.False(await UpdateDownload.MatchesAsync(new MemoryStream([.. Payload, 0]), Asset(Payload), TestContext.Current.CancellationToken));
    }

    private static UpdateAsset Asset(byte[] content) => new(
        UpdateAssetKind.Zip,
        Architecture.X64,
        new Uri("https://example.test/TablePro.zip"),
        content.Length,
        Convert.ToHexStringLower(SHA256.HashData(content)));
}
