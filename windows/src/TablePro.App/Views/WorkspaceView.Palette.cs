using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Model.QuickSwitcher;
using TablePro.Interop;

namespace TablePro.App.Views;

// The palette's source and commit for one connected workspace: the catalog, databases, schemas and saved queries it
// can reach, and the open that each committed row runs. Mirrors the macOS MainContentCoordinator+QuickSwitcher.
public sealed partial class WorkspaceView
{
    public async Task<IReadOnlyList<PaletteItem>> BuildPaletteItemsAsync(CancellationToken cancellationToken)
    {
        if (_session is not { } session)
        {
            return [];
        }

        var items = new List<PaletteItem>();
        var open = Tabs.TabItems.OfType<TabViewItem>().Select(tab => tab.Content).OfType<TableTabView>().ToList();

        var scope = _singleSchema ? ObjectScope.DefaultSchema : ObjectScope.AllSchemas;
        foreach (var entry in await session.GetObjectsAsync(scope, cancellationToken).ConfigureAwait(true))
        {
            if (Kind(entry.Kind) is not { } kind)
            {
                continue;
            }

            items.Add(new PaletteItem
            {
                FrecencyKey = $"object:{entry.Kind}:{entry.Schema}.{entry.Name}",
                Name = entry.Name,
                Kind = kind,
                Subtitle = _singleSchema ? string.Empty : entry.Schema ?? string.Empty,
                SchemaName = entry.Schema,
                ObjectEntry = entry,
                IsOpenInTab = open.Any(view => view.Shows(entry.Schema, entry.Name)),
            });
        }

        if (session.Layout != DatabaseLayout.OneDatabase)
        {
            foreach (var database in await session.GetDatabasesAsync(cancellationToken).ConfigureAwait(true))
            {
                items.Add(new PaletteItem
                {
                    FrecencyKey = "database:" + database.Name,
                    Name = database.Name,
                    Kind = PaletteItemKind.Database,
                    Payload = database.Name,
                });
            }
        }

        if (session.Layout != DatabaseLayout.AsSchemas)
        {
            foreach (var schema in await session.GetSchemasAsync(cancellationToken).ConfigureAwait(true))
            {
                if (schema.IsSystem)
                {
                    continue;
                }

                items.Add(new PaletteItem
                {
                    FrecencyKey = "schema:" + schema.Name,
                    Name = schema.Name,
                    Kind = PaletteItemKind.Schema,
                    Payload = schema.Name,
                });
            }
        }

        if (_connection.ConnectionId is { } connectionId
            && await _workbench.GetSavedQueriesAsync().ConfigureAwait(true) is { } store)
        {
            var saved = await store.GetAsync(connectionId, cancellationToken).ConfigureAwait(true);
            foreach (var query in saved.Queries)
            {
                items.Add(new PaletteItem
                {
                    FrecencyKey = "savedQuery:" + query.Id,
                    Name = query.Name,
                    Kind = PaletteItemKind.SavedQuery,
                    Subtitle = query.Keyword ?? string.Empty,
                    Keyword = query.Keyword,
                    Payload = query.Sql,
                });
            }
        }

        return items;
    }

    // Runs a committed palette row through the same entry points the tree and the menu use.
    public void CommitPalette(PaletteItem item, PaletteCommitIntent intent)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (_session is not { } session)
        {
            return;
        }

        switch (item.Kind)
        {
            case PaletteItemKind.SavedQuery:
                NewQueryTab(item.Payload);
                break;
            case PaletteItemKind.Database when item.Payload is { } database:
                PickDatabase(session, database);
                break;
            case PaletteItemKind.Schema when item.Payload is { } schema:
                RevealSchema(schema);
                break;
            default:
                CommitObject(item, intent);
                break;
        }
    }

    private void CommitObject(PaletteItem item, PaletteCommitIntent intent)
    {
        if (item.ObjectEntry is not { } entry)
        {
            return;
        }

        if (ObjectFolders.HasRows(entry.Kind))
        {
            var tab = OpenTable(entry);
            if (intent == PaletteCommitIntent.OpenStructure)
            {
                tab?.ShowStructure();
            }
        }
        else if (ObjectFolders.HasDefinition(entry.Kind))
        {
            OpenDefinition(entry);
        }
        else if (entry.Kind == ObjectKind.Key)
        {
            OpenKey(entry);
        }
    }

    private static PaletteItemKind? Kind(ObjectKind kind) => kind switch
    {
        ObjectKind.Table or ObjectKind.PartitionedTable or ObjectKind.ForeignTable => PaletteItemKind.Table,
        ObjectKind.View or ObjectKind.MaterializedView => PaletteItemKind.View,
        ObjectKind.Sequence or ObjectKind.Dictionary => PaletteItemKind.Type,
        ObjectKind.Function => PaletteItemKind.Function,
        ObjectKind.Procedure => PaletteItemKind.Procedure,
        ObjectKind.Trigger => PaletteItemKind.Trigger,
        ObjectKind.Key => PaletteItemKind.Table,
        _ => null,
    };
}
