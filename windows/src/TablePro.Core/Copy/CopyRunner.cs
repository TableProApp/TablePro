using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Core.Copy;

/// <summary>A DDL statement the target refused.</summary>
public sealed class CopyStepException(string message, string? statement = null) : InvalidOperationException(message)
{
    public string? Statement { get; } = statement;
}

/// <summary>
/// Runs a <see cref="CopyPlan"/>: drops what is replaced, creates the tables, streams every table's rows in batches,
/// then builds indexes and adds foreign keys once all rows are in, and last creates views and routines.
/// </summary>
/// <remarks>
/// The macOS copy turns the target's foreign key checks off for one transaction and checks them at the commit. Rows
/// here go through the session's save path, a pooled connection and a transaction per batch, where a session setting
/// would not last; so the keys are added after the rows instead. That also defers every check to the end, and the
/// engine validates the existing rows as it adds each key, so a row the source already broke fails there.
/// </remarks>
public static class CopyRunner
{
    public static async Task<CopyResult> RunAsync(CopyRequest request, CopyPlan plan, IProgress<CopyProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(plan);
        var run = new Run(request, plan, progress, cancellationToken);
        try
        {
            await run.ExecuteAsync();
        }
        catch (OperationCanceledException)
        {
            run.Cancelled = true;
        }
        finally
        {
            await run.DisposeAsync();
        }

        return run.Result();
    }

    private sealed class Run(CopyRequest request, CopyPlan plan, IProgress<CopyProgress>? progress, CancellationToken cancellationToken) : IAsyncDisposable
    {
        private readonly Dictionary<string, Outcome> _outcomes = new(StringComparer.Ordinal);
        private readonly List<string> _order = [];
        private readonly ISchemaDdlProvider? _ddl = request.Target as ISchemaDdlProvider;
        private IQueryChannel? _channel;
        private bool _stopped;

        public bool Cancelled { get; set; }

        public async Task ExecuteAsync()
        {
            foreach (var table in plan.Tables)
            {
                Track(Key(table.Source), table.Target.ToString(), table.Action == CopyAction.Skip ? CopyOutcomeStatus.Skipped : CopyOutcomeStatus.Copied, table.Notes, FinalPhase(table));
            }

            foreach (var definition in plan.Definitions)
            {
                Track(Key(definition.Source), definition.Target.ToString(), definition.Action == CopyAction.Skip ? CopyOutcomeStatus.Skipped : CopyOutcomeStatus.Copied, definition.Notes, CopyPhase.Definitions);
            }

            var tables = plan.Tables.Where(t => t.Action != CopyAction.Skip).ToArray();
            var definitions = plan.Definitions.Where(d => d.Action != CopyAction.Skip).ToArray();
            var recreated = request.IncludesStructure ? tables.Where(t => t.Action is CopyAction.Create or CopyAction.Replace).ToArray() : [];

            // Views go before the tables they read, and children before their parents, so no drop meets a dependent.
            foreach (var definition in definitions.Where(d => d.Action == CopyAction.Replace))
            {
                await StepAsync(definition.Source, CopyPhase.Dropping, definition.Target.ToString(), () => DdlAsync(new DropObject(definition.Source with { Name = definition.Target }), definition.Target));
            }

            foreach (var table in recreated.Where(t => t.Action == CopyAction.Replace).Reverse())
            {
                await StepAsync(table.Source, CopyPhase.Dropping, table.Target.ToString(), () => DdlAsync(new DropObject(new DatabaseObject(table.Target, ObjectKind.Table)), table.Target));
            }

            foreach (var table in recreated)
            {
                await StepAsync(table.Source, CopyPhase.Creating, table.Target.ToString(), () => DdlAsync(new CreateTable(table.Target, table.Columns), table.Target));
            }

            if (request.IncludesData)
            {
                // Data only with Replace empties the table first, in the same pass that fills it.
                foreach (var table in tables.Where(t => !request.IncludesStructure && t.Action == CopyAction.Replace))
                {
                    await StepAsync(table.Source, CopyPhase.Dropping, table.Target.ToString(), () => DdlAsync(new TruncateTable(), table.Target));
                }

                foreach (var table in tables)
                {
                    await StepAsync(table.Source, CopyPhase.CopyingRows, table.Target.ToString(), () => CopyRowsAsync(table));
                }
            }

            foreach (var table in recreated)
            {
                foreach (var index in table.Indexes)
                {
                    await StepAsync(table.Source, CopyPhase.Indexing, table.Target.ToString(), () => DdlAsync(new CreateIndex(index), table.Target), note: $"index {index.Name}");
                }
            }

            // Every row is in, so a key checks the finished tables: the deferral the macOS copy gets from its commit.
            foreach (var table in recreated)
            {
                foreach (var key in table.ForeignKeys)
                {
                    if (!Succeeded(key.ReferencedTable, recreated))
                    {
                        Note(table.Source, $"The foreign key {key.Name} was not added, since {key.ReferencedTable} was not copied.");
                        continue;
                    }

                    await StepAsync(table.Source, CopyPhase.LinkingKeys, table.Target.ToString(), () => DdlAsync(new AddForeignKey(key), table.Target), note: $"foreign key {key.Name}");
                }
            }

            foreach (var table in recreated.Where(t => t.IdentityColumns.Count > 0))
            {
                await StepAsync(table.Source, CopyPhase.LinkingKeys, table.Target.ToString(), () => ResetIdentityAsync(table));
            }

            foreach (var definition in definitions)
            {
                await StepAsync(definition.Source, CopyPhase.Definitions, definition.Target.ToString(), () => CreateDefinitionAsync(definition));
            }

            Report(CopyPhase.Finished, null, null, null);
        }

        public CopyResult Result()
        {
            // An object the run stopped before it finished did not get every part it was meant to, so it is not copied.
            if (_stopped || Cancelled)
            {
                foreach (var outcome in _outcomes.Values.Where(o => o.Status == CopyOutcomeStatus.Copied && o.Reached < o.Final))
                {
                    outcome.Status = Cancelled ? CopyOutcomeStatus.Cancelled : CopyOutcomeStatus.Skipped;
                    outcome.Error ??= Cancelled ? "Stopped before it was finished." : "Not finished, since the copy stopped at an earlier failure.";
                }
            }

            return new([.. _order.Select(k => _outcomes[k].ToOutcome())], Cancelled);
        }

        private CopyPhase FinalPhase(CopyTablePlan table)
        {
            if (table.Action == CopyAction.Skip)
            {
                return CopyPhase.Preparing;
            }

            var recreates = request.IncludesStructure && table.Action is CopyAction.Create or CopyAction.Replace;
            if (recreates && (table.ForeignKeys.Count > 0 || table.IdentityColumns.Count > 0))
            {
                return CopyPhase.LinkingKeys;
            }

            if (recreates && table.Indexes.Count > 0)
            {
                return CopyPhase.Indexing;
            }

            return request.IncludesData ? CopyPhase.CopyingRows : CopyPhase.Creating;
        }

        public async ValueTask DisposeAsync()
        {
            if (_channel is not null)
            {
                await _channel.DisposeAsync();
            }
        }

        private static string Key(DatabaseObject obj) => $"{obj.Kind}\u001F{obj.Name}";

        private void Track(string key, string name, CopyOutcomeStatus status, IReadOnlyList<string> notes, CopyPhase final)
        {
            if (_outcomes.TryAdd(key, new Outcome(name, status) { Final = final }))
            {
                _order.Add(key);
                _outcomes[key].Notes.AddRange(notes);
            }
        }

        private void Note(DatabaseObject obj, string note) => _outcomes[Key(obj)].Notes.Add(note);

        private bool Succeeded(ObjectName referenced, CopyTablePlan[] recreated)
        {
            var parent = recreated.FirstOrDefault(t => t.Target == referenced);

            // A key to a table the target already had is fine; one to a copied table needs that table's copy to have worked.
            return parent is null || _outcomes[Key(parent.Source)].Status == CopyOutcomeStatus.Copied;
        }

        /// <summary>
        /// Runs one step for one object unless the run has stopped or the object already failed. A failure marks the
        /// object and, under <see cref="CopyErrorHandling.Stop"/>, ends the run.
        /// </summary>
        private async Task StepAsync(DatabaseObject obj, CopyPhase phase, string name, Func<Task> step, string? note = null)
        {
            var outcome = _outcomes[Key(obj)];
            if (_stopped || outcome.Status != CopyOutcomeStatus.Copied)
            {
                return;
            }

            cancellationToken.ThrowIfCancellationRequested();
            Report(phase, name, null, null);
            try
            {
                await step();
                outcome.Reached = phase;
            }
            catch (OperationCanceledException)
            {
                outcome.Status = CopyOutcomeStatus.Cancelled;
                throw;
            }
            catch (Exception ex)
            {
                outcome.Status = CopyOutcomeStatus.Failed;
                outcome.Error = note is null ? ex.Message : $"Could not create the {note}: {ex.Message}";
                if (request.ErrorHandling == CopyErrorHandling.Stop)
                {
                    _stopped = true;
                }
            }
        }

        private void Report(CopyPhase phase, string? name, long? rows, long? total) =>
            progress?.Report(new CopyProgress(phase, name, _outcomes.Values.Sum(o => o.Rows), rows, total));

        private async Task DdlAsync(SchemaChange change, ObjectName table)
        {
            if (_ddl is null)
            {
                throw new CopyStepException("The target cannot change its structure from TablePro.");
            }

            // Built just before it runs: SQLite reads the live table to write a rebuild.
            var statements = _ddl.BuildDdl(table, change);
            if (statements.Count == 0)
            {
                throw new CopyStepException($"{request.Target.Profile.Descriptor.DisplayName} cannot express this change.");
            }

            await ExecuteAsync(statements);
        }

        private async Task ExecuteAsync(IReadOnlyList<string> statements)
        {
            _channel ??= await request.Target.OpenChannelAsync(cancellationToken);
            await foreach (var result in _channel.ExecuteAsync(statements, new ExecuteOptions(RowLimit: 1, StopOnError: true), cancellationToken))
            {
                if (!result.Succeeded)
                {
                    throw new CopyStepException(result.Error!, result.Sql);
                }
            }
        }

        private async Task CopyRowsAsync(CopyTablePlan table)
        {
            if (table.InsertColumns.Count == 0)
            {
                return;
            }

            var outcome = _outcomes[Key(table.Source)];
            var name = table.Target.ToString();
            var targetFamily = CopyTypeMapper.FamilyOf(request.Target.Profile.Engine);
            var shares = CopyTypeMapper.SharesTypes(request.Source.Profile.Engine, request.Target.Profile.Engine);
            long? total = null;
            try
            {
                total = await request.Source.CountAsync(table.Structure.Table, BrowseFilter.None, cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // The count only drives the progress bar; a copy of a table the server will not count still runs.
            }

            var sort = table.PageOrder.Select(c => new SortColumn(c, false)).ToArray();
            var pageSize = Math.Max(1, request.BatchSize);

            // Without a column to order by, offset paging could skip or repeat rows, so the table is read in one page.
            var limit = sort.Length == 0 ? int.MaxValue : pageSize;
            var offset = 0;
            Report(CopyPhase.CopyingRows, name, 0, total);
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var page = await request.Source.BrowseAsync(new BrowseRequest(table.Structure.Table, BrowseFilter.None, sort, offset, limit), cancellationToken);
                if (page.RowCount == 0)
                {
                    break;
                }

                var ordinals = table.InsertColumns.Select(c => page.ColumnIndex(c.Source)).ToArray();
                var shapes = table.InsertColumns.Select(c => table.TargetShapes.TryGetValue(c.Target, out var shape) ? shape : new SqlTypeShape(SqlTypeCategory.Other)).ToArray();
                for (var start = 0; start < page.RowCount; start += pageSize)
                {
                    var end = Math.Min(page.RowCount, start + pageSize);
                    var batch = new List<RowChange>(end - start);
                    for (var r = start; r < end; r++)
                    {
                        var row = page.Rows[r];
                        var values = new Dictionary<string, object?>(ordinals.Length, StringComparer.Ordinal);
                        for (var c = 0; c < ordinals.Length; c++)
                        {
                            values[table.InsertColumns[c].Target] = ordinals[c] < 0 ? null : CopyValueAdapter.Adapt(row[ordinals[c]], shapes[c], targetFamily, shares);
                        }

                        batch.Add(new RowInsert(values));
                    }

                    await request.Target.SaveChangesAsync(table.Target, batch, cancellationToken);
                    outcome.Rows += batch.Count;
                    Report(CopyPhase.CopyingRows, name, outcome.Rows, total);
                }

                if (page.RowCount < limit)
                {
                    break;
                }

                offset += page.RowCount;
            }
        }

        // An identity filled with explicit values keeps counting from 1, so its sequence is moved past the copied rows.
        private async Task ResetIdentityAsync(CopyTablePlan table)
        {
            var dialect = request.Target.Dialect;
            var qualified = dialect.Qualify(table.Target);
            var statements = table.IdentityColumns.Select(column =>
                $"SELECT setval(pg_get_serial_sequence({dialect.StringLiteral(qualified)}, {dialect.StringLiteral(column)}), COALESCE(MAX({dialect.QuoteIdentifier(column)}), 0) + 1, false) FROM {qualified}").ToArray();
            await ExecuteAsync(statements);
        }

        private async Task CreateDefinitionAsync(CopyDefinitionPlan definition)
        {
            var text = await request.Source.GetDefinitionAsync(definition.Source, cancellationToken);
            var retargeted = DefinitionRetargeter.Retarget(text, request.Source.Dialect, definition.Source.Name.Schema, definition.Target.Schema);
            var statements = request.Target.Dialect.Split(retargeted).Select(s => s.Text).Where(s => !string.IsNullOrWhiteSpace(s)).ToArray();
            if (statements.Length == 0)
            {
                throw new CopyStepException($"The source returned no definition for {definition.Source.Name}.");
            }

            await ExecuteAsync(statements);
        }

        private sealed class Outcome(string name, CopyOutcomeStatus status)
        {
            public string Name { get; } = name;

            public CopyOutcomeStatus Status { get; set; } = status;

            public long Rows { get; set; }

            public string? Error { get; set; }

            /// <summary>The last phase this object has a step in.</summary>
            public CopyPhase Final { get; init; }

            /// <summary>The last phase one of its steps finished.</summary>
            public CopyPhase Reached { get; set; }

            public List<string> Notes { get; } = [];

            public CopyObjectOutcome ToOutcome() => new(Name, Status, Rows, Error) { Notes = Notes };
        }
    }
}
