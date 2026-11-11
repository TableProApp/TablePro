namespace TablePro.App.Model;

public enum SessionSave
{
    Written,

    // A newer save came first, or the last save was already written.
    Skipped,

    // The file refused it, as when another program holds it; the one before stays on disk.
    Refused,
}

// Saves are written one at a time and never over a newer one, so a save from the pool cannot undo a later one.
public sealed class SessionWriter(SessionStore store)
{
    // Taking a turn never waits on a write, so the UI thread that takes one is never held by a slow disk.
    private readonly Lock _turns = new();
    private readonly Lock _writes = new();
    private long _taken;
    private bool _ended;
    private long _attempted;

    // On the pool, so a large session never stalls the window that asked.
    public Task<SessionSave> SaveInBackgroundAsync(SessionState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        var turn = Take(end: false);
        return turn == 0 ? Task.FromResult(SessionSave.Skipped) : Task.Run(() => Write(turn, state));
    }

    // On this thread. The last save, as the app closes or its session ends, also refuses every save after it.
    public SessionSave Save(SessionState state, bool last = false)
    {
        ArgumentNullException.ThrowIfNull(state);
        var turn = Take(last);
        return turn == 0 ? SessionSave.Skipped : Write(turn, state);
    }

    private long Take(bool end)
    {
        lock (_turns)
        {
            if (_ended)
            {
                return 0;
            }

            _ended = end;
            return ++_taken;
        }
    }

    private SessionSave Write(long turn, SessionState state)
    {
        lock (_writes)
        {
            if (turn <= _attempted)
            {
                return SessionSave.Skipped;
            }

            _attempted = turn;
            try
            {
                store.Save(state);
                return SessionSave.Written;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                return SessionSave.Refused;
            }
        }
    }
}
