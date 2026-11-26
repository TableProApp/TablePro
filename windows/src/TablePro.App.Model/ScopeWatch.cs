using TablePro.Interop;

namespace TablePro.App.Model;

// The project the lists are narrowed to and the connections and groups it holds then.
public sealed class ScopedSet
{
    private readonly HashSet<Guid> _connections;
    private readonly HashSet<Guid> _groups;

    private ScopedSet(Guid? project, HashSet<Guid> connections, HashSet<Guid> groups)
    {
        Project = project;
        _connections = connections;
        _groups = groups;
    }

    // Before the first read: all connections, none of them known yet.
    public static ScopedSet None { get; } = new(null, [], []);

    // Null for all connections, also when the setting names a project the library no longer holds.
    public Guid? Project { get; }

    public IReadOnlySet<Guid> Connections => _connections;

    // A form's group choices follow these, so an empty group moved in or out changes the scope too.
    public IReadOnlySet<Guid> Groups => _groups;

    // From a snapshot the core narrowed, so the core alone says what a project holds.
    public static ScopedSet Of(LibrarySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        return new ScopedSet(
            snapshot.Scope,
            [.. snapshot.Connections.Where(connection => connection.Id is not null).Select(connection => connection.Id!.Value)],
            [.. snapshot.Groups.Select(group => group.Id)]);
    }

    // The project counts too: two empty projects hold the same nothing under different names.
    public bool Matches(ScopedSet other)
    {
        ArgumentNullException.ThrowIfNull(other);
        return Project == other.Project
            && _connections.SetEquals(other._connections)
            && _groups.SetEquals(other._groups);
    }
}

// What a read that failed leaves of the scope.
public enum FailedScopeRead
{
    // A later read is out and answers for the scope, so this one says nothing.
    Overtaken,

    // The setting names the project the lists show, or nothing was read yet: both stay and the next read retries.
    Kept,

    // A switch whose lists never loaded: the setting goes back to the project the lists show.
    Reverted,
}

// Says when what is in scope changed, whatever changed it: a switch, a move, a delete, an import.
public sealed class ScopeWatch
{
    private int _started;
    private bool _read;

    public ScopedSet Current { get; private set; } = ScopedSet.None;

    public int Start() => ++_started;

    public bool IsLatest(int read) => read == _started;

    // False for a read a later one overtook, and for one that found the scope as it was.
    public bool Show(int read, LibrarySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (read != _started)
        {
            return false;
        }

        _read = true;
        var found = ScopedSet.Of(snapshot);
        if (found.Matches(Current))
        {
            return false;
        }

        Current = found;
        return true;
    }

    // Current stays, as a failed reload keeps the page's list; before the first read there is none to go back to.
    public FailedScopeRead Fail(int read, Guid? asked)
    {
        if (read != _started)
        {
            return FailedScopeRead.Overtaken;
        }

        return _read && asked != Current.Project ? FailedScopeRead.Reverted : FailedScopeRead.Kept;
    }
}
