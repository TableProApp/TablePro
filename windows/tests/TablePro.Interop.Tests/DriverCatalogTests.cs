using System.Net;
using TablePro.App.Services;

namespace TablePro.Interop.Tests;

public sealed class DriverCatalogTests : IDisposable
{
    private static readonly Uri Catalog = new("https://example.com/drivers/v1.json");
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-download-tests-").FullName;

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    [Fact]
    public async Task AMalformedReleaseUrlIsAHandledDownloadFailure()
    {
        using var body = new InterruptedStream(stall: false);
        using var handler = new ResponseHandler(body);
        using var client = new HttpClient(handler);

        await Assert.ThrowsAsync<InvalidOperationException>(() => Download(client, "https://["));

        Assert.False(handler.Requested);
        Assert.Empty(Directory.EnumerateFiles(_directory));
    }

    [Fact]
    public async Task AFailedResponseBodyRemovesItsPartialFile()
    {
        using var body = new InterruptedStream(stall: false);
        using var handler = new ResponseHandler(body);
        using var client = new HttpClient(handler);

        await Assert.ThrowsAsync<HttpRequestException>(() => Download(client, "sqlite.dll"));

        Assert.True(body.Started);
        Assert.Empty(Directory.EnumerateFiles(_directory));
    }

    [Fact]
    public async Task AStalledBodyTimesOutAndRemovesItsPartialFile()
    {
        using var body = new InterruptedStream(stall: true);
        using var handler = new ResponseHandler(body);
        using var client = new HttpClient(handler);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            Download(client, "sqlite.dll", TimeSpan.FromSeconds(1)).WaitAsync(TimeSpan.FromSeconds(10)));

        Assert.True(body.Started);
        Assert.Empty(Directory.EnumerateFiles(_directory));
    }

    private Task<string> Download(HttpClient client, string url, TimeSpan? timeout = null) =>
        DriverCatalog.DownloadAsync(
            new AvailableDriver("sqlite", "SQLite", "1.0.0", url, "unused"),
            CancellationToken.None,
            client,
            Catalog,
            timeout ?? TimeSpan.FromSeconds(10),
            _directory);

    private sealed class ResponseHandler(Stream body) : HttpMessageHandler
    {
        public bool Requested { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requested = true;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(body) });
        }
    }

    private sealed class InterruptedStream(bool stall) : Stream
    {
        public bool Started { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (!Started)
            {
                Started = true;
                buffer.Span[0] = 0x4D;
                return 1;
            }

            if (stall)
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
            }

            throw new IOException("The response body was interrupted.");
        }

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
