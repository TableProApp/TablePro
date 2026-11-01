using System.Buffers;
using System.Runtime.CompilerServices;
using System.Text;

namespace TablePro.Ai.Sse;

/// <summary>One dispatched server-sent event. <see cref="Data"/> joins multi-line data with <c>\n</c>, as the spec says.</summary>
public readonly record struct SseEvent(string? EventType, string Data, string? Id)
{
    /// <summary>OpenAI and compatible servers end a stream with a literal <c>[DONE]</c> payload.</summary>
    public bool IsDone => Data == "[DONE]";
}

/// <summary>
/// Reads the <c>text/event-stream</c> format straight from the response stream's bytes. Lines are never turned into
/// strings: field values collect in a reused buffer and only an event's data is decoded, once, when it dispatches.
/// </summary>
public static class SseReader
{
    private const int InitialBufferSize = 16 * 1024;

    public static async IAsyncEnumerable<SseEvent> ReadAsync(Stream stream, [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        var parser = new Parser(ArrayPool<byte>.Shared.Rent(InitialBufferSize));
        try
        {
            while (true)
            {
                var read = await stream.ReadAsync(parser.FreeSpace(), cancellationToken);
                if (read == 0)
                {
                    break;
                }

                parser.Advance(read);
                while (parser.TryReadEvent(out var evt))
                {
                    yield return evt;
                }
            }

            // Some compatible servers close without the final blank line; the last event is still meant to count.
            if (parser.Finish() is { } last)
            {
                yield return last;
            }
        }
        finally
        {
            parser.ReturnBuffer();
        }
    }

    private sealed class Parser(byte[] buffer)
    {
        private readonly ArrayBufferWriter<byte> _data = new(1024);
        private byte[] _buffer = buffer;
        private int _start;
        private int _end;

        // A CR that ended the last chunk may be the first half of a CRLF; its LF must not read as a blank line.
        private bool _skipLeadingLf;
        private bool _hasData;
        private string? _eventType;
        private string? _lastId;

        public Memory<byte> FreeSpace()
        {
            if (_start == _end)
            {
                _start = _end = 0;
            }

            if (_end == _buffer.Length)
            {
                if (_start > 0)
                {
                    Buffer.BlockCopy(_buffer, _start, _buffer, 0, _end - _start);
                    _end -= _start;
                    _start = 0;
                }
                else
                {
                    var larger = ArrayPool<byte>.Shared.Rent(_buffer.Length * 2);
                    Buffer.BlockCopy(_buffer, 0, larger, 0, _end);
                    ArrayPool<byte>.Shared.Return(_buffer);
                    _buffer = larger;
                }
            }

            return _buffer.AsMemory(_end);
        }

        public void Advance(int count) => _end += count;

        public bool TryReadEvent(out SseEvent evt)
        {
            while (_start < _end)
            {
                if (_skipLeadingLf)
                {
                    _skipLeadingLf = false;
                    if (_buffer[_start] == (byte)'\n')
                    {
                        _start++;
                        continue;
                    }
                }

                var span = _buffer.AsSpan(_start, _end - _start);
                var lineLength = span.IndexOfAny((byte)'\r', (byte)'\n');
                if (lineLength < 0)
                {
                    break;
                }

                var consumed = lineLength + 1;
                if (span[lineLength] == (byte)'\r')
                {
                    if (consumed == span.Length)
                    {
                        _skipLeadingLf = true;
                    }
                    else if (span[consumed] == (byte)'\n')
                    {
                        consumed++;
                    }
                }

                var dispatched = ProcessLine(span[..lineLength]);
                _start += consumed;
                if (dispatched is { } ready)
                {
                    evt = ready;
                    return true;
                }
            }

            evt = default;
            return false;
        }

        public SseEvent? Finish()
        {
            if (_start < _end)
            {
                var tail = ProcessLine(_buffer.AsSpan(_start, _end - _start));
                _start = _end;
                if (tail is not null)
                {
                    return tail;
                }
            }

            return Flush();
        }

        public void ReturnBuffer() => ArrayPool<byte>.Shared.Return(_buffer);

        private SseEvent? ProcessLine(ReadOnlySpan<byte> line)
        {
            if (line.IsEmpty)
            {
                return Flush();
            }

            if (line[0] == (byte)':')
            {
                return null;
            }

            ReadOnlySpan<byte> field;
            ReadOnlySpan<byte> value;
            var colon = line.IndexOf((byte)':');
            if (colon < 0)
            {
                field = line;
                value = default;
            }
            else
            {
                field = line[..colon];
                value = line[(colon + 1)..];
                if (!value.IsEmpty && value[0] == (byte)' ')
                {
                    value = value[1..];
                }
            }

            if (field.SequenceEqual("data"u8))
            {
                if (_hasData)
                {
                    _data.Write("\n"u8);
                }

                _data.Write(value);
                _hasData = true;
            }
            else if (field.SequenceEqual("event"u8))
            {
                _eventType = Encoding.UTF8.GetString(value);
            }
            else if (field.SequenceEqual("id"u8) && !value.Contains((byte)0))
            {
                _lastId = Encoding.UTF8.GetString(value);
            }

            return null;
        }

        private SseEvent? Flush()
        {
            if (!_hasData)
            {
                _eventType = null;
                return null;
            }

            var evt = new SseEvent(_eventType, Encoding.UTF8.GetString(_data.WrittenSpan), _lastId);
            _data.ResetWrittenCount();
            _hasData = false;
            _eventType = null;
            return evt;
        }
    }
}
