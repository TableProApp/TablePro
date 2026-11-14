using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum KeyKind
{
    // The engine's string: text or bytes.
    Text,
    Hash,
    List,
    Set,
    SortedSet,
    Stream,

    // A module's type, such as a JSON document, which the engine names but the reader does not read.
    Other,
}

public abstract record KeyTtl
{
    private KeyTtl()
    {
    }

    public sealed record Persistent : KeyTtl
    {
        public static Persistent Instance { get; } = new();
    }

    public sealed record ExpiresIn(TimeSpan Left) : KeyTtl;

    // The login may read the key but not ask when it expires.
    public sealed record Unknown : KeyTtl
    {
        public static Unknown Instance { get; } = new();
    }
}

// Length counts entries, or a string's bytes. Rows: what the reader holds after this window, a scan's repeats left
// out. Truncated: a string longer than one window, of which the row holds the start. Restarted: the key changed type,
// so the rows began again in a new set.
public sealed record KeyWindow(
    KeyKind Kind,
    string TypeName,
    KeyTtl Ttl,
    long? Length,
    long Rows,
    bool HasMore,
    bool Truncated,
    bool Restarted);

// One key's value read a window at a time into one set, which a grid shows while Load More adds to it.
public sealed class KeyReader : IDisposable
{
    private readonly Native.KeyReader _reader;

    internal KeyReader(Native.KeyReader reader)
    {
        _reader = reader;
        Key = reader.Key();
    }

    public string Key { get; }

    // The rows read so far, a new handle each call; null before the first window. Call RowsChanged after each window.
    public ResultSet? GetRows() => _reader.Rows() is { } set ? new ResultSet(set, 0) : null;

    // Null when the key does not exist. Past the last window nothing is read and the last window comes back again.
    public async Task<KeyWindow?> ReadMoreAsync(CancellationToken cancellationToken = default)
    {
        var window = await CoreCall.RunAsync(token => _reader.ReadMore(token), cancellationToken).ConfigureAwait(false);
        return window is null ? null : Window(window);
    }

    public void Dispose() => _reader.Dispose();

    private static KeyWindow Window(Native.KeyWindowInfo window) => new(
        Kind(window.Kind),
        window.TypeName,
        Ttl(window.Ttl),
        window.Length is { } length ? Mapping.Count(length) : null,
        Mapping.Count(window.Rows),
        window.HasMore,
        window.Truncated,
        window.Restarted);

    private static KeyKind Kind(Native.KeyKindTag kind) => kind switch
    {
        Native.KeyKindTag.String => KeyKind.Text,
        Native.KeyKindTag.Hash => KeyKind.Hash,
        Native.KeyKindTag.List => KeyKind.List,
        Native.KeyKindTag.Set => KeyKind.Set,
        Native.KeyKindTag.SortedSet => KeyKind.SortedSet,
        Native.KeyKindTag.Stream => KeyKind.Stream,
        _ => KeyKind.Other,
    };

    private static KeyTtl Ttl(Native.KeyTtlTag ttl) => ttl switch
    {
        Native.KeyTtlTag.Persistent => KeyTtl.Persistent.Instance,
        Native.KeyTtlTag.ExpiresIn expires => new KeyTtl.ExpiresIn(TimeSpan.FromSeconds(expires.Seconds)),
        _ => KeyTtl.Unknown.Instance,
    };
}
