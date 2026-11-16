using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// Emptying and dropping a table, and making and dropping a schema or database: asked, planned by the core, run at once
// through Safe Mode, then the tree and the tabs follow (core/docs/decisions/0013-catalog-operations.md).
public sealed partial class WorkspaceView
{
    // Read-only, by the connection or its Safe Mode, offers none of them, nor does a window whose bar is busy with an
    // export, an import or another change.
    private CatalogAbilities Abilities =>
        _session is { IsReadOnly: false } session && _exporting is null ? session.CatalogAbilities : CatalogAbilities.None;

    public bool CanCreateDatabase => Abilities.CreateDatabase;

    public bool CanCreateSchema => Abilities.CreateSchema;

    public bool CanTruncate(ObjectEntry entry) => IsTable(entry) && Abilities.TruncateTable;

    public bool CanDrop(ObjectEntry entry) => IsTable(entry) && Abilities.DropTable;

    public async Task NewSchemaAsync()
    {
        if (_session is not { } session || !CanCreateSchema)
        {
            return;
        }

        var abilities = Abilities;
        var choices = abilities.SchemaOwner ? await ChoicesAsync(session).ConfigureAwait(true) : NewDatabaseChoices.None;
        if (!Holds(session))
        {
            return;
        }

        using var change = await CatalogDialogs.AskNewSchemaAsync(this, session, abilities, choices).ConfigureAwait(true);
        if (change is null || !await RunCatalogChangeAsync(session, change, "CreateSchemaFailed").ConfigureAwait(true))
        {
            return;
        }

        await RefreshAsync().ConfigureAwait(true);
        if (CreatedName(change) is { } name)
        {
            RevealSchema(name);
        }
    }

    public async Task NewDatabaseAsync()
    {
        if (_session is not { } session || !CanCreateDatabase)
        {
            return;
        }

        var abilities = Abilities;
        var choices = await ChoicesAsync(session).ConfigureAwait(true);
        if (!Holds(session))
        {
            return;
        }

        using var change = await CatalogDialogs.AskNewDatabaseAsync(this, session, abilities, choices).ConfigureAwait(true);
        if (change is null
            || !await RunCatalogChangeAsync(session, change, abilities.Keyspaces ? "CreateKeyspaceFailed" : "CreateDatabaseFailed")
                .ConfigureAwait(true))
        {
            return;
        }

        if (session.Layout == DatabaseLayout.AsSchemas)
        {
            await RefreshAsync().ConfigureAwait(true);
        }

        // As macOS does, the window goes on in the new database.
        if (CreatedName(change) is { } name && Holds(session))
        {
            PickDatabase(session, name);
        }
    }

    private static bool IsTable(ObjectEntry entry) => entry.Kind is ObjectKind.Table or ObjectKind.PartitionedTable;

    private static string? CreatedName(CatalogChange change) => change.Operation switch
    {
        CatalogOperation.CreateSchema schema => schema.Name,
        CatalogOperation.CreateDatabase database => database.Draft.Name,
        _ => null,
    };

    private async Task TruncateAsync(ObjectEntry entry)
    {
        if (_session is not { } session || !CanTruncate(entry))
        {
            return;
        }

        var table = new TableName(entry.Schema, entry.Name);
        var abilities = Abilities;
        var referencing = await ReferencingAsync(session, table).ConfigureAwait(true);
        if (!Holds(session))
        {
            return;
        }

        if (referencing.Count > 0 && abilities.TruncateRefusedWhenReferenced)
        {
            await CatalogDialogs.ShowRefusedAsync(
                    this,
                    Strings.Get("TruncateRefusedTitle"),
                    Strings.Format("TruncateRefusedMessage", entry.Name, CatalogDialogs.Names(table, referencing)))
                .ConfigureAwait(true);
            return;
        }

        var clusters = abilities.OnCluster ? (await ChoicesAsync(session).ConfigureAwait(true)).Clusters : [];
        if (!Holds(session))
        {
            return;
        }

        using var change = await CatalogDialogs.AskTruncateAsync(this, session, table, abilities, clusters).ConfigureAwait(true);
        if (change is null || !await RunCatalogChangeAsync(session, change, "TruncateFailed").ConfigureAwait(true))
        {
            return;
        }

        // A cascade empties the tables pointing at this one, and a partitioned table its partitions, so every table tab
        // reads again; one holding edits comes forward first, since the question names no table.
        var items = Tabs.TabItems.OfType<TabViewItem>().Where(item => item.Content is TableTabView).ToList();
        foreach (var item in items)
        {
            if (item.Content is TableTabView view && Tabs.TabItems.Contains(item))
            {
                if (view.Model.HasUnsavedChanges)
                {
                    Tabs.SelectedItem = item;
                }

                await view.RefreshRowsAsync().ConfigureAwait(true);
            }
        }
    }

    private async Task DropTableAsync(ObjectEntry entry)
    {
        if (_session is not { } session || !CanDrop(entry))
        {
            return;
        }

        var table = new TableName(entry.Schema, entry.Name);
        var abilities = Abilities;
        var referencing = await ReferencingAsync(session, table).ConfigureAwait(true);
        if (!Holds(session))
        {
            return;
        }

        if (referencing.Count > 0 && !abilities.DropTableCascade)
        {
            await CatalogDialogs.ShowRefusedAsync(
                    this,
                    Strings.Get("DropTableRefusedTitle"),
                    Strings.Format("DropTableRefusedMessage", entry.Name, CatalogDialogs.Names(table, referencing)))
                .ConfigureAwait(true);
            return;
        }

        using var change = await CatalogDialogs.AskDropTableAsync(this, session, table, abilities, referencing)
            .ConfigureAwait(true);
        if (change is null || !await RunCatalogChangeAsync(session, change, "DropTableFailed").ConfigureAwait(true))
        {
            return;
        }

        await DiscardTabsAsync(view => view.Shows(entry.Schema, entry.Name)).ConfigureAwait(true);
        _workbench.TableFilters.ForgetTable(FilterConnection, session.Database, table);
        // A partitioned table takes its partitions with it, and Cascade the views on it, so every tab whose object the
        // catalog no longer lists goes too.
        await DiscardGoneTabsAsync(session, entry.Schema).ConfigureAwait(true);
        await RefreshAsync().ConfigureAwait(true);
        if (entry.Schema is { } schema && !_singleSchema)
        {
            RevealSchema(schema);
        }
    }

    private async Task DropSchemaAsync(string schema)
    {
        if (_session is not { } session || !Abilities.DropSchema)
        {
            return;
        }

        using var change = await CatalogDialogs.AskDropSchemaAsync(this, session, schema, Abilities).ConfigureAwait(true);
        if (change is null || !await RunCatalogChangeAsync(session, change, "DropSchemaFailed").ConfigureAwait(true))
        {
            return;
        }

        await DiscardObjectTabsAsync(shown => string.Equals(shown.Schema, schema, StringComparison.Ordinal))
            .ConfigureAwait(true);
        _workbench.TableFilters.ForgetSchema(FilterConnection, session.Database, schema);
        // Cascade drops the views in other schemas that read this one's tables too.
        await DiscardGoneTabsAsync(session, null).ConfigureAwait(true);
        await RefreshAsync().ConfigureAwait(true);
    }

    private async Task DropDatabaseAsync(string database)
    {
        if (_session is not { } session || !Abilities.DropDatabase)
        {
            return;
        }

        var abilities = Abilities;
        var clusters = abilities.OnCluster ? (await ChoicesAsync(session).ConfigureAwait(true)).Clusters : [];
        if (!Holds(session))
        {
            return;
        }

        using var change = await CatalogDialogs.AskDropDatabaseAsync(this, session, database, abilities, clusters)
            .ConfigureAwait(true);
        if (change is null
            || !await RunCatalogChangeAsync(session, change, abilities.Keyspaces ? "DropKeyspaceFailed" : "DropDatabaseFailed")
                .ConfigureAwait(true))
        {
            return;
        }

        if (session.Layout == DatabaseLayout.AsSchemas)
        {
            // Each database is a schema of this connection's catalog, so its tabs and filters go with it.
            await DiscardObjectTabsAsync(shown => string.Equals(shown.Schema, database, StringComparison.Ordinal))
                .ConfigureAwait(true);
            _workbench.TableFilters.ForgetSchema(FilterConnection, session.Database, database);
            await DiscardGoneTabsAsync(session, null).ConfigureAwait(true);
            if (string.Equals(_defaultDatabase, database, StringComparison.Ordinal))
            {
                _defaultDatabase = null;
                SessionChanged?.Invoke(this, EventArgs.Empty);
            }

            await RefreshAsync().ConfigureAwait(true);
            ShowDatabase();
        }
        else
        {
            _workbench.TableFilters.ForgetDatabase(FilterConnection, database);
        }
    }

    // A creation that Safe Mode asks before is asked once more with the statements, as a save is; emptying or dropping
    // was asked in its own question, which showed them. True only once the change landed on this window's session.
    private async Task<bool> RunCatalogChangeAsync(DatabaseSession session, CatalogChange change, string failedTitle)
    {
        if (!Holds(session))
        {
            return false;
        }

        if (change.Gate == SaveGate.Refuse)
        {
            await CatalogDialogs.ShowRefusedAsync(this, Strings.Get(failedTitle), Strings.Get("EditLockReadOnly"))
                .ConfigureAwait(true);
            return false;
        }

        if (change.Gate == SaveGate.Confirm && !change.IsDestructive)
        {
            var statements = change.Statements.Select(statement => new PlannedStatement(statement, [])).ToList();
            if (!await RowEditDialogs.ConfirmSaveAsync(this, session.Name, statements).ConfigureAwait(true))
            {
                return false;
            }
        }

        if (_exporting is not null)
        {
            return false;
        }

        // The bar's Cancel stops a change waiting on a lock, and leaving the window stops it too.
        using var running = new CancellationTokenSource();
        _exporting = running;
        ShowExport(InfoBarSeverity.Informational, Strings.Format("CatalogChangeRunning", session.Name), running: true);
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        CatalogChangeOutcome outcome;
        try
        {
            outcome = await change.RunAsync(confirmed: true, running.Token).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            await CatalogDialogs.ShowRefusedAsync(this, Strings.Get(failedTitle), Strings.Error(exception.Error))
                .ConfigureAwait(true);
            return false;
        }
        catch (OperationCanceledException)
        {
            // A statement stopped once sent may have run, so the tree is read again and nothing closes.
            if (Holds(session))
            {
                ShowExport(InfoBarSeverity.Informational, Strings.Get("CatalogChangeStopped"), running: false);
                await RefreshAsync().ConfigureAwait(true);
            }

            return false;
        }
        catch (ObjectDisposedException)
        {
            // The window let go of its session while the change waited.
            return false;
        }
        finally
        {
            _exporting = null;
            if (ExportBar.Severity == InfoBarSeverity.Informational && !ExportBar.IsClosable)
            {
                ExportBar.IsOpen = false;
            }

            CommandsChanged?.Invoke(this, EventArgs.Empty);
        }

        switch (outcome)
        {
            case CatalogChangeOutcome.Failed failed:
                await CatalogDialogs.ShowRefusedAsync(this, Strings.Get(failedTitle), Strings.Error(failed.Error))
                    .ConfigureAwait(true);
                return false;
            case CatalogChangeOutcome.Unknown unknown:
                // It may not have landed, so the tree is read again but no tab or kept filter goes with it.
                await CatalogDialogs.ShowRefusedAsync(
                        this,
                        Strings.Get(failedTitle),
                        $"{Strings.Error(unknown.Error)} {Strings.Get("CatalogChangeUnknown")}")
                    .ConfigureAwait(true);
                if (Holds(session))
                {
                    await RefreshAsync().ConfigureAwait(true);
                }

                return false;
            default:
                return Holds(session);
        }
    }

    // The keys that cannot be read leave the refusal to the server.
    private static async Task<IReadOnlyList<TableName>> ReferencingAsync(DatabaseSession session, TableName table)
    {
        try
        {
            using var keys = await session.ReadTableKeysAsync(table).ConfigureAwait(true);
            return keys.ReferencingTables;
        }
        catch (Exception exception) when (exception is TableProException or ObjectDisposedException)
        {
            return [];
        }
    }

    // A server that lists none leaves every picker with only its own default.
    private static async Task<NewDatabaseChoices> ChoicesAsync(DatabaseSession session)
    {
        try
        {
            return await session.GetDatabaseChoicesAsync().ConfigureAwait(true);
        }
        catch (Exception exception) when (exception is TableProException or ObjectDisposedException)
        {
            return NewDatabaseChoices.None;
        }
    }

    private List<TableTabView> TableViews() =>
        [.. Tabs.TabItems.OfType<TabViewItem>().Select(item => item.Content).OfType<TableTabView>()];

    // A read can outlast the window's session: a disconnect replaces it, and the last holder disposes it.
    private bool Holds(DatabaseSession session) => ReferenceEquals(_session, session);

    // The objects of each schema a table or definition tab shows or a kept filter names, read again: what the catalog
    // no longer lists loses its tabs and its filter. A schema that cannot be read changes nothing.
    private async Task DiscardGoneTabsAsync(DatabaseSession session, string? dropped)
    {
        HashSet<ShownObject> gone = [];
        var schemas = ObjectTabs().Select(shown => shown.Schema)
            .Concat(_workbench.TableFilters.SchemasWithFilters(FilterConnection, session.Database))
            .Append(dropped)
            .Distinct()
            .ToList();
        foreach (var schema in schemas)
        {
            IReadOnlyList<ObjectEntry> objects;
            try
            {
                var scope = schema is null ? ObjectScope.DefaultSchema : ObjectScope.Schema(schema);
                objects = await session.RefreshObjectsAsync(scope).ConfigureAwait(true);
            }
            catch (TableProException)
            {
                continue;
            }
            catch (ObjectDisposedException)
            {
                return;
            }

            if (!Holds(session))
            {
                return;
            }

            _workbench.TableFilters.ForgetMissing(
                FilterConnection, session.Database, schema, objects.Select(entry => entry.Name).ToHashSet(StringComparer.Ordinal));

            // A tab opened from the tree and one restored can spell the default schema apart, so a name with no
            // schema on either side is the same object; a trigger is its table's.
            foreach (var shown in ObjectTabs().Where(shown => shown.Schema == schema))
            {
                if (!objects.Any(entry => entry.Name == shown.Name
                    && (shown.Kind is null || (entry.Kind == shown.Kind && entry.ParentTable == shown.ParentTable))
                    && (entry.Schema is null || schema is null || entry.Schema == schema)))
                {
                    gone.Add(shown);
                }
            }
        }

        await DiscardObjectTabsAsync(gone.Contains).ConfigureAwait(true);

        // A table that stays can lose a foreign key into one that went, so every other table tab reads its keys again.
        foreach (var view in TableViews())
        {
            await view.ForgetCatalogAsync().ConfigureAwait(true);
        }
    }

    // What a table or definition tab shows; a table tab's kind is left open, since a table and a view read alike.
    private readonly record struct ShownObject(string? Schema, string Name, ObjectKind? Kind, string? ParentTable);

    private static ShownObject? ShownBy(object? content) => content switch
    {
        TableTabView table => new ShownObject(table.Model.Table.Schema, table.Model.Table.Name, null, null),
        DefinitionTabView definition =>
            new ShownObject(definition.Entry.Schema, definition.Entry.Name, definition.Entry.Kind, definition.Entry.ParentTable),
        _ => null,
    };

    private List<ShownObject> ObjectTabs() =>
        [.. Tabs.TabItems.OfType<TabViewItem>().Select(item => ShownBy(item.Content)).OfType<ShownObject>()];

    // The object is gone, so its tabs close without asking, and none is kept to reopen.
    private async Task DiscardObjectTabsAsync(Func<ShownObject, bool> shows)
    {
        var items = Tabs.TabItems.OfType<TabViewItem>()
            .Where(item => ShownBy(item.Content) is { } shown && shows(shown))
            .ToList();
        foreach (var item in items)
        {
            await _tabs.DiscardAsync(item).ConfigureAwait(true);
        }
    }

    // The table is gone, so its tabs close without asking about their changes, and none is kept to reopen.
    private async Task DiscardTabsAsync(Func<TableTabView, bool> shows)
    {
        var items = Tabs.TabItems.OfType<TabViewItem>()
            .Where(item => item.Content is TableTabView view && shows(view))
            .ToList();
        foreach (var item in items)
        {
            await _tabs.DiscardAsync(item).ConfigureAwait(true);
        }
    }
}
