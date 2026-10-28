namespace TablePro.Storage.Workspace;

public enum WorkspaceTabKind
{
    Query,
    Table,
}

/// <summary>One open tab, with enough to reopen it where the user left it.</summary>
public sealed record WorkspaceTab
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public WorkspaceTabKind Kind { get; init; }
    public string Title { get; init; } = string.Empty;

    /// <summary>The editor text of a query tab, including what was never saved to a file.</summary>
    public string? QueryText { get; init; }

    /// <summary>The .sql file a query tab was opened from, if any.</summary>
    public string? FilePath { get; init; }

    public string? Database { get; init; }
    public string? Schema { get; init; }

    /// <summary>The table or view a table tab browses.</summary>
    public string? ObjectName { get; init; }

    public bool IsPinned { get; init; }
}

/// <summary>The tabs a connection had open when the app last saved its session.</summary>
public sealed record WorkspaceState
{
    public required Guid ConnectionId { get; init; }
    public IReadOnlyList<WorkspaceTab> Tabs { get; init; } = [];
    public int SelectedIndex { get; init; }
    public string? Database { get; init; }
    public string? Schema { get; init; }
    public DateTimeOffset SavedAt { get; init; } = DateTimeOffset.UtcNow;
}
