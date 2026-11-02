namespace TablePro.App.Model;

public enum TabKind
{
    Query,
    Table,
}

public sealed record SessionTab
{
    public TabKind Kind { get; init; }

    public string Title { get; init; } = string.Empty;

    public string? Sql { get; init; }

    public string? Schema { get; init; }

    public string? Table { get; init; }
}

// A connection the window had open. A saved one is reopened by id; a file opened without saving, by its path.
public sealed record SessionConnection
{
    public Guid? ConnectionId { get; init; }

    public string? FilePath { get; init; }

    public string Name { get; init; } = string.Empty;

    public string EngineId { get; init; } = string.Empty;

    public IReadOnlyList<SessionTab> Tabs { get; init; } = [];

    public int SelectedTab { get; init; }

    public bool IsRestorable => ConnectionId is not null || !string.IsNullOrEmpty(FilePath);
}

public sealed record SessionState
{
    public IReadOnlyList<SessionConnection> Connections { get; init; } = [];

    // The connection in front when the window closed, which is the only one that connects at launch.
    public int Front { get; init; } = -1;

    public static SessionState Empty { get; } = new();

    public SessionState Restorable()
    {
        var kept = Connections.Where(connection => connection.IsRestorable).ToList();
        var front = Front >= 0 && Front < Connections.Count ? kept.IndexOf(Connections[Front]) : -1;
        return new SessionState
        {
            Connections = kept,
            Front = front < 0 && kept.Count > 0 ? 0 : front,
        };
    }
}

// session.json in the app's data folder.
public sealed class SessionStore(string path)
{
    public string Path { get; } = path;

    public SessionState Load() => (JsonFile.Read(Path, ModelJson.Default.SessionState) ?? SessionState.Empty).Restorable();

    public void Save(SessionState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        JsonFile.Write(Path, state, ModelJson.Default.SessionState);
    }
}
