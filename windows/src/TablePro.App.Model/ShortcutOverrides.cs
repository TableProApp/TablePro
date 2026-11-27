namespace TablePro.App.Model;

// The stored form of the overrides: action -> chord text, "" for a removed binding. A dictionary with value equality,
// so two AppSettings with the same customs compare equal, as a record expects, and System.Text.Json reads it as a map.
public sealed class ShortcutOverrideMap : Dictionary<string, string>, IEquatable<ShortcutOverrideMap>
{
    public ShortcutOverrideMap()
        : base(StringComparer.Ordinal)
    {
    }

    public ShortcutOverrideMap(IDictionary<string, string> source)
        : base(source, StringComparer.Ordinal)
    {
    }

    public bool Equals(ShortcutOverrideMap? other) =>
        other is not null && Count == other.Count
        && this.All(pair => other.TryGetValue(pair.Key, out var value) && value == pair.Value);

    public override bool Equals(object? obj) => Equals(obj as ShortcutOverrideMap);

    public override int GetHashCode()
    {
        var hash = default(HashCode);
        foreach (var pair in this.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            hash.Add(pair.Key);
            hash.Add(pair.Value);
        }

        return hash.ToHashCode();
    }
}

// The user's per-command key customs laid over the shortcut preset (windows/docs/decisions/0028). An entry is a chord
// the user bound, or the cleared sentinel (a null chord) for a command they removed a key from; a command with no
// entry keeps the preset's key. Stored in AppSettings as action -> chord text, "" for the cleared sentinel.
public sealed class ShortcutOverrides
{
    private readonly Dictionary<string, KeyChord?> _entries;

    private ShortcutOverrides(Dictionary<string, KeyChord?> entries) => _entries = entries;

    public static ShortcutOverrides None { get; } = new([]);

    public int Count => _entries.Count;

    // Only movable commands the user touched; a renamed command's stale entry is dropped in AppSettings.Normalized.
    public IReadOnlyCollection<string> Actions => _entries.Keys;

    public bool IsCustomized(string action) => _entries.ContainsKey(action);

    // The chord bound to the action, or null when it is the cleared sentinel or has no entry; ask IsCustomized apart.
    public KeyChord? ChordFor(string action) => _entries.TryGetValue(action, out var chord) ? chord : null;

    // Reads AppSettings' storage: "" is the cleared sentinel, any other text a chord, bad text dropped.
    public static ShortcutOverrides From(IReadOnlyDictionary<string, string> stored)
    {
        ArgumentNullException.ThrowIfNull(stored);
        var entries = new Dictionary<string, KeyChord?>(StringComparer.Ordinal);
        foreach (var (action, text) in stored)
        {
            if (text.Length == 0)
            {
                entries[action] = null;
            }
            else if (KeyChord.TryParse(text, out var chord))
            {
                entries[action] = chord;
            }
        }

        return new ShortcutOverrides(entries);
    }

    public ShortcutOverrideMap ToStorage()
    {
        var map = new ShortcutOverrideMap();
        foreach (var (action, chord) in _entries)
        {
            map[action] = chord?.ToString() ?? string.Empty;
        }

        return map;
    }

    public ShortcutOverrides Assigning(string action, KeyChord chord)
    {
        ArgumentNullException.ThrowIfNull(chord);
        return With(next => next[action] = chord);
    }

    public ShortcutOverrides Clearing(string action) => With(next => next[action] = null);

    public ShortcutOverrides Resetting(string action) => With(next => next.Remove(action));

    // The new override claims the chord; every other holder loses its key, as the reassign dialog warns.
    public ShortcutOverrides Reassigning(string action, KeyChord chord, IEnumerable<string> holders)
    {
        ArgumentNullException.ThrowIfNull(chord);
        ArgumentNullException.ThrowIfNull(holders);
        return With(next =>
        {
            foreach (var holder in holders)
            {
                next[holder] = null;
            }

            next[action] = chord;
        });
    }

    private ShortcutOverrides With(Action<Dictionary<string, KeyChord?>> edit)
    {
        var next = new Dictionary<string, KeyChord?>(_entries, StringComparer.Ordinal);
        edit(next);
        return new ShortcutOverrides(next);
    }
}
