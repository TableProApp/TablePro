using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.App.Services;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Principals;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.App.ViewModels;

/// <summary>
/// The Users and Roles editor: the principal list, a principal's privileges by scope and its attributes, all staged in a
/// <see cref="PrincipalChangeTracker"/> until a review runs them, as the macOS app's Users and Roles tab does.
/// </summary>
public sealed partial class UsersRolesViewModel : ObservableObject
{
    private const int ScopeSearchLimit = 200;

    private readonly WorkspaceContext _context;
    private readonly IUserAdministration _admin;
    private CancellationTokenSource? _scopeSearch;
    private IReadOnlyList<string> _databases = [];
    private string? _currentDatabase;
    private bool _hasLoaded;
    private Task? _loading;
    private bool _syncingRows;

    public UsersRolesViewModel(WorkspaceContext context, IUserAdministration admin, UserAdministrationFeatures features)
    {
        _context = context;
        _admin = admin;
        Features = features;
        Tracker.Cascades = admin.Cascades;
        Tracker.Changed += (_, _) => OnTrackerChanged();
    }

    /// <summary>Raised when the detail pane must redraw: another principal, another scope, or any staged edit.</summary>
    public event EventHandler? DetailChanged;

    public PrincipalChangeTracker Tracker { get; } = new();

    public UserAdministrationFeatures Features { get; }

    public ObservableCollection<PrincipalRowItem> Rows { get; } = [];

    public ObservableCollection<ScopeNodeItem> ScopeRoots { get; } = [];

    /// <summary>The account this connection uses, so the review can warn before it is locked out.</summary>
    public PrincipalRef? ConnectedPrincipal { get; private set; }

    public PrincipalRef? Selection => SelectedRow?.Ref;

    public PrincipalInfo? SelectedInfo => Selection is { } selection ? Tracker.Rows().FirstOrDefault(r => r.Ref == selection)?.Info : null;

    public PrincipalDefinition? SelectedDraft => Selection is { } selection ? Tracker.Draft(selection) : null;

    public bool HasSelection => SelectedRow is not null;

    public bool HasChanges => Tracker.HasChanges;

    public bool CanUndo => Tracker.CanUndo;

    public bool CanRedo => Tracker.CanRedo;

    public string UndoLabel => Tracker.UndoActionName is { } name ? $"Undo {name}" : "Undo";

    public string RedoLabel => Tracker.RedoActionName is { } name ? $"Redo {name}" : "Redo";

    public string PendingTitle
    {
        get
        {
            if (Tracker.ChangeCount > 0)
            {
                return Tracker.ChangeCount == 1 ? "1 pending change" : string.Create(CultureInfo.CurrentCulture, $"{Tracker.ChangeCount:N0} pending changes");
            }

            var roles = Tracker.Principals.Count(p => p.IsRole);
            var users = Tracker.Principals.Count - roles;
            return Features.RoleMembership
                ? string.Create(CultureInfo.CurrentCulture, $"{users:N0} users, {roles:N0} roles")
                : string.Create(CultureInfo.CurrentCulture, $"{users:N0} users");
        }
    }

    /// <summary>What closing the tab would lose.</summary>
    public string? UnsavedWork => Tracker.HasChanges ? $"{PendingTitle} to users and roles" : null;

    [ObservableProperty]
    public partial string PrincipalFilter { get; set; } = string.Empty;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Selection), nameof(SelectedInfo), nameof(SelectedDraft), nameof(HasSelection))]
    public partial PrincipalRowItem? SelectedRow { get; set; }

    [ObservableProperty]
    public partial bool IsLoading { get; set; }

    [ObservableProperty]
    public partial string? LoadError { get; set; }

    [ObservableProperty]
    public partial string? GrantsError { get; set; }

    [ObservableProperty]
    public partial UsersRolesSegment Segment { get; set; }

    [ObservableProperty]
    public partial ScopeViewMode ScopeMode { get; set; }

    [ObservableProperty]
    public partial string ScopeFilter { get; set; } = string.Empty;

    [ObservableProperty]
    public partial ScopeNodeItem? SelectedScope { get; set; }

    [ObservableProperty]
    public partial string PrivilegeFilter { get; set; } = string.Empty;

    [ObservableProperty]
    public partial bool IsApplying { get; set; }

    // MARK: Loading

    /// <summary>Reads the server's principals. Only a forced load replaces a snapshot, since staged work rests on it.</summary>
    public Task LoadAsync(bool force = false)
    {
        // The dashboard and the view both ask for the first load; they share one rather than reading twice.
        if (_loading is { IsCompleted: false } running && !force)
        {
            return running;
        }

        if (_hasLoaded && !force)
        {
            return Task.CompletedTask;
        }

        _loading = LoadCoreAsync();
        return _loading;
    }

    private async Task LoadCoreAsync()
    {
        IsLoading = true;
        LoadError = null;
        try
        {
            var snapshot = await _admin.LoadPrincipalsAsync(CancellationToken.None);
            _databases = snapshot.Databases;
            _currentDatabase = snapshot.CurrentDatabase;
            ConnectedPrincipal = snapshot.CurrentPrincipal;
            if (_hasLoaded)
            {
                Tracker.Reload(snapshot.Principals, snapshot.Catalog);
            }
            else
            {
                Tracker.Load(snapshot.Principals, snapshot.Catalog);
            }

            _hasLoaded = true;
            if (Selection is { } selection)
            {
                await LoadGrantsAsync(selection);
            }

            await RestoreScopePresentationAsync();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            LoadError = ex.Message;
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>The principal's grants and those of every role it belongs to, which decide what it inherits.</summary>
    public async Task LoadGrantsAsync(PrincipalRef principal)
    {
        GrantsError = null;
        try
        {
            await EnsureGrantsAsync(principal);
            if (Features.RoleMembership)
            {
                foreach (var role in Tracker.RoleClosure(principal).Select(r => new PrincipalRef(r)).Where(r => !Tracker.HasLoadedGrants(r)).ToArray())
                {
                    try
                    {
                        await EnsureGrantsAsync(role);
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        // An unreadable role only means its inherited privileges go unlabelled.
                    }
                }
            }

            if (principal == Selection && ScopeMode == ScopeViewMode.Granted && ScopeFilter.Length == 0)
            {
                ApplyScopeMode();
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            GrantsError = ex.Message;
        }

        RaiseDetailChanged();
    }

    public async Task EnsureGrantsAsync(PrincipalRef principal)
    {
        if (!Tracker.HasLoadedGrants(principal))
        {
            Tracker.LoadGrants(principal, await _admin.LoadGrantsAsync(principal, CancellationToken.None));
        }
    }

    // MARK: Principals

    public bool CanRename(PrincipalRef principal) => Features.Rename && Tracker.Stage(principal) is PrincipalStage.Unchanged or PrincipalStage.Modified;

    public bool IsNameTaken(PrincipalRef principal) => Tracker.Rows().Any(r => r.Ref == principal);

    /// <summary>
    /// Where roles never log in, a principal's kind is decided by Can log in when it is created, so the toggle is offered
    /// only on existing users there; where principals are not roles at all, never.
    /// </summary>
    public bool AllowsLoginToggle(PrincipalInfo principal) =>
        Features.RoleMembership && (Features.RoleLogin || (!principal.IsRole && Tracker.Stage(principal.Ref) != PrincipalStage.Created));

    public IReadOnlyList<PrincipalRef> RoleCandidates(PrincipalRef principal) =>
        Tracker.Rows().Where(r => r.Info.IsRole && r.Ref != principal).Select(r => r.Ref).ToArray();

    public void Create(PrincipalDefinition definition)
    {
        Tracker.StageCreate(definition);
        SelectedRow = Rows.FirstOrDefault(r => r.Ref == definition.Ref);
    }

    public void SetPassword(PrincipalRef principal, string password) => Tracker.StageSetPassword(principal, password);

    /// <summary>Stages an edit of the selected principal's attributes; the form never carries a password.</summary>
    public void EditSelected(Func<PrincipalDefinition, PrincipalDefinition> edit)
    {
        if (Selection is { } selection)
        {
            Edit(selection, edit);
        }
    }

    public void Edit(PrincipalRef principal, Func<PrincipalDefinition, PrincipalDefinition> edit)
    {
        if (Tracker.Draft(principal) is { } draft)
        {
            Tracker.StageAlter(principal, edit(draft) with { Password = null });
        }
    }

    public void Rename(PrincipalRef principal, PrincipalRef renamed)
    {
        if (Tracker.Draft(principal) is { } draft)
        {
            Tracker.StageAlter(principal, draft with { Ref = renamed, Password = null });
        }
    }

    public void CopyPrivileges(PrincipalRef source, PrincipalRef target) => Tracker.CopyGrants(source, target);

    /// <summary>
    /// Stages a drop. A principal that exists only as a staged create is simply removed. The principals returned own
    /// objects and need the caller to choose what happens to those first.
    /// </summary>
    public async Task<IReadOnlyList<PrincipalRef>> DropAsync(PrincipalRef principal)
    {
        if (Tracker.Stage(principal) == PrincipalStage.Created)
        {
            Tracker.UnstageCreate(principal);
            return [];
        }

        if (Features.OwnedObjectReassignment)
        {
            try
            {
                if (await _admin.OwnsObjectsAsync(principal, CancellationToken.None))
                {
                    return [principal];
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                await _context.Dialogs.ShowErrorAsync("Could not check owned objects", ex.Message);
                return [];
            }
        }

        Tracker.StageDrop(principal, PrincipalDropOptions.None);
        return [];
    }

    public void ConfirmDrop(PrincipalRef principal, PrincipalDropOptions options) => Tracker.StageDrop(principal, options);

    public void KeepPrincipal(PrincipalRef principal) => Tracker.UnstageDrop(principal);

    /// <summary>Principals that could take over a dropped role's objects: every other existing one, by name.</summary>
    public IReadOnlyList<PrincipalRef> ReassignCandidates(PrincipalRef dropping) =>
        Tracker.Principals.Select(p => p.Ref).Where(r => r != dropping).OrderBy(r => r.Name, StringComparer.Ordinal).ToArray();

    // MARK: Privileges

    public IReadOnlyList<PrivilegeSection> Sections =>
        SelectedScope is { } node ? PrivilegeSection.Filter(Tracker.Sections(node.Scope), PrivilegeFilter) : [];

    public bool IsGranted(string privilege) =>
        Selection is { } principal && SelectedScope is { } node && Tracker.IsGranted(privilege, node.Scope, principal);

    public bool IsStaged(string privilege) =>
        Selection is { } principal && SelectedScope is { } node && Tracker.IsStaged(privilege, node.Scope, principal);

    public bool IsGrantable(string privilege) =>
        Selection is { } principal && SelectedScope is { } node && Tracker.IsGrantable(privilege, node.Scope, principal);

    public PrivilegeEffectiveness Effectiveness(string privilege) =>
        Selection is { } principal && SelectedScope is { } node ? Tracker.Effectiveness(privilege, node.Scope, principal) : PrivilegeEffectiveness.NotEffective;

    /// <summary>All of a section granted, none, or some, for its header's three-state box.</summary>
    public bool? SectionState(PrivilegeSection section)
    {
        var granted = section.Privileges.Count(p => IsGranted(p.Name));
        return granted == 0 ? false : granted == section.Privileges.Count ? true : null;
    }

    public void SetGranted(bool granted, IReadOnlyCollection<string> privileges)
    {
        if (Selection is not { } principal || SelectedScope is not { } node || privileges.Count == 0)
        {
            return;
        }

        var what = privileges.Count == 1 ? privileges.First() : $"{privileges.Count} privileges";
        Tracker.SetGranted(granted, privileges, [node.Scope], principal, $"{(granted ? "Grant" : "Revoke")} {what} on {node.Scope.DisplayName}");
    }

    public void SetAllGranted(bool granted) => SetGranted(granted, Sections.SelectMany(s => s.Privileges).Select(p => p.Name).ToArray());

    // MARK: Scope tree

    public async Task ExpandAsync(ScopeNodeItem node)
    {
        if (node.IsLoaded || node.IsLoading || node.ChildrenAvailability != ScopeChildren.Available || ScopeMode != ScopeViewMode.All || ScopeFilter.Length > 0)
        {
            return;
        }

        node.IsLoading = true;
        try
        {
            var children = await _admin.LoadChildScopesAsync(node.Scope, CancellationToken.None);
            node.SetChildren(children.Select(MakeNode));
            RefreshSummaries();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            node.SetChildren([]);
            node.Summary = ex.Message;
        }
        finally
        {
            node.IsLoading = false;
        }
    }

    public void ApplyScopeMode()
    {
        ScopeRoots.Clear();
        if (ScopeMode == ScopeViewMode.Granted)
        {
            // The server is an ancestor of every grant, but a root only where something can be granted on it.
            var closure = Selection is { } principal ? Tracker.GrantedScopeClosure(principal) : new HashSet<PrivilegeScope>();
            var shown = closure.Where(s => s.Level != PrivilegeLevel.Server || Tracker.Catalog.Server.Count > 0).ToHashSet();
            foreach (var root in BuildStaticTree(shown))
            {
                ScopeRoots.Add(root);
            }
        }
        else
        {
            if (Tracker.Catalog.Server.Count > 0)
            {
                ScopeRoots.Add(MakeNode(PrivilegeScope.Server));
            }

            foreach (var database in _databases)
            {
                ScopeRoots.Add(MakeNode(PrivilegeScope.ForDatabase(database)));
            }
        }

        SelectedScope = null;
        RefreshSummaries();
    }

    /// <summary>Waits out typing, then lists matching tables flat; clearing the box brings the tree back.</summary>
    public async Task SearchScopesAsync()
    {
        _scopeSearch?.Cancel();
        _scopeSearch?.Dispose();
        _scopeSearch = null;
        var text = ScopeFilter.Trim();
        if (text.Length == 0)
        {
            ApplyScopeMode();
            return;
        }

        if (!Features.ScopeSearch)
        {
            return;
        }

        var search = new CancellationTokenSource();
        _scopeSearch = search;
        try
        {
            await Task.Delay(250, search.Token);
            var scopes = await _admin.SearchScopesAsync(text, ScopeSearchLimit, search.Token);
            if (search.IsCancellationRequested)
            {
                return;
            }

            ScopeRoots.Clear();
            foreach (var scope in scopes)
            {
                var node = new ScopeNodeItem(scope, ScopeChildren.None);
                node.SetChildren([]);
                ScopeRoots.Add(node);
            }

            SelectedScope = null;
            RefreshSummaries();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            await _context.Dialogs.ShowErrorAsync("Could not search objects", ex.Message);
        }
    }

    // MARK: Undo and apply

    [RelayCommand]
    public void Undo() => Tracker.Undo();

    [RelayCommand]
    public void Redo() => Tracker.Redo();

    [RelayCommand]
    public void Discard() => Tracker.Discard();

    [RelayCommand]
    public Task RefreshAsync() => LoadAsync(force: true);

    /// <summary>
    /// Shows every statement for review, then runs them on one connection, inside a transaction where the engine can roll
    /// account statements back. The review hides passwords; the statements that carry one are kept out of history.
    /// </summary>
    [RelayCommand]
    public async Task ApplyAsync()
    {
        if (!Tracker.HasChanges || IsApplying)
        {
            return;
        }

        var profile = _context.Session.Profile;
        if (profile.SafeMode.BlocksAllWrites())
        {
            await _context.Dialogs.ShowErrorAsync("Read-only connection", "Safe Mode is Read-Only on this connection, so users and roles cannot be changed.");
            return;
        }

        var changes = Tracker.PendingChanges();
        IReadOnlyList<PrincipalStatement> statements;
        IReadOnlyList<PrincipalStatement> shown;
        try
        {
            statements = _admin.BuildStatements(changes);
            shown = _admin.BuildStatements(changes.Select(c => c.MaskingPassword(PrincipalScript.PasswordPlaceholder)).ToArray());
        }
        catch (UnsupportedPrincipalChangeException ex)
        {
            await _context.Dialogs.ShowErrorAsync("Cannot apply these changes", ex.Message);
            return;
        }

        if (statements.Count == 0)
        {
            Tracker.Discard();
            return;
        }

        if (Tracker.SelfImpact(ConnectedPrincipal) is { } warning
            && !await _context.Dialogs.ConfirmAsync("This affects your own account", warning + " You may lose access to this server.", "Continue", destructive: true))
        {
            return;
        }

        var hidesPasswords = statements.Any(s => s.CarriesCredentials);
        var title = hidesPasswords ? "Review user and role changes (passwords hidden)" : "Review user and role changes";
        if (!await _context.Dialogs.ReviewSqlAsync(title, shown.Select(s => s.Sql).ToArray(), statements.Any(s => s.IsDestructive) ? "Apply" : "Execute"))
        {
            return;
        }

        IsApplying = true;
        try
        {
            if (await RunAsync(statements, profile))
            {
                Tracker.Discard();
                _context.Notify(statements.Count == 1 ? "Applied 1 user and role statement." : string.Create(CultureInfo.CurrentCulture, $"Applied {statements.Count:N0} user and role statements."));
            }

            await LoadAsync(force: true);
        }
        finally
        {
            IsApplying = false;
        }
    }

    private async Task<bool> RunAsync(IReadOnlyList<PrincipalStatement> statements, ConnectionProfile profile)
    {
        var transaction = Features.Transaction;
        var applied = 0;
        await using var channel = await _context.Session.Database.OpenChannelAsync(CancellationToken.None);
        try
        {
            if (transaction is not null && await RunOneAsync(channel, transaction.Begin) is { Succeeded: false } begin)
            {
                await _context.Dialogs.ShowErrorAsync("Nothing was applied", begin.Error!);
                return false;
            }

            foreach (var statement in statements)
            {
                var result = await RunOneAsync(channel, statement.Sql);
                if (!statement.CarriesCredentials)
                {
                    _context.History.Record(profile, _context.Session.Database.CurrentDatabase, result, StatementKind.Ddl, "users");
                }

                if (!result.Succeeded)
                {
                    var rolledBack = transaction is not null && (await RunOneAsync(channel, transaction.Rollback)).Succeeded;
                    var where = $"Statement {applied + 1} of {statements.Count} failed ({statement.Description}).";
                    var outcome = rolledBack ? "Every change was rolled back." : applied == 0 ? "Nothing was applied." : $"The {applied} statements before it were applied.";
                    await _context.Dialogs.ShowErrorAsync("The changes failed", $"{where} {outcome}\n\n{result.Error}");
                    return false;
                }

                applied++;
            }

            if (transaction is not null && await RunOneAsync(channel, transaction.Commit) is { Succeeded: false } commit)
            {
                await _context.Dialogs.ShowErrorAsync("The changes were not committed", commit.Error!);
                return false;
            }

            return true;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            await _context.Dialogs.ShowErrorAsync("The changes failed", ex.Message);
            return false;
        }
    }

    private static async Task<StatementResult> RunOneAsync(IQueryChannel channel, string sql)
    {
        await foreach (var result in channel.ExecuteAsync([sql], new ExecuteOptions(RowLimit: 100), CancellationToken.None))
        {
            return result;
        }

        return new StatementResult(sql, [], -1, TimeSpan.Zero, "The statement did not run.");
    }

    // MARK: Bookkeeping

    partial void OnPrincipalFilterChanged(string value) => SyncRows();

    partial void OnSelectedRowChanged(PrincipalRowItem? oldValue, PrincipalRowItem? newValue)
    {
        if (_syncingRows)
        {
            return;
        }

        if (oldValue?.Ref != newValue?.Ref)
        {
            if (ScopeMode == ScopeViewMode.Granted && ScopeFilter.Length == 0)
            {
                ApplyScopeMode();
            }

            RefreshSummaries();
            RaiseDetailChanged();
            if (newValue is not null)
            {
                _ = LoadGrantsAsync(newValue.Ref);
            }
        }
    }

    partial void OnScopeModeChanged(ScopeViewMode value)
    {
        if (ScopeFilter.Length == 0)
        {
            ApplyScopeMode();
        }
    }

    partial void OnScopeFilterChanged(string value) => _ = SearchScopesAsync();

    partial void OnSelectedScopeChanged(ScopeNodeItem? value) => RaiseDetailChanged();

    partial void OnPrivilegeFilterChanged(string value) => RaiseDetailChanged();

    partial void OnSegmentChanged(UsersRolesSegment value) => RaiseDetailChanged();

    private void OnTrackerChanged()
    {
        SyncRows();
        RefreshSummaries();
        OnPropertyChanged(nameof(HasChanges));
        OnPropertyChanged(nameof(CanUndo));
        OnPropertyChanged(nameof(CanRedo));
        OnPropertyChanged(nameof(UndoLabel));
        OnPropertyChanged(nameof(RedoLabel));
        OnPropertyChanged(nameof(PendingTitle));
        OnPropertyChanged(nameof(UnsavedWork));
        OnPropertyChanged(nameof(SelectedInfo));
        OnPropertyChanged(nameof(SelectedDraft));
        RaiseDetailChanged();
    }

    /// <summary>
    /// Updates the list in place when the same principals are shown, so the selection and scroll position survive an
    /// edit; rebuilds it otherwise and puts the selection back.
    /// </summary>
    private void SyncRows()
    {
        var filter = PrincipalFilter.Trim();
        var rows = Tracker.Rows()
            .Where(r => filter.Length == 0 || r.DisplayName.Contains(filter, StringComparison.CurrentCultureIgnoreCase))
            .OrderBy(r => r.Ref.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(r => r.Ref.Host, StringComparer.Ordinal)
            .ToArray();

        PrincipalRef? RenamedTo(PrincipalRow row) => Tracker.Draft(row.Ref) is { } draft && draft.Ref != row.Ref ? draft.Ref : null;

        if (rows.Length == Rows.Count && rows.Select(r => r.Ref).SequenceEqual(Rows.Select(r => r.Ref)))
        {
            for (var i = 0; i < rows.Length; i++)
            {
                Rows[i].Update(rows[i], RenamedTo(rows[i]));
            }

            return;
        }

        var selection = Selection;
        _syncingRows = true;
        try
        {
            Rows.Clear();
            foreach (var row in rows)
            {
                Rows.Add(new PrincipalRowItem(row, RenamedTo(row)));
            }

            SelectedRow = selection is null ? null : Rows.FirstOrDefault(r => r.Ref == selection);
        }
        finally
        {
            _syncingRows = false;
        }

        if (selection is not null && SelectedRow is null)
        {
            RefreshSummaries();
            RaiseDetailChanged();
        }
    }

    private async Task RestoreScopePresentationAsync()
    {
        if (ScopeFilter.Trim().Length > 0)
        {
            await SearchScopesAsync();
        }
        else
        {
            ApplyScopeMode();
        }
    }

    private void RefreshSummaries()
    {
        foreach (var node in ScopeRoots.SelectMany(r => r.SelfAndDescendants()))
        {
            node.Summary = Selection is { } principal
                ? Tracker.Summary(node.Scope, principal, node.ChildrenAvailability == ScopeChildren.RestrictedToCurrentDatabase).Text
                : string.Empty;
        }
    }

    private ScopeNodeItem MakeNode(PrivilegeScope scope)
    {
        var children = scope.Level switch
        {
            PrivilegeLevel.Server or PrivilegeLevel.Column => ScopeChildren.None,
            _ when Features.RestrictsBrowsingToCurrentDatabase && scope.Database != _currentDatabase => ScopeChildren.RestrictedToCurrentDatabase,
            _ => ScopeChildren.Available,
        };
        return new ScopeNodeItem(scope, children);
    }

    private static List<ScopeNodeItem> BuildStaticTree(IReadOnlySet<PrivilegeScope> scopes)
    {
        var nodes = new Dictionary<PrivilegeScope, ScopeNodeItem>();
        var children = new Dictionary<PrivilegeScope, List<ScopeNodeItem>>();
        var roots = new List<ScopeNodeItem>();
        foreach (var scope in scopes.OrderBy(s => s.SortKey, StringComparer.Ordinal))
        {
            var node = new ScopeNodeItem(scope, ScopeChildren.None);
            nodes[scope] = node;
            if (scope.Parent is { } parent && scopes.Contains(parent))
            {
                if (!children.TryGetValue(parent, out var list))
                {
                    list = [];
                    children[parent] = list;
                }

                list.Add(node);
            }
            else
            {
                roots.Add(node);
            }
        }

        foreach (var (scope, node) in nodes)
        {
            node.SetChildren(children.TryGetValue(scope, out var list) ? list : []);
        }

        return roots;
    }

    private void RaiseDetailChanged() => DetailChanged?.Invoke(this, EventArgs.Empty);
}
