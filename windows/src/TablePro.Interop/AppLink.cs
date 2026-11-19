using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// A tablepro:// link other than a share link, which ShareLinks.TokenFromLink reads; the grammar is the core's.
public abstract record AppLink
{
    private AppLink()
    {
    }

    public sealed record OpenConnection(Guid ConnectionId) : AppLink;

    // No database means the connection's own, no schema its current one.
    public sealed record OpenTable(Guid ConnectionId, string? Database, string? Schema, string Table) : AppLink;

    // The SQL opens in a new query tab and never runs from the link.
    public sealed record OpenQuery(Guid ConnectionId, string Sql) : AppLink;

    public sealed record OpenSettings(string? Pane) : AppLink;

    // Throws TableProException with a link.* code for a link the app does not read.
    public static AppLink Parse(string link)
    {
        ArgumentNullException.ThrowIfNull(link);
        return CoreCall.Run(() => Native.CoreMethods.ParseAppLink(link)) switch
        {
            Native.AppLinkInfo.OpenConnection open => new OpenConnection(Guid.Parse(open.ConnectionId)),
            Native.AppLinkInfo.OpenTable table => new OpenTable(
                Guid.Parse(table.ConnectionId), table.Database, table.Schema, table.Table),
            Native.AppLinkInfo.OpenQuery query => new OpenQuery(Guid.Parse(query.ConnectionId), query.Sql),
            Native.AppLinkInfo.OpenSettings settings => new OpenSettings(settings.Pane),
            _ => throw new InvalidOperationException("The core gave a link this library does not know."),
        };
    }
}
