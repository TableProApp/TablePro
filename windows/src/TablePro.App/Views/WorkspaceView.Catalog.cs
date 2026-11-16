using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// Emptying and dropping a table, and making and dropping a schema or database: asked, planned by the core, run at once
// through Safe Mode, then the tree and the tabs follow (core/docs/decisions/0013-catalog-operations.md).
public sealed partial class WorkspaceView
{
    // Read-only, by the connection or its Safe Mode, offers none of them.
    private CatalogAbilities Abilities =>
        _session is { IsReadOnly: false } session ? session.CatalogAbilities : CatalogAbilities.None;

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
        var choices = abilities.SchemaOwner ? await ChoicesAsync(session).ConfigureAwait(true) : DatabaseChoices.None;
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
        if (CreatedName(change) is { } name && ReferenceEquals(_session, session))
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
        using var change = await CatalogDialogs.AskTruncateAsync(this, session, table, abilities, clusters).ConfigureAwait(true);
        if (change is null || !await RunCatalogChangeAsync(session, change, "TruncateFailed").ConfigureAwait(true))
        {
            return;
        }

        // A cascade empties the tables pointing at this one, and a partitioned table its partitions, so every table tab
        // reads again; one holding edits asks first.
        foreach (var view in TableViews())
        {
            if (TableViews().Contains(view))
            {
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
        await DiscardGoneTabsAsync(session).ConfigureAwait(true);
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

        await DiscardTabsAsync(view => string.Equals(view.Model.Table.Schema, schema, StringComparison.Ordinal))
            .ConfigureAwait(true);
        _workbench.TableFilters.ForgetSchema(FilterConnection, session.Database, schema);
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
            await DiscardTabsAsync(view => string.Equals(view.Model.Table.Schema, database, StringComparison.Ordinal))
                .ConfigureAwait(true);
            _workbench.TableFilters.ForgetSchema(FilterConnection, session.Database, database);
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

        CatalogChangeOutcome outcome;
        try
        {
            outcome = await change.RunAsync(confirmed: true).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            await CatalogDialogs.ShowRefusedAsync(this, Strings.Get(failedTitle), Strings.Error(exception.Error))
                .ConfigureAwait(true);
            return false;
        }
        catch (OperationCanceledException)
        {
            return false;
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
                if (ReferenceEquals(_session, session))
                {
                    await RefreshAsync().ConfigureAwait(true);
                }

                return false;
            default:
                return ReferenceEquals(_session, session);
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
        catch (TableProException)
        {
            return [];
        }
    }

    // A server that lists none leaves every picker with only its own default.
    private static async Task<DatabaseChoices> ChoicesAsync(DatabaseSession session)
    {
        try
        {
            return await session.GetDatabaseChoicesAsync().ConfigureAwait(true);
        }
        catch (TableProException)
        {
            return DatabaseChoices.None;
        }
    }

    private List<TableTabView> TableViews() =>
        [.. Tabs.TabItems.OfType<TabViewItem>().Select(item => item.Content).OfType<TableTabView>()];

    // The objects of each schema a table tab shows, read again; a schema that cannot be read closes nothing.
    private async Task DiscardGoneTabsAsync(DatabaseSession session)
    {
        HashSet<(string? Schema, string Name)> gone = [];
        foreach (var schema in TableViews().Select(view => view.Model.Table.Schema).Distinct())
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

            foreach (var view in TableViews().Where(view => view.Model.Table.Schema == schema))
            {
                var table = view.Model.Table;
                // A tab opened from the tree and one restored can spell the default schema apart, so a name with no
                // schema on either side is the same object.
                if (!objects.Any(entry => entry.Name == table.Name
                    && (entry.Schema is null || schema is null || entry.Schema == schema)))
                {
                    gone.Add((table.Schema, table.Name));
                }
            }
        }

        foreach (var (schema, name) in gone)
        {
            _workbench.TableFilters.ForgetTable(FilterConnection, session.Database, new TableName(schema, name));
        }

        await DiscardTabsAsync(view => gone.Contains((view.Model.Table.Schema, view.Model.Table.Name))).ConfigureAwait(true);
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
