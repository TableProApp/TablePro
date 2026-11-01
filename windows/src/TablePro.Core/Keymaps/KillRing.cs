namespace TablePro.Core.Keymaps;

/// <summary>
/// Emacs's kill ring, separate from the clipboard as it is in Emacs and on macOS. Each entry holds one string per
/// caret, so a kill at several carets yanks back one piece at each. Consecutive kills with nothing in between join into
/// one entry (https://www.gnu.org/software/emacs/manual/html_node/emacs/Appending-Kills.html).
/// </summary>
public sealed class KillRing
{
    /// <summary>Emacs's kill-ring-max.</summary>
    public const int DefaultCapacity = 120;

    private readonly List<string[]> _entries = [];
    private int _yankIndex;
    private KillContinuation? _lastKill;
    private (KillContinuation State, (int Start, int End)[] Ranges)? _lastYank;

    public KillRing(int capacity = DefaultCapacity) => Capacity = Math.Max(1, capacity);

    /// <summary>One ring for every editor in the app, as macOS shares one between its text views.</summary>
    public static KillRing Shared { get; } = new();

    public int Capacity { get; }

    /// <summary>The entries, newest first.</summary>
    public IReadOnlyList<IReadOnlyList<string>> Entries => _entries;

    /// <summary>
    /// Adds a kill. When <paramref name="before"/> is where the previous kill left the editor, the kill joins that entry:
    /// appended for a forward kill, prepended for a backward one.
    /// </summary>
    public void Kill(IReadOnlyList<string> strings, bool forward, KillContinuation? before, KillContinuation after)
    {
        ArgumentNullException.ThrowIfNull(strings);
        try
        {
            if (before is { } previous && previous == _lastKill && _entries.Count > 0 && _entries[0].Length == strings.Count)
            {
                var newest = _entries[0];
                for (var i = 0; i < newest.Length; i++)
                {
                    newest[i] = forward ? newest[i] + strings[i] : strings[i] + newest[i];
                }

                return;
            }

            _entries.Insert(0, [.. strings]);
            if (_entries.Count > Capacity)
            {
                _entries.RemoveRange(Capacity, _entries.Count - Capacity);
            }
        }
        finally
        {
            _lastKill = after;
            _lastYank = null;
            _yankIndex = 0;
        }
    }

    /// <summary>The entry a yank inserts: the newest, or the one yank-pop last stepped to.</summary>
    public IReadOnlyList<string> Yank() => _entries.Count == 0 ? [] : _entries[_yankIndex];

    /// <summary>Steps to the next older entry, wrapping to the newest, and returns it.</summary>
    public IReadOnlyList<string> Rotate()
    {
        if (_entries.Count == 0)
        {
            return [];
        }

        _yankIndex = (_yankIndex + 1) % _entries.Count;
        return _entries[_yankIndex];
    }

    /// <summary>Records where a yank put its text, so a yank-pop straight after it can replace that text.</summary>
    public void DidYank(KillContinuation state, IReadOnlyList<(int Start, int End)> ranges)
    {
        ArgumentNullException.ThrowIfNull(ranges);
        _lastYank = (state, [.. ranges]);
        _lastKill = null;
    }

    /// <summary>The ranges the last yank inserted, when nothing changed since it.</summary>
    public IReadOnlyList<(int Start, int End)>? YankedRanges(KillContinuation state) =>
        _lastYank is { } yank && yank.State == state ? yank.Ranges : null;
}

/// <summary>
/// The editor as an edit left it: a kill or yank continues the previous one only while nothing moved or changed in
/// between, which the owner's change count and text length tell.
/// </summary>
public readonly record struct KillContinuation(object Owner, int Version, int Length);
