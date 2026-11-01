using System.Text;
using TablePro.Ai.Sse;

namespace TablePro.Ai.Tests;

public sealed class SseReaderTests
{
    [Fact]
    public async Task EventsSplitAcrossEveryByteStillParse()
    {
        var events = await ReadAll("event: delta\r\ndata: {\"a\":1}\r\n\r\ndata: second\r\n\r\n", chunkSize: 1);

        Assert.Equal(2, events.Count);
        Assert.Equal("delta", events[0].EventType);
        Assert.Equal("{\"a\":1}", events[0].Data);
        Assert.Null(events[1].EventType);
        Assert.Equal("second", events[1].Data);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(7)]
    [InlineData(4096)]
    public async Task ChunkBoundariesDoNotChangeTheEvents(int chunkSize)
    {
        const string body = "data: one\n\ndata: two\r\rdata: three\r\n\r\n: comment\n\ndata: four\n\n";

        var events = await ReadAll(body, chunkSize);

        Assert.Equal(["one", "two", "three", "four"], events.Select(e => e.Data));
    }

    [Fact]
    public async Task MultiLineDataJoinsWithLineFeeds()
    {
        var events = await ReadAll("data: first\ndata: second\ndata:third\n\n", chunkSize: 5);

        var evt = Assert.Single(events);
        Assert.Equal("first\nsecond\nthird", evt.Data);
    }

    [Fact]
    public async Task DoneMarkerIsRecognised()
    {
        var events = await ReadAll("data: {\"x\":1}\n\ndata: [DONE]\n\n", chunkSize: 3);

        Assert.False(events[0].IsDone);
        Assert.True(events[1].IsDone);
    }

    [Fact]
    public async Task CommentsAndEmptyEventsAreSkipped()
    {
        var events = await ReadAll(": keep-alive\n\nevent: ping\n\nretry: 1000\nid: 7\ndata: x\n\n", chunkSize: 4);

        var evt = Assert.Single(events);
        Assert.Equal("x", evt.Data);
        Assert.Equal("7", evt.Id);
    }

    [Fact]
    public async Task LastEventWithoutBlankLineIsKept()
    {
        var events = await ReadAll("data: a\n\ndata: tail", chunkSize: 2);

        Assert.Equal(["a", "tail"], events.Select(e => e.Data));
    }

    [Fact]
    public async Task LineLongerThanTheBufferIsRead()
    {
        var payload = new string('x', 100_000);

        var events = await ReadAll($"data: {payload}\n\n", chunkSize: 8192);

        Assert.Equal(payload, Assert.Single(events).Data);
    }

    [Fact]
    public async Task MultiByteCharactersSplitBetweenChunksDecode()
    {
        var events = await ReadAll("data: héllo wörld ✓\n\n", chunkSize: 1);

        Assert.Equal("héllo wörld ✓", Assert.Single(events).Data);
    }

    private static async Task<List<SseEvent>> ReadAll(string body, int chunkSize)
    {
        await using var stream = new ChunkedStream(Encoding.UTF8.GetBytes(body), chunkSize);
        var events = new List<SseEvent>();
        await foreach (var evt in SseReader.ReadAsync(stream, TestContext.Current.CancellationToken))
        {
            events.Add(evt);
        }

        return events;
    }
}

/// <summary>Hands out at most a few bytes per read, the way a slow network splits a response.</summary>
internal sealed class ChunkedStream(byte[] data, int chunkSize) : Stream
{
    private int _position;

    public override bool CanRead => true;

    public override bool CanSeek => false;

    public override bool CanWrite => false;

    public override long Length => data.Length;

    public override long Position
    {
        get => _position;
        set => throw new NotSupportedException();
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        var n = Math.Min(Math.Min(count, chunkSize), data.Length - _position);
        Array.Copy(data, _position, buffer, offset, n);
        _position += n;
        return n;
    }

    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        var n = Math.Min(Math.Min(buffer.Length, chunkSize), data.Length - _position);
        data.AsMemory(_position, n).CopyTo(buffer);
        _position += n;
        return ValueTask.FromResult(n);
    }

    public override void Flush()
    {
    }

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
