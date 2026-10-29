using TablePro.App.Services;
using TablePro.Core.Compare;
using TablePro.Storage.Compare;

namespace TablePro.App.ViewModels;

/// <summary>Saved comparisons: writing the setup on screen down by name, and putting a saved one back.</summary>
public sealed partial class CompareTabViewModel
{
    /// <summary>
    /// Saves the setup under <paramref name="name"/>. The profile on screen is updated in place; another profile with
    /// the same name is replaced only after the user agrees, so two setups never silently share a name.
    /// </summary>
    public async Task<bool> SaveProfileAsync(string name)
    {
        name = name.Trim();
        if (name.Length == 0)
        {
            return false;
        }

        var store = _endpoints.ProfileStore;
        var id = ActiveProfile is { } active && string.Equals(active.Name, name, StringComparison.CurrentCultureIgnoreCase) ? active.Id : (Guid?)null;
        if (id is null && store.FindByName(name) is { } clash)
        {
            if (!await _context.Dialogs.ConfirmAsync(Strings.Get("Compare/ReplaceProfileTitle"), Strings.Format("Compare/ReplaceProfileMessage", clash.Name), Strings.Get("Compare/ReplaceProfileButton")))
            {
                return false;
            }

            id = clash.Id;
        }

        try
        {
            var existing = id is { } known ? store.Find(known) : null;
            var setup = CurrentSetup(name) with { Id = id ?? Guid.NewGuid(), CreatedAt = existing?.CreatedAt ?? DateTimeOffset.UtcNow };
            ActiveProfile = await store.SaveAsync(setup);
            StatusText = Strings.Format("Compare/ProfileSaved", ActiveProfile.Name);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/CouldNotSaveProfileTitle"), ex.Message);
            return false;
        }
    }

    /// <summary>
    /// Puts a saved comparison back: both endpoints, the mode, the scope, each table's scope and the options. Nothing is
    /// compared until the user presses Compare, as on macOS.
    /// </summary>
    public async Task LoadProfileAsync(CompareProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (IsRunning)
        {
            return;
        }

        var source = Profiles.FirstOrDefault(p => p.Id == profile.Source.ConnectionId);
        var target = Profiles.FirstOrDefault(p => p.Id == profile.Target.ConnectionId);
        if (source is null || target is null)
        {
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/CouldNotLoadProfileTitle"), Strings.Format("Compare/ProfileMissingConnection", profile.Name));
            return;
        }

        if (!await ConnectSourceAsync(source))
        {
            return;
        }

        if (profile.Source.Schema is { } sourceSchema && SourceSchemas.Contains(sourceSchema))
        {
            await SetSchemaAsync(target: false, sourceSchema);
        }

        ApplyOptions(profile.Options);
        Mode = profile.Mode;
        Scope = profile.Scope;

        TargetProfile = target;
        if (!await ConnectTargetAsync())
        {
            return;
        }

        if (profile.Target.Schema is { } targetSchema && TargetSchemas.Contains(targetSchema))
        {
            await SetSchemaAsync(target: true, targetSchema);
        }

        if (profile.Scope == DataCompareScope.OneTable)
        {
            ApplyOneTable(profile.Tables.Count > 0 ? profile.Tables[0] : null);
            RebuildPlans();
        }
        else
        {
            RebuildPlans(profile.Tables, savedOnly: profile.Scope == DataCompareScope.ChosenTables);
        }

        ClearResults();
        Notes = [.. DatabaseNotes(profile)];
        ActiveProfile = profile;
        StatusText = Strings.Format("Compare/ProfileLoaded", profile.Name);
    }

    public async Task DeleteProfileAsync(CompareProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (!await _context.Dialogs.ConfirmAsync(Strings.Get("Compare/DeleteProfileTitle"), Strings.Format("Compare/DeleteProfileMessage", profile.Name), Strings.Get("Common/Delete"), destructive: true))
        {
            return;
        }

        try
        {
            await _endpoints.ProfileStore.DeleteAsync(profile.Id);
            if (ActiveProfile?.Id == profile.Id)
            {
                ActiveProfile = null;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Compare/CouldNotSaveProfileTitle"), ex.Message);
        }
    }

    /// <summary>The pair a saved comparison names, so a list of several can be told apart without loading one.</summary>
    public string DescribeProfile(CompareProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var mode = profile.Mode == CompareMode.Structure
            ? Strings.Get("Compare/ModeStructure")
            : profile.Scope switch
            {
                DataCompareScope.OneTable => Strings.Get("Compare/ScopeOneTable"),
                DataCompareScope.WholeSchema => Strings.Get("Compare/ScopeWholeSchema"),
                _ => Strings.Plural("Compare/ProfileTableCount", profile.Tables.Count(t => t.IsIncluded)),
            };
        return Strings.Format("Compare/ProfileDescription", EndpointName(profile.Source), EndpointName(profile.Target), mode);
    }

    private string EndpointName(CompareEndpointScope scope)
    {
        var name = Profiles.FirstOrDefault(p => p.Id == scope.ConnectionId)?.Name ?? Strings.Get("Compare/MissingConnection");
        return string.IsNullOrEmpty(scope.Schema) ? name : $"{name} ({scope.Schema})";
    }

    private CompareProfile CurrentSetup(string name)
    {
        var tables = Scope switch
        {
            DataCompareScope.OneTable when SelectedSourceTable is { } source && SelectedTargetTable is { } target =>
            [
                new CompareProfileTable
                {
                    SourceSchema = source.Name.Schema,
                    Source = source.Name.Name,
                    TargetSchema = target.Name.Schema,
                    Target = target.Name.Name,
                    Scope = new CompareTableScope
                    {
                        KeyColumns = SplitList(KeyColumns),
                        ExcludedColumns = SplitList(ExcludedColumns),
                        SourceFilter = string.IsNullOrWhiteSpace(SourceWhere) ? null : SourceWhere.Trim(),

                        // One-table mode filters each side on its own, so an empty target filter means "every row".
                        TargetFilter = TargetWhere.Trim(),
                    },
                },
            ],
            DataCompareScope.OneTable => [],
            DataCompareScope.WholeSchema => TablePlans.Where(p => !p.Scope.IsDefault).Select(SavedTable).ToList(),
            _ => TablePlans.Where(p => p.IsIncluded || !p.Scope.IsDefault).Select(SavedTable).ToList(),
        };

        return new CompareProfile
        {
            Name = name,
            Source = new CompareEndpointScope { ConnectionId = Source.Profile.Id, Database = Source.Database.CurrentDatabase, Schema = SourceSchema },
            Target = new CompareEndpointScope
            {
                ConnectionId = TargetProfile?.Id ?? Source.Profile.Id,
                Database = Target?.Database.CurrentDatabase ?? TargetProfile?.Database,
                Schema = TargetSchema,
            },
            Mode = Mode,
            Scope = Scope,
            Tables = tables,
            Options = new CompareProfileOptions
            {
                InsertMissingRows = InsertMissing,
                UpdateChangedRows = UpdateChanged,
                DeleteExtraRows = DeleteExtra,
                KeysIgnoreCase = KeysIgnoreCase,
                FloatTolerance = Math.Max(0, FloatTolerance),
                ApplyInBatches = ApplyInBatches,
                RowLimit = GlobalRowLimit,
                DropExtraTables = DropExtraTables,
                DropExtraColumns = DropExtraColumns,
            },
        };
    }

    private static CompareProfileTable SavedTable(CompareTablePlan plan) => new()
    {
        SourceSchema = plan.Pair.Source.Schema,
        Source = plan.Pair.Source.Name,
        TargetSchema = plan.Pair.Target.Schema,
        Target = plan.Pair.Target.Name,
        IsIncluded = plan.IsIncluded,
        Scope = plan.Scope,
    };

    private void ApplyOneTable(CompareProfileTable? table)
    {
        if (table is null)
        {
            return;
        }

        SelectedSourceTable = SourceTables.FirstOrDefault(t => string.Equals(t.Name.Name, table.Source, StringComparison.OrdinalIgnoreCase)) ?? SelectedSourceTable;
        SelectedTargetTable = TargetTables.FirstOrDefault(t => string.Equals(t.Name.Name, table.Target, StringComparison.OrdinalIgnoreCase)) ?? SelectedTargetTable;
        KeyColumns = string.Join(", ", table.Scope.KeyColumns);
        ExcludedColumns = string.Join(", ", table.Scope.ExcludedColumns);
        SourceWhere = table.Scope.SourceFilter ?? string.Empty;
        TargetWhere = table.Scope.TargetFilter ?? table.Scope.SourceFilter ?? string.Empty;
    }

    /// <summary>
    /// A profile remembers the database each side was saved against. A connection since pointed elsewhere is named
    /// rather than followed, since a comparison quietly run against another database answers a different question.
    /// </summary>
    private IEnumerable<string> DatabaseNotes(CompareProfile profile)
    {
        if (Differs(profile.Source.Database, Source.Database.CurrentDatabase))
        {
            yield return Strings.Format("Compare/ProfileDatabaseMoved", Source.Profile.Name, profile.Source.Database, Source.Database.CurrentDatabase);
        }

        if (Target is { } target && Differs(profile.Target.Database, target.Database.CurrentDatabase))
        {
            yield return Strings.Format("Compare/ProfileDatabaseMoved", target.Profile.Name, profile.Target.Database, target.Database.CurrentDatabase);
        }

        static bool Differs(string? saved, string? now) =>
            !string.IsNullOrEmpty(saved) && !string.IsNullOrEmpty(now) && !string.Equals(saved, now, StringComparison.OrdinalIgnoreCase);
    }

    private async Task LoadSavedProfilesAsync()
    {
        try
        {
            await _endpoints.ProfileStore.EnsureLoadedAsync();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            CrashLog.Write("Compare: load saved comparisons", ex);
        }

        SavedProfiles = _endpoints.ProfileStore.Profiles;
        await RestoreLastSetupAsync();
    }

    /// <summary>
    /// Puts back the setup the last compare tab held, as the macOS window reopens where it was left, so running the
    /// same comparison again is one press of Compare. The tab's workspace stays the source. The target and the table
    /// scopes come back only when they were remembered against this same source, connection, database and schema,
    /// since the target is the side that gets written to. A tab opened from a table keeps that table and its mode.
    /// Nothing is compared.
    /// </summary>
    private async Task RestoreLastSetupAsync()
    {
        if (_endpoints.ProfileStore.LastSetup is not { } setup || IsRunning || _target is not null || ActiveProfile is not null)
        {
            return;
        }

        ApplyOptions(setup.Options);
        if (_startTable is null)
        {
            Mode = setup.Mode;
            Scope = setup.Scope;
        }

        if (!IsCurrentSource(setup.Source) || Profiles.FirstOrDefault(p => p.Id == setup.Target.ConnectionId) is not { } target)
        {
            return;
        }

        TargetProfile = target;
        if (!await ConnectTargetAsync(reportErrors: false))
        {
            return;
        }

        if (setup.Target.Schema is { } targetSchema && TargetSchemas.Contains(targetSchema))
        {
            await SetSchemaAsync(target: true, targetSchema);
        }

        if (_startTable is not null)
        {
            return;
        }

        if (setup.Scope == DataCompareScope.OneTable)
        {
            ApplyOneTable(setup.Tables.Count > 0 ? setup.Tables[0] : null);
            RebuildPlans();
        }
        else
        {
            RebuildPlans(setup.Tables, savedOnly: setup.Scope == DataCompareScope.ChosenTables);
        }

        ClearResults();
    }

    /// <summary>
    /// Writes the setup down for the next tab once a pair is open. Under several tables only the scopes the user
    /// changed are kept, and the store unticks them all.
    /// </summary>
    private void RememberSetup()
    {
        if (_target is null)
        {
            return;
        }

        var setup = CurrentSetup(string.Empty);
        if (Scope != DataCompareScope.OneTable)
        {
            setup = setup with { Tables = [.. setup.Tables.Where(t => !t.Scope.IsDefault)] };
        }

        _ = WriteSetupAsync(setup);
    }

    private async Task WriteSetupAsync(CompareProfile setup)
    {
        try
        {
            await Task.Run(() => _endpoints.ProfileStore.RememberSetupAsync(setup));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Losing the remembered setup costs a few picks next time; it must not interrupt the comparison.
            CrashLog.Write("Compare: remember the setup", ex);
        }
    }

    private bool IsCurrentSource(CompareEndpointScope scope) =>
        scope.ConnectionId == Source.Profile.Id
        && string.Equals(scope.Database ?? string.Empty, Source.Database.CurrentDatabase ?? string.Empty, StringComparison.Ordinal)
        && string.Equals(scope.Schema ?? string.Empty, SourceSchema ?? string.Empty, StringComparison.Ordinal);

    private void ApplyOptions(CompareProfileOptions options)
    {
        InsertMissing = options.InsertMissingRows;
        UpdateChanged = options.UpdateChangedRows;
        DeleteExtra = options.DeleteExtraRows;
        KeysIgnoreCase = options.KeysIgnoreCase;
        FloatTolerance = Math.Max(0, options.FloatTolerance);
        RowLimit = options.RowLimit is { } limit ? limit : double.NaN;
        ApplyInBatches = options.ApplyInBatches;
        DropExtraTables = options.DropExtraTables;
        DropExtraColumns = options.DropExtraColumns;
    }

    // The store raises Changed on whichever thread saved, which can be another window's.
    private void OnProfilesChanged(object? sender, EventArgs e) =>
        _dispatcher.TryEnqueueLogged(() => SavedProfiles = _endpoints.ProfileStore.Profiles);
}
