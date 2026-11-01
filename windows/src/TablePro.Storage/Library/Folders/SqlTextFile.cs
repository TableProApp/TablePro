using System.Text;

namespace TablePro.Storage.Library.Folders;

/// <summary>A text file's content and how it was encoded on disk, so a write puts it back the same way.</summary>
public sealed record SqlTextContent(string Text, Encoding Encoding, bool HasByteOrderMark)
{
    public string EncodingName => Encoding.WebName;
}

/// <summary>
/// Reads and writes linked SQL files. A byte order mark decides the encoding; otherwise valid UTF-8 is UTF-8 and
/// anything else is read as Windows-1252's Latin-1 subset, so an old file opens rather than failing. A write keeps the
/// encoding and the mark the file had.
/// </summary>
public static class SqlTextFile
{
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    public static async Task<SqlTextContent> ReadAsync(string path, CancellationToken cancellationToken = default) =>
        Decode(await File.ReadAllBytesAsync(path, cancellationToken));

    /// <summary>The first <paramref name="maxBytes"/> of a file, enough for its header without reading a large script.</summary>
    public static SqlTextContent ReadHeader(string path, int maxBytes = 16 * 1024)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan);
        var buffer = new byte[(int)Math.Min(maxBytes, stream.Length)];
        var read = stream.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);
        ReadOnlySpan<byte> bytes = buffer.AsSpan(0, read);

        // A cut through the middle of a UTF-8 sequence would make a valid file look like Latin-1.
        if (read == maxBytes)
        {
            bytes = TrimPartialUtf8(bytes);
        }

        return Decode(bytes);
    }

    public static SqlTextContent Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]))
        {
            return new SqlTextContent(Encoding.UTF8.GetString(bytes[3..]), new UTF8Encoding(true), true);
        }

        if (bytes.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xFE]))
        {
            return new SqlTextContent(Encoding.Unicode.GetString(bytes[2..]), Encoding.Unicode, true);
        }

        if (bytes.StartsWith((ReadOnlySpan<byte>)[0xFE, 0xFF]))
        {
            return new SqlTextContent(Encoding.BigEndianUnicode.GetString(bytes[2..]), Encoding.BigEndianUnicode, true);
        }

        try
        {
            return new SqlTextContent(StrictUtf8.GetString(bytes), new UTF8Encoding(false), false);
        }
        catch (DecoderFallbackException)
        {
            return new SqlTextContent(Encoding.Latin1.GetString(bytes), Encoding.Latin1, false);
        }
    }

    public static byte[] Encode(string text, Encoding encoding, bool withByteOrderMark)
    {
        var body = encoding.GetBytes(text);
        var preamble = withByteOrderMark ? encoding.GetPreamble() : [];
        if (preamble.Length == 0 && withByteOrderMark && encoding is UTF8Encoding)
        {
            preamble = [0xEF, 0xBB, 0xBF];
        }

        return [.. preamble, .. body];
    }

    /// <summary>Replaces a file's text atomically in the encoding it was read with.</summary>
    public static Task WriteAsync(string path, string text, SqlTextContent? original, CancellationToken cancellationToken = default)
    {
        var bytes = Encode(text, original?.Encoding ?? new UTF8Encoding(false), original?.HasByteOrderMark ?? false);
        return WriteBytesAsync(path, bytes, cancellationToken);
    }

    public static Task WriteBytesAsync(string path, byte[] bytes, CancellationToken cancellationToken = default) =>
        AtomicFile.WriteAsync(path, (stream, ct) => stream.WriteAsync(bytes, ct).AsTask(), cancellationToken);

    private static ReadOnlySpan<byte> TrimPartialUtf8(ReadOnlySpan<byte> bytes)
    {
        for (var back = 1; back <= Math.Min(3, bytes.Length); back++)
        {
            var b = bytes[^back];
            if ((b & 0xC0) == 0x80)
            {
                continue;
            }

            // A lead byte: keep it only when all its continuation bytes made it in.
            var needed = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1;
            return needed > back ? bytes[..^back] : bytes;
        }

        return bytes;
    }
}
