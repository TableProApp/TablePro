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

// A saved connection is reopened by id, a file opened without saving by its path.
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

// GetWindowPlacement's restored bounds, in physical pixels; Windows moves a window off a display that is gone.
public sealed record WindowPlacement
{
    public int X { get; set; }

    public int Y { get; set; }

    public int Width { get; set; }

    public int Height { get; set; }

    public bool Maximized { get; set; }

    public bool IsUsable => Width > 0 && Height > 0;
}

public sealed record SessionState
{
    public IReadOnlyList<SessionConnection> Connections { get; set; } = [];

    // The connection in front when the window closed, which is the only one that connects at launch.
    public int Front { get; set; } = -1;

    // Kept whether or not the connections are reopened.
    public WindowPlacement? Window { get; set; }

    // In effective pixels; every workspace shares it.
    public double? ObjectPaneWidth { get; set; }

    public static SessionState Empty { get; } = new();

    public SessionState Restorable()
    {
        var kept = Connections.Where(connection => connection.IsRestorable).ToList();
        var front = Front >= 0 && Front < Connections.Count ? kept.IndexOf(Connections[Front]) : -1;
        return new SessionState
        {
            Connections = kept,
            Front = front < 0 && kept.Count > 0 ? 0 : front,
            Window = Window is { IsUsable: true } ? Window : null,
            ObjectPaneWidth = ObjectPaneWidth is { } width ? ObjectPane.Clamp(width) : null,
        };
    }
}

public static class ObjectPane
{
    public const double DefaultWidth = 280;
    public const double MinWidth = 180;
    public const double MaxWidth = 640;

    public static double Clamp(double width) =>
        double.IsFinite(width) ? Math.Clamp(width, MinWidth, MaxWidth) : DefaultWidth;
}

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
