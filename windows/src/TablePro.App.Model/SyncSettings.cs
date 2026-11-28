using TablePro.Interop;

namespace TablePro.App.Model;

// How this PC syncs, kept in settings.json on this PC only (docs/decisions/0029-tablepro-sync.md).
public sealed record SyncSettings
{
    // Changed only once the core side of a choice returned, so a stored TablePro Sync means this PC has uploaded.
    public SyncProvider Provider { get; set; }

    public bool Connections { get; set; } = true;

    // Passwords ride on connection records, so turning Connections off turns them off in the same write.
    public bool Passwords { get; set; }

    public bool GroupsAndTags { get; set; } = true;

    public bool SavedQueries { get; set; } = true;

    public bool TableFavorites { get; set; } = true;

    public bool DatabaseFavorites { get; set; } = true;

    // The TablePro Sync sign-in whose state file the core used last, handed back at the next open, so another account
    // or server waits for Move my data or Start empty instead of taking this one's state.
    public string? ServiceAccount { get; set; }

    public SyncSettings WithConnections(bool on) => this with { Connections = on, Passwords = on && Passwords };

    public SyncSettings Normalized() => this with
    {
        Provider = Enum.IsDefined(Provider) ? Provider : SyncProvider.Off,
        Passwords = Connections && Passwords,
        ServiceAccount = string.IsNullOrWhiteSpace(ServiceAccount) ? null : ServiceAccount,
    };

    // The core's kinds each switch holds, by their wire names (tablepro-records). This app shows no SSH or credential
    // profiles and no table folders, so they go with the connections and the table favourites they serve.
    public SyncCategories Categories()
    {
        var off = new List<string>();
        if (!Connections)
        {
            off.AddRange(SyncKinds.Connections);
        }

        if (!GroupsAndTags)
        {
            off.AddRange(SyncKinds.GroupsAndTags);
        }

        if (!SavedQueries)
        {
            off.AddRange(SyncKinds.SavedQueries);
        }

        if (!TableFavorites)
        {
            off.AddRange(SyncKinds.TableFavorites);
        }

        if (!DatabaseFavorites)
        {
            off.AddRange(SyncKinds.DatabaseFavorites);
        }

        return new SyncCategories(off, Connections && Passwords);
    }
}

public static class SyncKinds
{
    public static IReadOnlyList<string> Connections { get; } =
        ["connection", "connection_project", "ssh_profile", "credential_profile"];

    public static IReadOnlyList<string> GroupsAndTags { get; } = ["group", "tag"];

    public static IReadOnlyList<string> SavedQueries { get; } = ["saved_query", "saved_query_folder"];

    public static IReadOnlyList<string> TableFavorites { get; } =
        ["favourite_table", "table_folder", "table_folder_item"];

    public static IReadOnlyList<string> DatabaseFavorites { get; } = ["favourite_database"];
}
