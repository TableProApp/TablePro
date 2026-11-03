namespace TablePro.App.Model;

public enum TabKind
{
    Query,
    Table,
}

public sealed record SessionTab
{
    public TabKind Kind { get; set; }

    public string Title { get; set; } = string.Empty;

    public string? Sql { get; set; }

    public string? Schema { get; set; }

    public string? Table { get; set; }
}

// A connection the window had open. A saved one is reopened by id; a file opened without saving, by its path.
public sealed record SessionConnection
{
    public Guid? ConnectionId { get; set; }

    public string? FilePath { get; set; }

    public string Name { get; set; } = string.Empty;

    public string EngineId { get; set; } = string.Empty;

    public IReadOnlyList<SessionTab> Tabs { get; set; } = [];

    public int SelectedTab { get; set; }

    public bool IsRestorable => ConnectionId is not null || !string.IsNullOrEmpty(FilePath);
}

public sealed record SessionState
{
    public IReadOnlyList<SessionConnection> Connections { get; set; } = [];

    // The connection in front when the window closed, which is the only one that connects at launch.
    public int Front { get; set; } = -1;

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
