using TablePro.Interop;

namespace TablePro.App.Services;

// A session held by each workspace and tab that uses it, so a tab moved to another window keeps its own.
internal sealed class SessionShare(DatabaseSession session)
{
    private int _holders = 1;

    public DatabaseSession Session { get; } = session;

    public SessionShare Hold()
    {
        _holders++;
        return this;
    }

    public ValueTask ReleaseAsync() => --_holders == 0 ? Session.DisposeAsync() : ValueTask.CompletedTask;
}
