using System.Text;

namespace TablePro.App.Model;

public enum SqlFileEncoding
{
    Utf8,
    Utf16LittleEndian,
    Utf16BigEndian,
    Utf32LittleEndian,
    Utf32BigEndian,
    Latin1,
}

// How a file's text was stored, so a save writes it back the same way.
public sealed record SqlFileFormat(SqlFileEncoding Encoding, bool ByteOrderMark)
{
    // What Save As writes.
    public static SqlFileFormat Utf8 { get; } = new(SqlFileEncoding.Utf8, ByteOrderMark: false);
}

// The file as it was read or written last; a write elsewhere, or an older copy restored over it, changes it.
public readonly record struct SqlFileStamp(DateTime LastWriteUtc, long Length);

public sealed record SqlFileRead(string Text, SqlFileFormat Format, SqlFileStamp Stamp);

// What a file tab opens with: its text, the file as last read or saved, and whether that read's text is unknown.
public sealed record SqlFileOpening(string Text, SqlFileRead? Baseline, bool BaselineUnknown)
{
    // A tab saved clean shows the file as it is now. One with unsaved text keeps it; a file written while the app was
    // closed then has a baseline whose text is unknown, so the tab reads as changed on disk and a save asks first.
    public static SqlFileOpening Restored(
        string sessionText,
        SqlFileStamp? savedStamp,
        bool unsaved,
        Func<SqlFileRead?> read)
    {
        ArgumentNullException.ThrowIfNull(sessionText);
        ArgumentNullException.ThrowIfNull(read);
        if (read() is not { } disk)
        {
            return new(sessionText, null, false);
        }

        if (!unsaved)
        {
            return new(disk.Text, disk, false);
        }

        return savedStamp is { } stamp && stamp != disk.Stamp
            ? new(sessionText, disk with { Stamp = stamp }, true)
            : new(sessionText, disk, false);
    }
}

// The text holds a character the file's encoding cannot store, so the file was left as it was.
public sealed class SqlFileEncodingException : IOException
{
    public SqlFileEncodingException(string filePath, SqlFileEncoding encoding, string character, Exception inner)
        : base($"{filePath} cannot store {character} in {encoding}.", inner)
    {
        FilePath = filePath;
        FileEncoding = encoding;
        Character = character;
    }

    public string FilePath { get; }

    public SqlFileEncoding FileEncoding { get; }

    public string Character { get; }
}

// The encoding comes from the byte order mark, else strict UTF-8, else Latin-1, which takes any bytes.
public static class SqlFile
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, throwOnInvalidBytes: true);

    // UTF-32 LE before UTF-16 LE, since its mark starts with UTF-16 LE's.
    private static readonly SqlFileEncoding[] MarkOrder =
    [
        SqlFileEncoding.Utf32LittleEndian,
        SqlFileEncoding.Utf32BigEndian,
        SqlFileEncoding.Utf8,
        SqlFileEncoding.Utf16LittleEndian,
        SqlFileEncoding.Utf16BigEndian,
    ];

    public static SqlFileRead Read(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        // Taken before the bytes, so a write in between reads as a change later rather than going unseen.
        var stamp = Stamp(path) ?? throw new FileNotFoundException(null, path);
        var (text, format) = Decode(File.ReadAllBytes(path));
        return new SqlFileRead(text, format, stamp);
    }

    public static (string Text, SqlFileFormat Format) Decode(ReadOnlySpan<byte> bytes)
    {
        foreach (var encoding in MarkOrder)
        {
            var mark = Mark(encoding);
            if (bytes.StartsWith(mark))
            {
                return (ReadingEncoding(encoding).GetString(bytes[mark.Length..]), new SqlFileFormat(encoding, true));
            }
        }

        try
        {
            return (StrictUtf8.GetString(bytes), SqlFileFormat.Utf8);
        }
        catch (DecoderFallbackException)
        {
            return (Encoding.Latin1.GetString(bytes), new SqlFileFormat(SqlFileEncoding.Latin1, false));
        }
    }

    // Written beside the file, then moved over it, so a failed write leaves the old file whole.
    public static SqlFileStamp Write(string path, string text, SqlFileFormat format)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(format);
        byte[] body;
        try
        {
            body = WritingEncoding(format.Encoding).GetBytes(text);
        }
        catch (EncoderFallbackException exception)
        {
            throw new SqlFileEncodingException(path, format.Encoding, Unstorable(exception), exception);
        }

        var full = Path.GetFullPath(path);
        var temporary = Path.Combine(
            Path.GetDirectoryName(full) ?? string.Empty,
            $".{Path.GetFileName(full)}.{Path.GetRandomFileName()}.tmp");
        var moved = false;
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                if (format.ByteOrderMark)
                {
                    stream.Write(Mark(format.Encoding));
                }

                stream.Write(body);
                // On disk before the move is, so a power cut after it cannot leave a file of zeros.
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporary, full, overwrite: true);
            moved = true;
        }
        finally
        {
            if (!moved)
            {
                TryDelete(temporary);
            }
        }

        return Stamp(full) ?? throw new FileNotFoundException(null, full);
    }

    // Null when the file is gone.
    public static SqlFileStamp? Stamp(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        var info = new FileInfo(path);
        return info.Exists ? new SqlFileStamp(info.LastWriteTimeUtc, info.Length) : null;
    }

    private static byte[] Mark(SqlFileEncoding encoding) => encoding switch
    {
        SqlFileEncoding.Utf8 => [0xEF, 0xBB, 0xBF],
        SqlFileEncoding.Utf16LittleEndian => [0xFF, 0xFE],
        SqlFileEncoding.Utf16BigEndian => [0xFE, 0xFF],
        SqlFileEncoding.Utf32LittleEndian => [0xFF, 0xFE, 0x00, 0x00],
        SqlFileEncoding.Utf32BigEndian => [0x00, 0x00, 0xFE, 0xFF],
        _ => [],
    };

    private static Encoding ReadingEncoding(SqlFileEncoding encoding) => encoding switch
    {
        SqlFileEncoding.Utf16LittleEndian => new UnicodeEncoding(bigEndian: false, byteOrderMark: false),
        SqlFileEncoding.Utf16BigEndian => new UnicodeEncoding(bigEndian: true, byteOrderMark: false),
        SqlFileEncoding.Utf32LittleEndian => new UTF32Encoding(bigEndian: false, byteOrderMark: false),
        SqlFileEncoding.Utf32BigEndian => new UTF32Encoding(bigEndian: true, byteOrderMark: false),
        SqlFileEncoding.Latin1 => Encoding.Latin1,
        _ => new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
    };

    // Each one refuses a character it cannot store instead of writing a question mark in its place.
    private static Encoding WritingEncoding(SqlFileEncoding encoding) => encoding switch
    {
        SqlFileEncoding.Utf16LittleEndian => new UnicodeEncoding(false, false, throwOnInvalidBytes: true),
        SqlFileEncoding.Utf16BigEndian => new UnicodeEncoding(true, false, throwOnInvalidBytes: true),
        SqlFileEncoding.Utf32LittleEndian => new UTF32Encoding(false, false, throwOnInvalidCharacters: true),
        SqlFileEncoding.Utf32BigEndian => new UTF32Encoding(true, false, throwOnInvalidCharacters: true),
        SqlFileEncoding.Latin1 => Encoding.GetEncoding(
            Encoding.Latin1.CodePage,
            EncoderFallback.ExceptionFallback,
            DecoderFallback.ReplacementFallback),
        _ => StrictUtf8,
    };

    private static string Unstorable(EncoderFallbackException exception) =>
        exception.CharUnknownHigh != '\0'
            ? new string([exception.CharUnknownHigh, exception.CharUnknownLow])
            : new string(exception.CharUnknown, 1);

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // The write's own failure is the one to report.
        }
    }
}
