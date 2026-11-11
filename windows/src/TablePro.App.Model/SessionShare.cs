namespace TablePro.App.Model;

// Held by each workspace and tab that uses the session, so a tab moved to another window keeps its own.
public sealed class SessionShare<T>(T session)
    where T : class, IAsyncDisposable
{
    private int _holders = 1;

    public T Session { get; } = session;

    public int Holders => _holders;

    public SessionShare<T> Hold()
    {
        _holders++;
        return this;
    }

    // The last holder to let go disposes the session.
    public ValueTask ReleaseAsync() => --_holders == 0 ? Session.DisposeAsync() : ValueTask.CompletedTask;
}
