using System.Collections.Frozen;

namespace TablePro.Core.Shortcuts;

/// <summary>
/// The chord each command answers to: the user's overrides laid over the catalogue defaults. It is immutable; the
/// <c>With</c> methods return a new map whose <see cref="Overrides"/> is what settings should store.
/// </summary>
/// <remarks>
/// Overrides map a command id to a chord written as <see cref="KeyChord.ToString()"/>, or to an empty string when the
/// user cleared the command. Only what the user chose is stored: a default that yields to a chord the user assigned
/// elsewhere is resolved here, so rebinding that chord brings the default back on its own and the yielding command
/// never shows as customized. Unknown ids are kept, so a file written by a newer build loses nothing.
/// </remarks>
public sealed class ShortcutMap
{
    /// <summary>The stored value of a cleared command.</summary>
    public const string ClearedValue = "";

    private static readonly IReadOnlyDictionary<string, string> NoOverrides = FrozenDictionary<string, string>.Empty;

    private readonly Dictionary<string, KeyChord> _chords = new(StringComparer.Ordinal);
    private readonly Dictionary<(ShortcutContext Context, KeyChord Chord), ShortcutCommand> _commands = [];

    public ShortcutMap(IReadOnlyDictionary<string, string>? overrides)
    {
        Overrides = overrides ?? NoOverrides;

        // Parsed once: the user's chords, which both win for their own command and stand down any default they take.
        var assigned = new Dictionary<string, KeyChord>(StringComparer.Ordinal);
        foreach (var (id, text) in Overrides)
        {
            if (ShortcutCatalog.Find(id) is not null && TryReadOverride(text, out var chord))
            {
                assigned[id] = chord;
            }
        }

        foreach (var command in ShortcutCatalog.All)
        {
            var chord = assigned.TryGetValue(command.Id, out var own)
                ? own
                : IsClaimed(command, assigned) ? KeyChord.None : command.DefaultChord;
            _chords[command.Id] = chord;

            // A hand-edited file can give two commands one chord; the first in catalogue order keeps it.
            if (!chord.IsEmpty)
            {
                _commands.TryAdd((command.Context, chord), command);
            }
        }
    }

    public static ShortcutMap Default { get; } = new(null);

    /// <summary>What the user changed, by command id. Empty means every command has its default.</summary>
    public IReadOnlyDictionary<string, string> Overrides { get; }

    /// <summary>The chord a command answers to, or <see cref="KeyChord.None"/> when it has none.</summary>
    public KeyChord ChordFor(string id) => _chords.GetValueOrDefault(id);

    public KeyChord ChordFor(ShortcutCommand command) => ChordFor(command.Id);

    /// <summary>The chord as menus show it, <c>Ctrl+T</c>, or an empty string when the command has none.</summary>
    public string TextFor(string id) => ChordFor(id).ToString();

    /// <summary>A tooltip with the chord appended, <c>New tab (Ctrl+T)</c>, or just the label when the command has none.</summary>
    public string Hint(string label, string id)
    {
        var chord = ChordFor(id);
        return chord.IsEmpty ? label : $"{label} ({chord})";
    }

    public bool IsCustomized(string id) => Overrides.ContainsKey(id);

    /// <summary>The command a key press in <paramref name="context"/> runs, or null. Only exact context matches count, since each context's owner dispatches its own commands.</summary>
    public ShortcutCommand? CommandFor(KeyChord chord, ShortcutContext context) =>
        chord.IsEmpty ? null : _commands.GetValueOrDefault((context, chord));

    /// <summary>Every bound command of one context with its chord, one per chord, for registering accelerators.</summary>
    public IEnumerable<(ShortcutCommand Command, KeyChord Chord)> Bindings(ShortcutContext context)
    {
        foreach (var ((owner, chord), command) in _commands)
        {
            if (owner == context)
            {
                yield return (command, chord);
            }
        }
    }

    /// <summary>Another command that answers to <paramref name="chord"/> where <paramref name="command"/> can fire too, or null.</summary>
    public ShortcutCommand? FindConflict(KeyChord chord, ShortcutCommand command)
    {
        if (chord.IsEmpty)
        {
            return null;
        }

        foreach (var other in ShortcutCatalog.All)
        {
            if (!ReferenceEquals(other, command) && other.Context.Overlaps(command.Context) && ChordFor(other.Id) == chord)
            {
                return other;
            }
        }

        return null;
    }

    /// <summary>Whether the command matches a settings search, by title or by the chord it answers to.</summary>
    public bool Matches(ShortcutCommand command, string? search)
    {
        if (string.IsNullOrWhiteSpace(search))
        {
            return true;
        }

        var query = search.Trim();
        return command.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)
            || TextFor(command.Id).Contains(query, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Binds <paramref name="chord"/> to the command. Binding its default removes the override instead, so the command
    /// reads as not customized and follows a changed default in a later version.
    /// </summary>
    public ShortcutMap WithChord(string id, KeyChord chord)
    {
        var command = ShortcutCatalog.Get(id);
        var overrides = Copy();
        if (chord == command.DefaultChord && !chord.IsEmpty)
        {
            overrides.Remove(id);
        }
        else
        {
            overrides[id] = chord.IsEmpty ? ClearedValue : chord.ToString();
        }

        return new ShortcutMap(overrides);
    }

    /// <summary>Leaves the command with no chord.</summary>
    public ShortcutMap WithCleared(string id)
    {
        var overrides = Copy();
        overrides[id] = ClearedValue;
        return new ShortcutMap(overrides);
    }

    public ShortcutMap WithDefault(string id)
    {
        if (!Overrides.ContainsKey(id))
        {
            return this;
        }

        var overrides = Copy();
        overrides.Remove(id);
        return new ShortcutMap(overrides);
    }

    /// <summary>
    /// Moves a chord from <paramref name="conflicting"/> to <paramref name="command"/>. A customized loser is cleared;
    /// a default one yields on its own, because the new override claims its chord.
    /// </summary>
    public ShortcutMap Reassign(ShortcutCommand command, KeyChord chord, ShortcutCommand conflicting)
    {
        var map = IsCustomized(conflicting.Id) ? WithCleared(conflicting.Id) : this;
        return map.WithChord(command.Id, chord);
    }

    /// <summary>
    /// Drops overrides that can never fire: unreadable text, and chords without Ctrl, Alt or a function key on a
    /// command that needs one. Cleared and unknown entries are kept.
    /// </summary>
    public ShortcutMap Sanitized()
    {
        Dictionary<string, string>? cleaned = null;
        foreach (var (id, text) in Overrides)
        {
            if (ShortcutCatalog.Find(id) is not { } command)
            {
                continue;
            }

            if (!TryReadOverride(text, out var chord) || (!chord.IsEmpty && !command.Accepts(chord)))
            {
                cleaned ??= Copy();
                cleaned.Remove(id);
            }
        }

        return cleaned is null ? this : new ShortcutMap(cleaned);
    }

    private static bool TryReadOverride(string? text, out KeyChord chord)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            chord = KeyChord.None;
            return true;
        }

        return KeyChord.TryParse(text.AsSpan(), out chord);
    }

    private static bool IsClaimed(ShortcutCommand command, Dictionary<string, KeyChord> assigned)
    {
        if (command.DefaultChord.IsEmpty)
        {
            return false;
        }

        foreach (var (id, chord) in assigned)
        {
            if (chord == command.DefaultChord && id != command.Id && ShortcutCatalog.Get(id).Context.Overlaps(command.Context))
            {
                return true;
            }
        }

        return false;
    }

    private Dictionary<string, string> Copy() => new(Overrides, StringComparer.Ordinal);
}
