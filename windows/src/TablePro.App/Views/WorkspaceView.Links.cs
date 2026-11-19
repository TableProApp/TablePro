using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Views;

// What a tablepro://connect link opens once the connection is up (docs/decisions/0018, Links and files).
public sealed partial class WorkspaceView
{
    internal DatabaseLayout? Layout => _session?.Layout;

    internal string? SessionDatabase => _session?.Database;

    // The catalog's entry, so a view opens as a view; false when the connection went while the catalog was read.
    internal async Task<bool> OpenLinkedTableAsync(string? schema, string table)
    {
        if (_session is not { } session)
        {
            return false;
        }

        ObjectEntry? listed = null;
        try
        {
            var objects = await session.GetObjectsAsync(
                schema is null ? ObjectScope.DefaultSchema : ObjectScope.Schema(schema)).ConfigureAwait(true);
            listed = objects.FirstOrDefault(entry => entry.ParentTable is null && entry.Name == table)
                ?? objects.FirstOrDefault(entry =>
                    entry.ParentTable is null && string.Equals(entry.Name, table, StringComparison.OrdinalIgnoreCase));
        }
        catch (TableProException)
        {
            // The tab reads the table itself and shows why it cannot.
        }

        if (!ReferenceEquals(_session, session))
        {
            return false;
        }

        OpenTable(listed ?? new ObjectEntry(schema, table, ObjectKind.Table, null));
        return true;
    }

    // A tab that already holds exactly this SQL comes forward rather than a second one opening, as on macOS.
    internal void OpenLinkedQuery(string sql)
    {
        ArgumentNullException.ThrowIfNull(sql);
        foreach (var item in Tabs.TabItems.OfType<TabViewItem>())
        {
            if (item.Content is IQueryTabView query && string.Equals(query.WholeText, sql, StringComparison.Ordinal))
            {
                Tabs.SelectedItem = item;
                return;
            }
        }

        NewQueryTab(sql);
    }
}
