using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using TablePro.App.Services;
using TablePro.Core.Browse;
using TablePro.Core.Compare;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.App.ViewModels;

public enum CompareMode
{
    Data,
    Structure,
}

/// <summary>
/// Compare and Sync, as the macOS app's compare window has it: two tables on the same or different connections
/// compared row by row and synced with reviewed INSERT, UPDATE and DELETE statements, or two schemas compared table by
/// table and migrated with reviewed DDL. The workspace's own connection is always the source.
/// </summary>
public sealed partial class CompareTabViewModel : TabViewModel
{
    /// <summary>Beyond this many tables a structure comparison costs too many catalog queries to run in one go.</summary>
    public const int MaxStructureTables = 500;

    /// <summary>The review sheet lists at most this many statements; the rest are counted.</summary>
    public const int MaxReviewedStatements = 1_000;

    private readonly WorkspaceContext _context;
    private readonly Func<ConnectionProfile, CancellationToken, Task<CompareEndpoint?>> _open;
    private readonly HashSet<string> _excluded = new(StringComparer.Ordinal);
    private CompareEndpoint? _target;
    private CancellationTokenSource? _run;

    /// <param name="context">The source workspace.</param>
    /// <param name="profiles">The saved connections a target can be picked from.</param>
    /// <param name="open">Finds or opens the session for a target connection; null when the user cancelled a prompt.</param>
    /// <param name="table">The table to start on, such as the one whose context menu opened the tab.</param>
    public CompareTabViewModel(
        WorkspaceContext context,
        IReadOnlyList<ConnectionProfile> profiles,
        Func<ConnectionProfile, CancellationToken, Task<CompareEndpoint?>> open,
        DatabaseObject? table = null)
    {
        ArgumentNullException.ThrowIfNull(context);
        _context = context;
        _open = open;
        Title = "Compare";
        Subtitle = context.Session.Profile.Name;
        Profiles = profiles.Any(p => p.Id == context.Session.Profile.Id) ? profiles : [context.Session.Profile, .. profiles];
        SourceTables = [.. context.Session.Objects.Where(o => o.Kind == ObjectKind.Table).OrderBy(o => o.Name.Name, StringComparer.OrdinalIgnoreCase)];
        SelectedSourceTable = table is not null ? SourceTables.FirstOrDefault(t => t.Name == table.Name) ?? table : SourceTables.Count > 0 ? SourceTables[0] : null;
        TargetProfile = context.Session.Profile;
    }

    public override string Glyph => "";

    public WorkspaceContext Context => _context;

    public IReadOnlyList<ConnectionProfile> Profiles { get; }

    public IReadOnlyList<DatabaseObject> SourceTables { get; }

    public ConnectionSession Source => _context.Session;

    public ConnectionSession? Target => _target?.Session;

    /// <summary>Row identities left out of the sync.</summary>
    public IReadOnlySet<string> Excluded => _excluded;

    [ObservableProperty]
    public partial CompareMode Mode { get; set; }

    [ObservableProperty]
    public partial ConnectionProfile? TargetProfile { get; set; }

    [ObservableProperty]
    public partial IReadOnlyList<DatabaseObject> TargetTables { get; set; } = [];

    [ObservableProperty]
    public partial DatabaseObject? SelectedSourceTable { get; set; }

    [ObservableProperty]
    public partial DatabaseObject? SelectedTargetTable { get; set; }

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

    public bool IsRunning => _run is not null;

    public DataCompareOptions Options => new()
    {
        InsertMissingRows = InsertMissing,
        UpdateChangedRows = UpdateChanged,
        DeleteExtraRows = DeleteExtra,
        KeysIgnoreCase = KeysIgnoreCase,
        FloatTolerance = Math.Max(0, FloatTolerance),
        RowLimit = double.IsNaN(RowLimit) || RowLimit < 1 ? null : (long)RowLimit,
    };

    public SchemaCompareOptions SchemaOptions => SchemaCompareOptions.Default with { DropExtraTables = DropExtraTables, DropExtraColumns = DropExtraColumns };

    /// <summary>Opens the target connection picked, and lists its tables with the source's table selected when it has one.</summary>
    public async Task<bool> ConnectTargetAsync()
    {
        if (TargetProfile is not { } profile)
        {
            return false;
        }

        if (_target?.Profile.Id == profile.Id)
        {
            return true;
        }

        IsBusy = true;
        StatusText = $"Connecting to {profile.Name}…";
        try
        {
            var opened = await _open(profile, CancellationToken.None);
            if (opened is null)
            {
                StatusText = null;
                return false;
            }

            if (_target is { } previous)
            {
                await previous.DisposeAsync();
            }

            _target = opened;
            TargetTables = [.. opened.Session.Objects.Where(o => o.Kind == ObjectKind.Table).OrderBy(o => o.Name.Name, StringComparer.OrdinalIgnoreCase)];
            MatchTargetTable();
            ClearResults();
            StatusText = $"Comparing with {profile.Name}";
            return true;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            CrashLog.Write($"Compare: connect to {profile.Name}", ex);
            StatusText = ex.Message;
            await _context.Dialogs.ShowErrorAsync($"Could not connect to {profile.Name}", ex.Message);
            return false;
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

    public async Task CompareDataAsync()
    {
        if (!await ConnectTargetAsync())
        {
            return;
        }

        if (SelectedSourceTable is not { } sourceTable || SelectedTargetTable is not { } targetTable || _target is not { } target)
        {
            StatusText = "Choose a table on both sides.";
            return;
        }

        using var run = Begin();
        try
        {
            StatusText = "Reading structure…";
            var sourceStructure = await Source.GetStructureAsync(sourceTable.Name, run.Token, refresh: true);
            var targetStructure = await target.Session.GetStructureAsync(targetTable.Name, run.Token, refresh: true);
            var setup = DataCompareSetup.Create(sourceStructure, targetStructure, SplitList(KeyColumns), SplitList(ExcludedColumns));
            Notes = SetupNotes(setup);
            if (setup.Spec is not { } baseSpec)
            {
                StatusText = setup.Problem;
                return;
            }

            var spec = baseSpec with { SourceFilter = Filter(SourceWhere), TargetFilter = Filter(TargetWhere) };
            var options = Options;
            var progress = new Progress<DataCompareProgress>(p =>
                StatusText = string.Create(CultureInfo.CurrentCulture, $"Compared {p.SourceRows:N0} source and {p.TargetRows:N0} target rows, {p.Differences:N0} differences…"));
            var result = await Task.Run(
                () => new DataDiffEngine(spec, options).CompareAsync(
                    SessionRowSource.Source(Source.Database, spec, options, run.Token),
                    SessionRowSource.Target(target.Session.Database, spec, options, run.Token),
                    progress,
                    run.Token),
                run.Token);

            _excluded.Clear();
            Result = result;
            Summary = Describe(result);
            StatusText = string.Create(CultureInfo.CurrentCulture, $"Compared in {result.Elapsed.TotalSeconds:N1} s");
        }
        catch (OperationCanceledException)
        {
            StatusText = "Comparison stopped.";
        }
        catch (Exception ex)
        {
            StatusText = ex.Message;
            if (ex is not CompareException)
            {
                CrashLog.Write("Compare data", ex);
            }

            await _context.Dialogs.ShowErrorAsync("Could not compare", ex.Message);
        }
    }

    /// <summary>Leaves rows out of the sync, or puts them back when every one was already left out.</summary>
    public void ToggleExcluded(IEnumerable<RowDiff> rows)
    {
        if (Result is not { } result)
        {
            return;
        }

        var keys = rows.Select(r => result.Spec.KeyIdentity(r.KeyRow)).ToArray();
        if (keys.All(_excluded.Contains))
        {
            _excluded.ExceptWith(keys);
        }
        else
        {
            _excluded.UnionWith(keys);
        }
    }

    /// <summary>Reviews the sync statements, then runs them against the target.</summary>
    public async Task SyncAsync()
    {
        if (Result is not { } result || _target is not { } target)
        {
            return;
        }

        if (target.Profile.IsReadOnly)
        {
            await _context.Dialogs.ShowErrorAsync("Read-only target", $"{target.Profile.Name} is read-only, so it cannot be synced.");
            return;
        }

        DataSyncPlan plan;
        try
        {
            plan = DataSyncPlan.Build(result, Options, _excluded);
        }
        catch (CompareException ex)
        {
            await _context.Dialogs.ShowErrorAsync("Cannot sync", ex.Message);
            return;
        }

        if (plan.IsEmpty)
        {
            await _context.Dialogs.ShowErrorAsync("Nothing to sync", "No difference is selected for writing. Turn on inserts, updates or deletes, or include skipped rows.");
            return;
        }

        var preview = plan.Preview(target.Session.Database);
        var batches = ApplyInBatches || plan.Steps.Count > DataSyncApplyOptions.SuggestedSingleTransactionLimit;
        var notes = new List<string>(plan.Warnings);
        if (!DataSyncTransactionality.CanRollBack(target.Profile.Engine))
        {
            notes.Add($"{target.Profile.Descriptor.DisplayName} cannot roll back, so a failure leaves the statements before it applied.");
        }
        else if (batches)
        {
            notes.Add("Batches commit as they go, so a failure keeps the batches before it.");
        }

        var title = string.Create(CultureInfo.CurrentCulture, $"Sync {plan.Table}: {plan.InsertCount:N0} inserts, {plan.UpdateCount:N0} updates, {plan.DeleteCount:N0} deletes");
        if (!await _context.Dialogs.ReviewSqlAsync(title, Reviewed(preview, notes, target.Session.Dialect), "Sync"))
        {
            return;
        }

        using var run = Begin();
        var started = DateTime.UtcNow;
        var progress = new Progress<DataSyncProgress>(p => StatusText = string.Create(CultureInfo.CurrentCulture, $"Applied {p.Applied:N0} of {p.Total:N0}…"));
        var applied = await DataSyncApplier.ApplyAsync(target.Session.Database, plan, new DataSyncApplyOptions(SingleTransaction: !batches), progress, run.Token);
        foreach (var statement in preview.Take(applied.AppliedSteps).Take(MaxReviewedStatements))
        {
            _context.History.Record(target.Profile, target.Session.Database.CurrentDatabase, new StatementResult(statement, [], 1, DateTime.UtcNow - started), StatementKind.Write, "sync");
        }

        if (applied.Error is { } error)
        {
            StatusText = error.Message;
            var kept = applied.CommittedBatches > 0 && batches
                ? string.Create(CultureInfo.CurrentCulture, $" {applied.CommittedBatches:N0} of {applied.TotalBatches:N0} batches were committed before it.")
                : " Nothing was changed.";
            await _context.Dialogs.ShowErrorAsync("The sync stopped", error.Message + kept);
            return;
        }

        _context.Notify(string.Create(CultureInfo.CurrentCulture, $"Synced {plan.Table}: {applied.RowsAffected:N0} rows."));
        await CompareDataAsync();
    }

    /// <summary>The sync script as text, for copying or saving.</summary>
    public string? SyncScript()
    {
        if (Result is not { } result || _target is not { } target)
        {
            return null;
        }

        try
        {
            var statements = DataSyncPlan.Build(result, Options, _excluded).Preview(target.Session.Database);
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
            var source = await LoadStructuresAsync(Source, "source", run.Token);
            var targetStructures = await LoadStructuresAsync(target.Session, "target", run.Token);
            var diffs = SchemaDiffEngine.Compare(source, targetStructures, SchemaOptions);
            SchemaDiffs = diffs;
            var changed = diffs.Count(d => d.Kind != SchemaDiffKind.Identical);
            Summary = string.Create(CultureInfo.CurrentCulture, $"{diffs.Count(d => d.Kind == SchemaDiffKind.OnlyInSource):N0} only in source · {diffs.Count(d => d.Kind == SchemaDiffKind.OnlyInTarget):N0} only in target · {diffs.Count(d => d.Kind == SchemaDiffKind.Changed):N0} changed · {diffs.Count(d => d.Kind == SchemaDiffKind.Identical):N0} identical");
            StatusText = changed == 0 ? "The structures match." : string.Create(CultureInfo.CurrentCulture, $"{changed:N0} tables differ");
        }
        catch (OperationCanceledException)
        {
            StatusText = "Comparison stopped.";
        }
        catch (Exception ex)
        {
            CrashLog.Write("Compare structure", ex);
            StatusText = ex.Message;
            await _context.Dialogs.ShowErrorAsync("Could not compare structure", ex.Message);
        }
    }

    /// <summary>The migration DDL for the target's engine, or null when it cannot change structure from the app.</summary>
    public MigrationScript? BuildMigration() =>
        Target?.Database is ISchemaDdlProvider ddl ? SchemaMigrationBuilder.Build(SchemaDiffs, ddl, Target.CurrentSchema, SchemaOptions) : null;

    /// <summary>Reviews the migration, then runs it on the target one statement at a time, stopping at the first error.</summary>
    public async Task MigrateAsync()
    {
        if (_target is not { } target)
        {
            return;
        }

        if (target.Profile.IsReadOnly || BuildMigration() is not { } script)
        {
            await _context.Dialogs.ShowErrorAsync("Cannot migrate", $"{target.Profile.Name} is read-only or cannot change structure from the app.");
            return;
        }

        if (script.Statements.Count == 0)
        {
            await _context.Dialogs.ShowErrorAsync("Nothing to migrate", script.Unsupported.Count > 0 ? "The target cannot express: " + string.Join("; ", script.Unsupported) : "The structures already match.");
            return;
        }

        var notes = new List<string>();
        if (script.Statements.Any(s => s.IsDestructive))
        {
            notes.Add("Some statements drop tables or columns, and the data in them is lost.");
        }

        notes.AddRange(script.Unsupported.Select(u => "Not scripted: " + u));
        notes.AddRange(SchemaDiffs.SelectMany(d => d.Notes.Select(n => $"{d.Name}: {n}")));
        if (!await _context.Dialogs.ReviewSqlAsync($"Migrate {target.Profile.Name}", Reviewed([.. script.Statements.Select(s => s.Sql)], notes, target.Session.Dialect), "Migrate"))
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
                    await _context.Dialogs.ShowErrorAsync("The migration stopped", string.Create(CultureInfo.CurrentCulture, $"{result.Error}\n\n{ran:N0} statements ran before it. Engines without transactional DDL keep them."));
                    break;
                }

                ran++;
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            await _context.Dialogs.ShowErrorAsync("The migration stopped", ex.Message);
        }
        finally
        {
            await target.Session.RefreshAsync(CancellationToken.None);
            if (ReferenceEquals(target.Session, Source))
            {
                _context.NotifySchemaChanged();
            }
        }

        if (ran == script.Statements.Count)
        {
            _context.Notify(string.Create(CultureInfo.CurrentCulture, $"Migrated {target.Profile.Name}: {ran:N0} statements."));
            await CompareStructureAsync();
        }
    }

    public string? MigrationText() => BuildMigration() is { Statements.Count: > 0 } script ? string.Join(";\n", script.Statements.Select(s => s.Sql)) + ";" : null;

    public override async ValueTask DisposeAsync()
    {
        _run?.Cancel();
        if (_target is { } target)
        {
            await target.DisposeAsync();
        }

        await base.DisposeAsync();
    }

    private static string Describe(DataDiffResult result)
    {
        var text = string.Create(CultureInfo.CurrentCulture, $"{result.OnlyInSourceCount:N0} only in source · {result.OnlyInTargetCount:N0} only in target · {result.ChangedCount:N0} changed · {result.IdenticalCount:N0} identical");
        if (result.SkippedNullKeyCount > 0)
        {
            text += string.Create(CultureInfo.CurrentCulture, $" · {result.SkippedNullKeyCount:N0} skipped for a NULL key");
        }

        if (result.StoppedAtRowLimit)
        {
            text += " · stopped at the row limit";
        }

        if (result.IsTruncated)
        {
            text += string.Create(CultureInfo.CurrentCulture, $" · showing the first {result.Differences.Count:N0} differences");
        }

        return text;
    }

    private static List<string> SetupNotes(DataCompareSetup setup)
    {
        var notes = new List<string>();
        if (setup.SourceOnlyColumns.Count > 0)
        {
            notes.Add("Only in the source, not compared: " + string.Join(", ", setup.SourceOnlyColumns));
        }

        if (setup.TargetOnlyColumns.Count > 0)
        {
            notes.Add("Only in the target, left as they are: " + string.Join(", ", setup.TargetOnlyColumns));
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
            lines.Add(string.Create(CultureInfo.CurrentCulture, $"{dialect.LineComment} and {statements.Count - MaxReviewedStatements:N0} more statements like these"));
        }

        return lines;
    }

    private async Task<List<TableStructure>> LoadStructuresAsync(ConnectionSession session, string side, CancellationToken cancellationToken)
    {
        var tables = session.Objects.Where(o => o.Kind == ObjectKind.Table).Take(MaxStructureTables).ToArray();
        var structures = new List<TableStructure>(tables.Length);
        foreach (var table in tables)
        {
            cancellationToken.ThrowIfCancellationRequested();
            structures.Add(await session.GetStructureAsync(table.Name, cancellationToken, refresh: true));
            StatusText = string.Create(CultureInfo.CurrentCulture, $"Reading {side} structure… {structures.Count:N0}/{tables.Length:N0}");
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
    }

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
