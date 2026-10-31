namespace TablePro.Core.Interaction;

/// <summary>
/// Lets a list that toggles a row on every click treat a double-click as one toggle. ListView raises ItemClick for both
/// clicks of a double-click, so a folder in the SQL files pane opened and closed again and looked as if it would not
/// expand. A click on the same row within the double-click time of the last one that acted is the second half of a
/// double-click and is dropped.
/// </summary>
public sealed class RepeatClickFilter(TimeSpan doubleClickTime)
{
    private object? _lastKey;
    private TimeSpan _lastAt = TimeSpan.MinValue;

    /// <param name="key">What was clicked, compared with <see cref="object.Equals(object?)"/>.</param>
    /// <param name="at">When, on any monotonic clock, such as <see cref="Environment.TickCount64"/>.</param>
    /// <returns>True when the click should act.</returns>
    public bool ShouldAct(object key, TimeSpan at)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (Equals(key, _lastKey) && at - _lastAt <= doubleClickTime)
        {
            // Swallowed; the next click starts a fresh pair.
            _lastKey = null;
            return false;
        }

        _lastKey = key;
        _lastAt = at;
        return true;
    }
}
