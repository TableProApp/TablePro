using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using TablePro.App.Services;
using TablePro.Core.Browse;
using TablePro.Core.Compare;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Storage.Compare;

namespace TablePro.App.ViewModels;

/// <summary>One table of a multi-table comparison: whether it takes part, how it is scoped, and what it found.</summary>
public sealed partial class CompareTablePlan(ComparedTablePair pair, CompareTableScope scope, bool isIncluded) : ObservableObject
{
    public ComparedTablePair Pair { get; } = pair;

    public string DisplayName => Pair.DisplayName;

    /// <summary>Row identities left out of the sync, kept per table so drilling into another table keeps them.</summary>
    public HashSet<string> Excluded { get; } = new(StringComparer.Ordinal);

    [ObservableProperty]
    public partial bool IsIncluded { get; set; } = isIncluded;

    [ObservableProperty]
    public partial CompareTableScope Scope { get; set; } = scope;

    [ObservableProperty]
    public partial TableCompareOutcome? Outcome { get; set; }

    /// <summary>The run is reading this table now.</summary>
    [ObservableProperty]
    public partial bool IsComparing { get; set; }

    // A result read under another key, filter or column set answers a different question, so it goes.
    partial void OnScopeChanged(CompareTableScope value)
    {
        Outcome = null;
        Excluded.Clear();
    }
}

/// <summary>
/// Compare and Sync, as the macOS app's compare window has it: two endpoints on the same or different connections,
/// compared one table pair at a time, table by table across a chosen set or the whole schema, or structure against
/// structure. Every sync and migration goes through the review sheet. A setup can be saved as a profile and reopened.
/// </summary>
public sealed partial class CompareTabViewModel : TabViewModel
{
    /// <summary>Beyond this many tables a structure comparison costs too many catalog queries to run in one go.</summary>
    public const int MaxStructureTables = 500;

    /// <summary>The review sheet lists at most this many statements; the rest are counted.</summary>
    public const int MaxReviewedStatements = 1_000;

    private readonly WorkspaceContext _context;
    private readonly CompareEndpoints _endpoints;
    private readonly HashSet<string> _excluded = new(StringComparer.Ordinal);
    private readonly ObjectName? _startTable;
    private readonly DispatcherQueue _dispatcher;
    private CompareEndpoint? _source;
    private CompareEndpoint? _target;
    private CancellationTokenSource? _run;

    /// <param name="context">The source workspace, whose connection is the source until a profile names another.</param>
    /// <param name="endpoints">Opens the other side's session and holds the saved comparisons.</param>
    /// <param name="table">The table to start on, such as the one whose context menu opened the tab.</param>
    public CompareTabViewModel(WorkspaceContext context, CompareEndpoints endpoints, DatabaseObject? table = null)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(endpoints);
        _context = context;
        _endpoints = endpoints;
        _startTable = table?.Name;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        Title = Strings.Get("Compare/TabTitle");
        Subtitle = context.Session.Profile.Name;
        var profiles = endpoints.Profiles;
        Profiles = profiles.Any(p => p.Id == context.Session.Profile.Id) ? profiles : [context.Session.Profile, .. profiles];
        SourceProfile = context.Session.Profile;
        SourceSchemas = context.Session.Schemas;
        SourceSchema = context.Session.CurrentSchema;
        SourceTables = TablesOf(context.Session.Objects);
        SelectedSourceTable = table is not null ? SourceTables.FirstOrDefault(t => t.Name == table.Name) ?? table : SourceTables.Count > 0 ? SourceTables[0] : null;
        Scope = table is null ? DataCompareScope.ChosenTables : DataCompareScope.OneTable;
        TargetProfile = context.Session.Profile;
        SavedProfiles = endpoints.ProfileStore.Profiles;
        endpoints.ProfileStore.Changed += OnProfilesChanged;
        _ = LoadSavedProfilesAsync();
    }

    public override string Glyph => "\xE8AB";

    public WorkspaceContext Context => _context;

    public IReadOnlyList<ConnectionProfile> Profiles { get; }

    public ConnectionSession Source => _source?.Session ?? _context.Session;

    public ConnectionSession? Target => _target?.Session;

    /// <summary>Row identities left out of a one-table sync.</summary>
    public IReadOnlySet<string> Excluded => _excluded;

    [ObservableProperty]
    public partial CompareMode Mode { get; set; }

    [ObservableProperty]
    public partial DataCompareScope Scope { get; set; }

    [ObservableProperty]
    public partial ConnectionProfile SourceProfile { get; set; }

    [ObservableProperty]
    public partial IReadOnlyList<string> SourceSchemas { get; set; } = [];

    [ObservableProperty]
    public partial string? SourceSchema { get; set; }

    [ObservableProperty]
    public partial IReadOnlyList<DatabaseObject> SourceTables { get; set; }

    [ObservableProperty]
    public partial ConnectionProfile? TargetProfile { get; set; }

    [ObservableProperty]
    public partial IReadOnlyList<string> TargetSchemas { get; set; } = [];

    [ObservableProperty]
    public partial string? TargetSchema { get; set; }

    [ObservableProperty]
    public partial IReadOnlyList<DatabaseObject> TargetTables { get; set; } = [];

    [ObservableProperty]
    public partial DatabaseObject? SelectedSourceTable { get; set; }

    [ObservableProperty]
    public partial DatabaseObject? SelectedTargetTable { get; set; }

    /// <summary>The table pairs both sides share, for a chosen-tables or whole-schema comparison.</summary>
    [ObservableProperty]
    public partial IReadOnlyList<CompareTablePlan> TablePlans { get; set; } = [];

    /// <summary>The table whose rows the grid shows; null shows the per-table summary.</summary>
    [ObservableProperty]
    public partial CompareTablePlan? SelectedPlan { get; set; }

    /// <summary>Tables only one side has, which a data comparison cannot pair.</summary>
    [ObservableProperty]
    public partial string? UnpairedTables { get; set; }

    /// <summary>Comma-separated source columns that identify a row; empty uses the primary key.</summary>
    [ObservableProperty]
    public partial string KeyColumns { get; set; } = string.Empty;

    /// <summary>Comma-separated source columns left out of the comparison.</summary>
    [ObservableProperty]
    public partial string ExcludedColumns { get; set; } = string.Empty;

    [ObservableProperty]
    public partial string SourceWhere { get; set; } = string.Empty;

    [ObservableProperty]
    public partial string TargetWhere { get; set; } = string.Empty;

    [ObservableProperty]
    public partial bool InsertMissing { get; set; } = true;

    [ObservableProperty]
    public partial bool UpdateChanged { get; set; } = true;

    [ObservableProperty]
    public partial bool DeleteExtra { get; set; }

    [ObservableProperty]
    public partial bool KeysIgnoreCase { get; set; }

    [ObservableProperty]
    public partial double FloatTolerance { get; set; }

    /// <summary>Rows read from each side at most; NaN, as an empty NumberBox reports, reads everything.</summary>
    [ObservableProperty]
    public partial double RowLimit { get; set; } = double.NaN;

    /// <summary>Commit after every batch instead of once at the end.</summary>
    [ObservableProperty]
    public partial bool ApplyInBatches { get; set; }

    [ObservableProperty]
    public partial DataDiffResult? Result { get; set; }

    [ObservableProperty]
    public partial string? Summary { get; set; }

    /// <summary>What the comparison could not cover, such as columns only one side has.</summary>
    [ObservableProperty]
    public partial IReadOnlyList<string> Notes { get; set; } = [];

    [ObservableProperty]
    public partial IReadOnlyList<TableSchemaDiff> SchemaDiffs { get; set; } = [];

    [ObservableProperty]
    public partial bool DropExtraTables { get; set; }

    [ObservableProperty]
    public partial bool DropExtraColumns { get; set; }

    /// <summary>Every saved comparison, by name.</summary>
    [ObservableProperty]
    public partial IReadOnlyList<CompareProfile> SavedProfiles { get; set; }

    /// <summary>The saved comparison on screen, which Save updates rather than adding another.</summary>
    [ObservableProperty]
    public partial CompareProfile? ActiveProfile { get; set; }

    public bool IsRunning => _run is not null;

    public bool IsMultiTable => Mode == CompareMode.Data && Scope != DataCompareScope.OneTable;

    public DataCompareOptions Options => new()
    {
        InsertMissingRows = InsertMissing,
        UpdateChangedRows = UpdateChanged,
        DeleteExtraRows = DeleteExtra,
        KeysIgnoreCase = KeysIgnoreCase,
        FloatTolerance = Math.Max(0, FloatTolerance),
        RowLimit = GlobalRowLimit,
    };

    public SchemaCompareOptions SchemaOptions => SchemaCompareOptions.Default with { DropExtraTables = DropExtraTables, DropExtraColumns = DropExtraColumns };

    /// <summary>The plans a run compares: every pair under whole schema, the ticked ones otherwise.</summary>
    public IEnumerable<CompareTablePlan> ActivePlans => Scope == DataCompareScope.WholeSchema ? TablePlans : TablePlans.Where(p => p.IsIncluded);

    private long? GlobalRowLimit => double.IsNaN(RowLimit) || RowLimit < 1 ? null : (long)RowLimit;

    /// <summary>Opens the target connection picked and lists its tables, pairing them with the source's.</summary>
    /// <param name="reportErrors">False when the tab restores a remembered target, which says why in the status line rather than a dialog.</param>
    public async Task<bool> ConnectTargetAsync(bool reportErrors = true)
    {
        if (TargetProfile is not { } profile)
        {
            return false;
        }

        if (_target?.Profile.Id == profile.Id)
        {
            return true;
        }

        var opened = await OpenEndpointAsync(profile, reportErrors);
        if (opened is null)
        {
            return false;
        }

        if (_target is { } previous)
        {
            await previous.DisposeAsync();
        }

        _target = opened;
        TargetSchemas = opened.Session.Schemas;
        TargetSchema = opened.Session.CurrentSchema;
        TargetTables = TablesOf(opened.Session.Objects);
        MatchTargetTable();
        RebuildPlans();
        ClearResults();
        StatusText = Strings.Format("Compare/ComparingWith", profile.Name);
        return true;
    }

    /// <summary>Makes another saved connection the source, as loading a profile saved from another window does.</summary>
    public async Task<bool> ConnectSourceAsync(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (Source.Profile.Id == profile.Id)
        {
            return true;
        }

        var opened = await OpenEndpointAsync(profile);
        if (opened is null)
        {
            SourceProfile = Source.Profile;
            return false;
        }

        if (_source is { } previous && !ReferenceEquals(previous.Session, _target?.Session))
        {
            await previous.DisposeAsync();
        }

        _source = opened.Session == _context.Session ? null : opened;
        SourceProfile = profile;
        SourceSchemas = Source.Schemas;
        SourceSchema = Source.CurrentSchema;
        SourceTables = TablesOf(Source.Objects);
        SelectedSourceTable = SourceTables.Count > 0 ? SourceTables[0] : null;
        Subtitle = profile.Name;
        RebuildPlans();
        ClearResults();
        return true;
    }

    /// <summary>Reads a side's tables in another schema, without moving the workspace's own schema.</summary>
    public async Task SetSchemaAsync(bool target, string? schema)
    {
        var session = target ? Target : Source;
        if (session is null || string.Equals(schema, target ? TargetSchema : SourceSchema, StringComparison.Ordinal))
        {
            return;
        }

        IsBusy = true;
        try
        {
            var objects = string.Equals(schema, session.CurrentSchema, StringComparison.Ordinal)
                ? session.Objects
                : await session.Database.GetObjectsAsync(schema, CancellationToken.None);
            if (target)
            {
                TargetSchema = schema;
                TargetTables = TablesOf(objects);
                MatchTargetTable();
            }
            else
            {
                SourceSchema = schema;
                SourceTables = TablesOf(objects);
                SelectedSourceTable = SourceTables.Count > 0 ? SourceTables[0] : null;
                MatchTargetTable();
            }

            RebuildPlans();
            ClearResults();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            StatusText = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Selects the target table named like the source table, when the target has one.</summary>
    public void MatchTargetTable()
    {
        if (SelectedSourceTable is { } source)
        {
            SelectedTargetTable = TargetTables.FirstOrDefault(t => string.Equals(t.Name.Name, source.Name.Name, StringComparison.OrdinalIgnoreCase)) ?? SelectedTargetTable;
        }
    }

    public void Cancel() => _run?.Cancel();

    /// <summary>Runs whichever comparison the mode and scope ask for, and writes the setup down for the next tab.</summary>
    public async Task CompareAsync()
    {
        await (Mode == CompareMode.Structure ? CompareStructureAsync() : IsMultiTable ? CompareTablesAsync() : CompareDataAsync());
        RememberSetup();
    }

    public async Task CompareDataAsync()
    {
        if (!await ConnectTargetAsync())
        {
            return;
        }

        if (SelectedSourceTable is not { } sourceTable || SelectedTargetTable is not { } targetTable || _target is not { } target)
        {
            StatusText = Strings.Get("Compare/ChooseTables");
            return;
        }

        using var run = Begin();
        try
        {
            StatusText = Strings.Get("Compare/ReadingStructure");
            var sourceStructure = await Source.GetStructureAsync(sourceTable.Name, run.Token, refresh: true);
            var targetStructure = await target.Session.GetStructureAsync(targetTable.Name, run.Token, refresh: true);
            var setup = DataCompareSetup.Create(sourceStructure, targetStructure, SplitList(KeyColumns), SplitList(ExcludedColumns));
            Notes = SetupNotes(setup.SourceOnlyColumns, setup.TargetOnlyColumns);
            if (setup.Spec is not { } baseSpec)
            {
                StatusText = setup.Problem;
                return;
            }

            var spec = baseSpec with { SourceFilter = Filter(SourceWhere), TargetFilter = Filter(TargetWhere) };
            var options = Options;
            var source = Source.Database;
            var progress = new Progress<DataCompareProgress>(p =>
                StatusText = Strings.Plural("Compare/DataProgress", p.Differences, p.SourceRows, p.TargetRows));
            var result = await Task.Run(
                () => new DataDiffEngine(spec, options).CompareAsync(
                    SessionRowSource.Source(source, spec, options, run.Token),
                    SessionRowSource.Target(target.Session.Database, spec, options, run.Token),
                    progress,
                    run.Token),
                run.Token);

            _excluded.Clear();
            Result = result;
            Summary = Describe(result);
            StatusText = Strings.Format("Compare/ComparedIn", result.Elapsed.TotalSeconds);
        }
        catch (OperationCanceledException)
        {
            StatusText = Strings.Get("Compare/ComparisonStopped");
        }
        catch (Exception ex)
        {
            StatusText = ex.Message;
            if (ex is not CompareException)
            {
                CrashLog.Write("Compare data", ex);
            }

            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/CouldNotCompareTitle"), ex.Message);
        }
    }

    /// <summary>
    /// Compares every active table, one after another, filling each row's counts as it finishes. A table that cannot
    /// be compared says why on its own row and the run goes on, as on macOS.
    /// </summary>
    public async Task CompareTablesAsync()
    {
        if (!await ConnectTargetAsync() || _target is not { } target)
        {
            return;
        }

        var plans = ActivePlans.ToArray();
        if (plans.Length == 0)
        {
            StatusText = TablePlans.Count == 0 ? Strings.Get("Compare/NoSharedTables") : Strings.Get("Compare/NothingIncluded");
            return;
        }

        // The drilled-into rows belong to the answer this run replaces.
        SelectedPlan = null;
        using var run = Begin();
        var started = DateTime.UtcNow;
        // Structures are read from the driver sessions, not the workspace's cache: the run is on the thread pool, and
        // the cache raises CatalogChanged, which the workspace's UI handles on its own thread.
        var comparer = new MultiTableComparer(Source.Database, target.Session.Database, Options);

        try
        {
            for (var i = 0; i < plans.Length; i++)
            {
                var plan = plans[i];
                var index = i;
                plan.IsComparing = true;
                var progress = new Progress<DataCompareProgress>(p =>
                    StatusText = Strings.Format("Compare/TablesProgress", index + 1, plans.Length, plan.DisplayName, p.SourceRows + p.TargetRows));
                StatusText = Strings.Format("Compare/TablesProgress", index + 1, plans.Length, plan.DisplayName, 0);
                var request = new TableCompareRequest(plan.Pair, plan.Scope);
                try
                {
                    var outcome = await Task.Run(() => comparer.CompareAsync(request, progress, run.Token), run.Token);
                    plan.Excluded.Clear();
                    plan.Outcome = outcome;
                }
                finally
                {
                    plan.IsComparing = false;
                }
            }

            SummarizeTables();
            StatusText = Strings.Format("Compare/ComparedIn", (DateTime.UtcNow - started).TotalSeconds);
        }
        catch (OperationCanceledException)
        {
            SummarizeTables();
            StatusText = Strings.Get("Compare/ComparisonStopped");
        }
    }

    /// <summary>Ticks or unticks every pair, or the given ones.</summary>
    public void SetIncluded(bool included, IEnumerable<CompareTablePlan>? plans = null)
    {
        foreach (var plan in plans ?? TablePlans)
        {
            plan.IsIncluded = included;
        }
    }

    /// <summary>Leaves rows out of the sync, or puts them back when every one was already left out.</summary>
    public void ToggleExcluded(IEnumerable<RowDiff> rows)
    {
        var (result, excluded) = SelectedPlan is { Outcome.Result: { } planResult } plan ? (planResult, plan.Excluded) : (Result, _excluded);
        if (result is null)
        {
            return;
        }

        var keys = rows.Select(r => result.Spec.KeyIdentity(r.KeyRow)).ToArray();
        if (keys.All(excluded.Contains))
        {
            excluded.ExceptWith(keys);
        }
        else
        {
            excluded.UnionWith(keys);
        }
    }

    /// <summary>Reviews the sync statements, then runs them against the target.</summary>
    public Task SyncAsync() => IsMultiTable ? SyncTablesAsync() : SyncTableAsync();

    /// <summary>The sync script as text, for copying or saving.</summary>
    public string? SyncScript()
    {
        if (_target is not { } target)
        {
            return null;
        }

        try
        {
            IReadOnlyList<string> statements = IsMultiTable
                ? BuildCombinedPlan().Preview(target.Session.Database)
                : Result is { } result ? DataSyncPlan.Build(result, Options, _excluded).Preview(target.Session.Database) : [];
            return statements.Count == 0 ? null : string.Join(";\n", statements) + ";";
        }
        catch (CompareException ex)
        {
            StatusText = ex.Message;
            return null;
        }
    }

    public async Task CompareStructureAsync()
    {
        if (!await ConnectTargetAsync() || _target is not { } target)
        {
            return;
        }

        using var run = Begin();
        try
        {
            var source = await LoadStructuresAsync(Source, SourceTables, isTarget: false, run.Token);
            var targetStructures = await LoadStructuresAsync(target.Session, TargetTables, isTarget: true, run.Token);
            var diffs = SchemaDiffEngine.Compare(source, targetStructures, SchemaOptions);
            SchemaDiffs = diffs;
            var changed = diffs.Count(d => d.Kind != SchemaDiffKind.Identical);
            Summary = Strings.Format(
                "Compare/DiffSummary",
                diffs.Count(d => d.Kind == SchemaDiffKind.OnlyInSource),
                diffs.Count(d => d.Kind == SchemaDiffKind.OnlyInTarget),
                diffs.Count(d => d.Kind == SchemaDiffKind.Changed),
                diffs.Count(d => d.Kind == SchemaDiffKind.Identical));
            StatusText = changed == 0 ? Strings.Get("Compare/StructuresMatch") : Strings.Plural("Compare/TablesDiffer", changed);
        }
        catch (OperationCanceledException)
        {
            StatusText = Strings.Get("Compare/ComparisonStopped");
        }
        catch (Exception ex)
        {
            CrashLog.Write("Compare structure", ex);
            StatusText = ex.Message;
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/CouldNotCompareStructureTitle"), ex.Message);
        }
    }

    /// <summary>The migration DDL for the target's engine, or null when it cannot change structure from the app.</summary>
    public MigrationScript? BuildMigration() =>
        Target?.Database is ISchemaDdlProvider ddl ? SchemaMigrationBuilder.Build(SchemaDiffs, ddl, TargetSchema ?? Target.CurrentSchema, SchemaOptions) : null;

    /// <summary>Reviews the migration, then runs it on the target one statement at a time, stopping at the first error.</summary>
    public async Task MigrateAsync()
    {
        if (_target is not { } target)
        {
            return;
        }

        if (target.Profile.IsReadOnly || BuildMigration() is not { } script)
        {
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/CannotMigrateTitle"), Strings.Format("Compare/CannotMigrateMessage", target.Profile.Name));
            return;
        }

        if (script.Statements.Count == 0)
        {
            await _context.Dialogs.ShowErrorAsync(
                Strings.Get("Compare/NothingToMigrateTitle"),
                script.Unsupported.Count > 0 ? Strings.Format("Compare/TargetCannotExpress", string.Join("; ", script.Unsupported)) : Strings.Get("Compare/StructuresAlreadyMatch"));
            return;
        }

        var notes = new List<string>();
        if (script.Statements.Any(s => s.IsDestructive))
        {
            notes.Add(Strings.Get("Compare/DestructiveNote"));
        }

        notes.AddRange(script.Unsupported.Select(u => Strings.Format("Compare/NotScripted", u)));
        notes.AddRange(SchemaDiffs.SelectMany(d => d.Notes.Select(n => $"{d.Name}: {n}")));
        if (!await _context.Dialogs.ReviewSqlAsync(Strings.Format("Compare/MigrateReviewTitle", target.Profile.Name), Reviewed([.. script.Statements.Select(s => s.Sql)], notes, target.Session.Dialect), Strings.Get("Compare/MigrateButton")))
        {
            return;
        }

        using var run = Begin();
        var ran = 0;
        try
        {
            await using var channel = await target.Session.Database.OpenChannelAsync(run.Token);
            await foreach (var result in channel.ExecuteAsync([.. script.Statements.Select(s => s.Sql)], new ExecuteOptions(StopOnError: true), run.Token))
            {
                _context.History.Record(target.Profile, target.Session.Database.CurrentDatabase, result, StatementKind.Ddl, "sync");
                if (!result.Succeeded)
                {
                    await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/MigrationStoppedTitle"), Strings.Plural("Compare/MigrationStoppedMessage", ran, result.Error));
                    break;
                }

                ran++;
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/MigrationStoppedTitle"), ex.Message);
        }
        finally
        {
            await target.Session.RefreshAsync(CancellationToken.None);
            await ReloadTablesAsync(target.Session);
            if (ReferenceEquals(target.Session, _context.Session))
            {
                _context.NotifySchemaChanged();
            }
        }

        if (ran == script.Statements.Count)
        {
            _context.Notify(Strings.Plural("Compare/Migrated", ran, target.Profile.Name));
            await CompareStructureAsync();
        }
    }

    public string? MigrationText() => BuildMigration() is { Statements.Count: > 0 } script ? string.Join(";\n", script.Statements.Select(s => s.Sql)) + ";" : null;

    public override async ValueTask DisposeAsync()
    {
        _run?.Cancel();
        RememberSetup();
        _endpoints.ProfileStore.Changed -= OnProfilesChanged;
        if (_target is { } target)
        {
            await target.DisposeAsync();
        }

        if (_source is { } source && !ReferenceEquals(source.Session, _target?.Session))
        {
            await source.DisposeAsync();
        }

        await base.DisposeAsync();
    }

    private static IReadOnlyList<DatabaseObject> TablesOf(IEnumerable<DatabaseObject> objects) =>
        [.. objects.Where(o => o.Kind == ObjectKind.Table).OrderBy(o => o.Name.Name, StringComparer.OrdinalIgnoreCase)];

    private static async Task<IReadOnlyList<DatabaseObject>> ObjectsInAsync(ConnectionSession session, string? schema) =>
        string.Equals(schema, session.CurrentSchema, StringComparison.Ordinal) ? session.Objects : await session.Database.GetObjectsAsync(schema, CancellationToken.None);

    /// <summary>Lists the tables again after a migration changed them, on whichever sides share the migrated session.</summary>
    private async Task ReloadTablesAsync(ConnectionSession migrated)
    {
        try
        {
            TargetTables = TablesOf(await ObjectsInAsync(migrated, TargetSchema));
            if (ReferenceEquals(migrated, Source))
            {
                SourceTables = TablesOf(await ObjectsInAsync(migrated, SourceSchema));
            }

            RebuildPlans();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            StatusText = ex.Message;
        }
    }

    private static string Describe(DataDiffResult result)
    {
        var text = Strings.Format("Compare/DiffSummary", result.OnlyInSourceCount, result.OnlyInTargetCount, result.ChangedCount, result.IdenticalCount);
        if (result.SkippedNullKeyCount > 0)
        {
            text += " · " + Strings.Plural("Compare/SkippedNullKey", result.SkippedNullKeyCount);
        }

        if (result.StoppedAtRowLimit)
        {
            text += " · " + Strings.Get("Compare/StoppedAtRowLimit");
        }

        if (result.IsTruncated)
        {
            text += " · " + Strings.Plural("Compare/ShowingFirstDifferences", result.Differences.Count);
        }

        return text;
    }

    private static List<string> SetupNotes(IReadOnlyList<string> sourceOnly, IReadOnlyList<string> targetOnly)
    {
        var notes = new List<string>();
        if (sourceOnly.Count > 0)
        {
            notes.Add(Strings.Format("Compare/SourceOnlyColumns", string.Join(", ", sourceOnly)));
        }

        if (targetOnly.Count > 0)
        {
            notes.Add(Strings.Format("Compare/TargetOnlyColumns", string.Join(", ", targetOnly)));
        }

        return notes;
    }

    private static string[] SplitList(string text) => text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);

    private static BrowseFilter Filter(string where) => string.IsNullOrWhiteSpace(where) ? BrowseFilter.None : new BrowseFilter([], where.Trim());

    /// <summary>The statements for the review sheet, capped, with the notes as comments first.</summary>
    private static List<string> Reviewed(IReadOnlyList<string> statements, IReadOnlyList<string> notes, SqlDialect dialect)
    {
        var lines = new List<string>(Math.Min(statements.Count, MaxReviewedStatements) + notes.Count + 1);
        lines.AddRange(notes.Select(n => $"{dialect.LineComment} {n}"));
        lines.AddRange(statements.Take(MaxReviewedStatements));
        if (statements.Count > MaxReviewedStatements)
        {
            lines.Add(Strings.Plural("Compare/MoreStatements", statements.Count - MaxReviewedStatements, dialect.LineComment));
        }

        return lines;
    }

    private async Task<CompareEndpoint?> OpenEndpointAsync(ConnectionProfile profile, bool reportErrors = true)
    {
        IsBusy = true;
        StatusText = Strings.Format("Compare/ConnectingTo", profile.Name);
        try
        {
            var opened = await _endpoints.OpenAsync(profile, _context.Session, CancellationToken.None);
            StatusText = null;
            return opened;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            CrashLog.Write($"Compare: connect to {profile.Name}", ex);
            StatusText = ex.Message;
            if (reportErrors)
            {
                await _context.Dialogs.ShowErrorAsync(Strings.Format("Compare/CouldNotConnectTitle", profile.Name), ex.Message);
            }

            return null;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task SyncTableAsync()
    {
        if (Result is not { } result || _target is not { } target)
        {
            return;
        }

        if (!await CheckWritableAsync(target))
        {
            return;
        }

        DataSyncPlan plan;
        try
        {
            plan = DataSyncPlan.Build(result, Options, _excluded);
        }
        catch (CompareException ex)
        {
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/CannotSyncTitle"), ex.Message);
            return;
        }

        if (plan.IsEmpty)
        {
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/NothingToSyncTitle"), Strings.Get("Compare/NothingToSyncMessage"));
            return;
        }

        var preview = plan.Preview(target.Session.Database);
        var batches = ApplyInBatches || plan.Steps.Count > DataSyncApplyOptions.SuggestedSingleTransactionLimit;
        var notes = new List<string>(plan.Warnings);
        AddTransactionNotes(notes, target, batches, tablesCommitApart: false);
        var nonTransactional = await NonTransactionalTablesAsync(target, [plan.Table], notes);

        var title = Strings.Format("Compare/SyncReviewTitle", plan.Table, plan.InsertCount, plan.UpdateCount, plan.DeleteCount);
        if (!await _context.Dialogs.ReviewSqlAsync(title, Reviewed(preview, notes, target.Session.Dialect), Strings.Get("Compare/SyncButton")))
        {
            return;
        }

        DataSyncApplyResult applied;
        var started = DateTime.UtcNow;
        using (var run = Begin())
        {
            var progress = new Progress<DataSyncProgress>(p => StatusText = Strings.Format("Compare/SyncProgress", p.Applied, p.Total));
            applied = await DataSyncApplier.ApplyAsync(target.Session.Database, plan, new DataSyncApplyOptions(SingleTransaction: !batches), progress, run.Token);
        }

        RecordHistory(target, preview, applied, DateTime.UtcNow - started);
        if (!await ReportFailureAsync(applied, batches, nonTransactional))
        {
            return;
        }

        _context.Notify(Strings.Plural("Compare/Synced", applied.RowsAffected, plan.Table));
        await CompareDataAsync();
    }

    /// <summary>Reviews one script for every compared table, ordered by foreign keys, then runs it against the target.</summary>
    private async Task SyncTablesAsync()
    {
        if (_target is not { } target)
        {
            return;
        }

        if (!await CheckWritableAsync(target))
        {
            return;
        }

        var plan = BuildCombinedPlan();
        if (plan.IsEmpty)
        {
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/NothingToSyncTitle"), Strings.Get("Compare/NothingToSyncTablesMessage"));
            return;
        }

        var preview = plan.Preview(target.Session.Database);
        var batches = ApplyInBatches || plan.StepCount > DataSyncApplyOptions.SuggestedSingleTransactionLimit;
        var notes = new List<string>(plan.Warnings);

        // A session without cross-table transactions commits each table's segment apart, which the sheet says first.
        var tablesCommitApart = plan.Segments.Count > 1 && ChangeTransactions.For(target.Session.Database) is null;
        AddTransactionNotes(notes, target, batches, tablesCommitApart);
        var nonTransactional = await NonTransactionalTablesAsync(target, plan.Tables.Select(t => t.Table), notes);
        var title = Strings.Format("Compare/SyncTablesReviewTitle", plan.Tables.Count, plan.InsertCount, plan.UpdateCount, plan.DeleteCount);
        if (!await _context.Dialogs.ReviewSqlAsync(title, Reviewed(preview, notes, target.Session.Dialect), Strings.Get("Compare/SyncButton")))
        {
            return;
        }

        DataSyncApplyResult applied;
        var started = DateTime.UtcNow;
        using (var run = Begin())
        {
            var progress = new Progress<DataSyncProgress>(p => StatusText = Strings.Format("Compare/SyncProgress", p.Applied, p.Total));
            applied = await DataSyncApplier.ApplyAsync(target.Session.Database, plan, new DataSyncApplyOptions(SingleTransaction: !batches), progress, run.Token);
        }

        RecordHistory(target, preview, applied, DateTime.UtcNow - started);
        var succeeded = await ReportFailureAsync(applied, batches || tablesCommitApart, nonTransactional);
        if (succeeded)
        {
            _context.Notify(Strings.Plural("Compare/SyncedTables", applied.RowsAffected, plan.Tables.Count));
        }

        // Compared again either way: after a partial sync the counts on screen no longer say what the target holds.
        await CompareTablesAsync();
    }

    private CombinedSyncPlan BuildCombinedPlan() => CombinedSyncPlan.Build(
        [.. ActivePlans.Where(p => p.Outcome is { State: TableCompareState.Compared, Result: not null })
            .Select(p => new CombinedSyncInput(p.Outcome!.Result!, p.Excluded, p.Outcome.SourceStructure))],
        Options);

    private async Task<bool> CheckWritableAsync(CompareEndpoint target)
    {
        if (!target.Profile.IsReadOnly)
        {
            return true;
        }

        await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/ReadOnlyTargetTitle"), Strings.Format("Compare/ReadOnlyTargetMessage", target.Profile.Name));
        return false;
    }

    private static void AddTransactionNotes(List<string> notes, CompareEndpoint target, bool batches, bool tablesCommitApart)
    {
        if (!DataSyncTransactionality.CanRollBack(target.Profile.Engine))
        {
            notes.Add(Strings.Format("Compare/CannotRollBackNote", target.Profile.Descriptor.DisplayName));
        }
        else if (batches)
        {
            notes.Add(Strings.Get("Compare/BatchesCommitNote"));
        }
        else if (tablesCommitApart)
        {
            notes.Add(Strings.Get("Compare/TablesCommitNote"));
        }
    }

    /// <summary>
    /// Names the tables whose storage engine ignores ROLLBACK (MyISAM and the like) in the review notes, as the macOS app
    /// names them after a failed run. The catalog read is a warning, not a gate: when it fails the review goes on
    /// without the note.
    /// </summary>
    private async Task<IReadOnlyList<NonTransactionalTable>> NonTransactionalTablesAsync(CompareEndpoint target, IEnumerable<ObjectName> tables, List<string> notes)
    {
        IReadOnlyList<NonTransactionalTable> found;
        try
        {
            found = await DataSyncTransactionality.NonTransactionalTablesAsync(target.Session.Database, tables, CancellationToken.None);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            CrashLog.Write("Compare: read storage engines", ex);
            return [];
        }

        if (DataSyncTransactionality.ReviewNote(found) is { } note)
        {
            notes.Insert(0, note);
        }

        return found;
    }

    private void RecordHistory(CompareEndpoint target, IReadOnlyList<string> preview, DataSyncApplyResult applied, TimeSpan elapsed)
    {
        foreach (var statement in preview.Take(applied.AppliedSteps).Take(MaxReviewedStatements))
        {
            _context.History.Record(target.Profile, target.Session.Database.CurrentDatabase, new StatementResult(statement, [], 1, elapsed), StatementKind.Write, "sync");
        }
    }

    /// <summary>Tells the user how far a failed sync got. Returns true when it did not fail.</summary>
    private async Task<bool> ReportFailureAsync(DataSyncApplyResult applied, bool partsCommit, IReadOnlyList<NonTransactionalTable> nonTransactional)
    {
        if (applied.Error is not { } error)
        {
            return true;
        }

        StatusText = error.Message;
        var message = applied.CommittedBatches > 0 && partsCommit
            ? Strings.Plural("Compare/SyncStoppedBatchesKept", applied.CommittedBatches, error.Message, applied.TotalBatches)
            : DataSyncTransactionality.RollbackLeftWritesNote(nonTransactional, applied.WrittenTables) is { } kept
                ? $"{error.Message} {kept}"
                : Strings.Format("Compare/SyncStoppedNothingChanged", error.Message);
        await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/SyncStoppedTitle"), message);
        return false;
    }

    /// <summary>
    /// Pairs the two sides' tables, keeping each pair's scope, tick and answer when it was there before, and placing
    /// <paramref name="saved"/> pairs (from a profile) first so a table renamed on the target still pairs.
    /// </summary>
    private void RebuildPlans(IReadOnlyList<CompareProfileTable>? saved = null, bool savedOnly = false)
    {
        var previous = TablePlans.ToDictionary(p => PlanKey(p.Pair.Source), StringComparer.OrdinalIgnoreCase);
        var sources = SourceTables.Select(t => t.Name).ToList();
        var targets = TargetTables.Select(t => t.Name).ToList();
        var plans = new List<CompareTablePlan>();
        var savedBySource = new Dictionary<string, CompareProfileTable>(StringComparer.OrdinalIgnoreCase);

        foreach (var table in saved ?? [])
        {
            savedBySource.TryAdd(table.Source, table);
            var source = sources.FindIndex(s => string.Equals(s.Name, table.Source, StringComparison.OrdinalIgnoreCase));
            var target = targets.FindIndex(t => string.Equals(t.Name, table.Target, StringComparison.OrdinalIgnoreCase));
            if (source >= 0 && target >= 0 && !string.Equals(table.Source, table.Target, StringComparison.OrdinalIgnoreCase))
            {
                plans.Add(new CompareTablePlan(new ComparedTablePair(sources[source], targets[target]), table.Scope, table.IsIncluded));
                sources.RemoveAt(source);
                targets.RemoveAt(target);
            }
        }

        var pairing = TablePairing.Match(sources, targets);
        foreach (var pair in pairing.Pairs)
        {
            if (savedBySource.TryGetValue(pair.Source.Name, out var table))
            {
                plans.Add(new CompareTablePlan(pair, table.Scope, table.IsIncluded));
            }
            else if (saved is not null && savedOnly)
            {
                plans.Add(new CompareTablePlan(pair, CompareTableScope.Default, isIncluded: false));
            }
            else if (previous.TryGetValue(PlanKey(pair.Source), out var kept) && kept.Pair == pair)
            {
                plans.Add(kept);
            }
            else
            {
                // A new pair starts unticked, as on macOS, so a first Compare cannot stream every table's rows before
                // the user chose any; the table the tab was opened for is the exception.
                var included = _startTable == pair.Source;
                plans.Add(new CompareTablePlan(pair, CompareTableScope.Default, included));
            }
        }

        plans.Sort((a, b) => StringComparer.OrdinalIgnoreCase.Compare(a.DisplayName, b.DisplayName));
        SelectedPlan = null;
        TablePlans = plans;
        var unpaired = pairing.SourceOnly.Select(t => Strings.Format("Compare/OnlyInSourceTable", t)).Concat(pairing.TargetOnly.Select(t => Strings.Format("Compare/OnlyInTargetTable", t))).ToArray();
        UnpairedTables = unpaired.Length == 0 ? null : string.Join(", ", unpaired);
    }

    private static string PlanKey(ObjectName name) => name.ToString();

    private void SummarizeTables()
    {
        var compared = TablePlans.Where(p => p.Outcome is { State: TableCompareState.Compared }).Select(p => p.Outcome!.Result!).ToArray();
        var problems = TablePlans.Count(p => p.Outcome is { State: not TableCompareState.Compared });
        Summary = compared.Length == 0 && problems == 0
            ? null
            : Strings.Format(
                "Compare/TablesSummary",
                compared.Length,
                compared.Sum(r => r.OnlyInSourceCount),
                compared.Sum(r => r.ChangedCount),
                compared.Sum(r => r.OnlyInTargetCount),
                compared.Count(r => r.DifferenceCount == 0))
              + (problems > 0 ? " · " + Strings.Plural("Compare/TablesWithProblems", problems) : string.Empty);
        Notes = [.. TablePlans
            .Where(p => p.Outcome is { State: TableCompareState.Compared } && (p.Outcome.SourceOnlyColumns.Count > 0 || p.Outcome.TargetOnlyColumns.Count > 0))
            .Select(p => $"{p.DisplayName}: {string.Join(" ", SetupNotes(p.Outcome!.SourceOnlyColumns, p.Outcome.TargetOnlyColumns))}")];
    }

    private async Task<List<TableStructure>> LoadStructuresAsync(ConnectionSession session, IReadOnlyList<DatabaseObject> objects, bool isTarget, CancellationToken cancellationToken)
    {
        var tables = objects.Take(MaxStructureTables).ToArray();
        var structures = new List<TableStructure>(tables.Length);
        foreach (var table in tables)
        {
            cancellationToken.ThrowIfCancellationRequested();
            structures.Add(await session.GetStructureAsync(table.Name, cancellationToken, refresh: true));
            StatusText = isTarget
                ? Strings.Format("Compare/ReadingTargetStructure", structures.Count, tables.Length)
                : Strings.Format("Compare/ReadingSourceStructure", structures.Count, tables.Length);
        }

        return structures;
    }

    private void ClearResults()
    {
        Result = null;
        SchemaDiffs = [];
        Summary = null;
        Notes = [];
        _excluded.Clear();
        foreach (var plan in TablePlans)
        {
            plan.Outcome = null;
            plan.Excluded.Clear();
        }
    }

    partial void OnScopeChanged(DataCompareScope value)
    {
        SelectedPlan = null;
        OnPropertyChanged(nameof(IsMultiTable));
    }

    partial void OnModeChanged(CompareMode value) => OnPropertyChanged(nameof(IsMultiTable));

    private RunScope Begin()
    {
        _run?.Cancel();
        var run = new CancellationTokenSource();
        _run = run;
        IsBusy = true;
        OnPropertyChanged(nameof(IsRunning));
        return new RunScope(this, run);
    }

    /// <summary>Ends a run: the busy state clears only if no newer run replaced this one.</summary>
    private sealed class RunScope(CompareTabViewModel owner, CancellationTokenSource source) : IDisposable
    {
        public CancellationToken Token => source.Token;

        public void Dispose()
        {
            if (ReferenceEquals(owner._run, source))
            {
                owner._run = null;
                owner.IsBusy = false;
                owner.OnPropertyChanged(nameof(IsRunning));
            }

            source.Dispose();
        }
    }
}
