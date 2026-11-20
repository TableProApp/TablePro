namespace TablePro.App.Model;

// Which read of the library the Connections page may show. Each read takes the project active when it starts.
public sealed class LibraryReads
{
    private int _started;
    private int _shown;

    public int Start() => ++_started;

    // False for a read a later one overtook: its snapshot is older, or of a project the user has left.
    public bool Show(int read)
    {
        if (read != _started)
        {
            return false;
        }

        _shown = read;
        return true;
    }

    // A read still out started before the scope changed, so the list is kept only when it is settled and of that scope.
    public bool ScopeNeedsRead(ScopedSet shown, ScopedSet now)
    {
        ArgumentNullException.ThrowIfNull(shown);
        ArgumentNullException.ThrowIfNull(now);
        return !shown.Matches(now) || _shown != _started;
    }
}
