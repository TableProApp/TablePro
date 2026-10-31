using System.Collections.Immutable;
using TablePro.Core.Localization;

namespace TablePro.Core.Principals;

/// <summary>
/// The Users and Roles editor's model: the server's principals and the grants loaded for them, and every edit staged on
/// top until an apply runs it or a discard drops it. Nothing here touches a database, so the whole editing behavior is
/// pinned by unit tests.
/// </summary>
/// <remarks>
/// Each edit replaces one immutable <see cref="EditState"/>, and undo restores the previous one. Snapshots rather than
/// inverse operations keep undo exact however edits combine: unstaging a create and undoing it brings back the grants
/// and password staged for it as they were.
/// </remarks>
public sealed class PrincipalChangeTracker
{
    private const int UndoLimit = 100;

    private readonly Dictionary<PrincipalRef, IReadOnlyList<PrincipalGrant>> _baselineGrants = [];
    private readonly Dictionary<PrincipalRef, ImmutableHashSet<PrincipalGrantKey>> _baselineKeys = [];
    private readonly Dictionary<PrincipalRef, IReadOnlySet<PrivilegeScope>> _closureCache = [];
    private readonly List<(string Name, EditState State)> _undo = [];
    private readonly List<(string Name, EditState State)> _redo = [];
    private EditState _state = EditState.Empty;

    /// <summary>Raised after anything that changes what the editor shows: a load, an edit, an undo.</summary>
    public event EventHandler? Changed;

    public IReadOnlyList<PrincipalInfo> Principals { get; private set; } = [];

    public PrivilegeCatalog Catalog { get; private set; } = PrivilegeCatalog.Empty;

    /// <summary>Whether a grant on the first scope also covers the second; the engine's rule, from its driver.</summary>
    public Func<PrivilegeScope, PrivilegeScope, bool> Cascades { get; set; } = static (_, _) => false;

    public int ChangeCount { get; private set; }

    public bool HasChanges => ChangeCount > 0;

    public bool CanUndo => _undo.Count > 0;

    public bool CanRedo => _redo.Count > 0;

    public string? UndoActionName => _undo.Count > 0 ? _undo[^1].Name : null;

    public string? RedoActionName => _redo.Count > 0 ? _redo[^1].Name : null;

    public IReadOnlyList<PrincipalDefinition> PendingCreates => _state.Creates;

    // MARK: Loading

    /// <summary>A fresh snapshot from the server: everything staged is dropped with the old one.</summary>
    public void Load(IReadOnlyList<PrincipalInfo> principals, PrivilegeCatalog catalog)
    {
        Principals = principals;
        Catalog = catalog;
        _baselineGrants.Clear();
        _baselineKeys.Clear();
        _state = EditState.Empty;
        _undo.Clear();
        _redo.Clear();
        StateChanged();
    }

    /// <summary>
    /// A reload after an apply or a refresh. Staged work that still makes sense survives: a create the server now has is
    /// done, while edits to principals that no longer exist go. Grants are refetched, since the server's are stale.
    /// </summary>
    public void Reload(IReadOnlyList<PrincipalInfo> principals, PrivilegeCatalog catalog)
    {
        Principals = principals;
        Catalog = catalog;
        var live = principals.Select(p => p.Ref).ToHashSet();
        var creates = _state.Creates.Where(c => !live.Contains(c.Ref)).ToImmutableList();
        var retained = live.Union(creates.Select(c => c.Ref)).ToHashSet();

        _baselineGrants.Clear();
        _baselineKeys.Clear();
        _state = new EditState(
            _state.Deltas.Where(d => retained.Contains(d.Key) && !d.Value.IsEmpty).ToImmutableDictionary(),
            creates,
            _state.Drops.Where(d => live.Contains(d.Key)).ToImmutableDictionary(),
            _state.Passwords.Where(p => retained.Contains(p.Key)).ToImmutableDictionary(),
            _state.Alters.Where(a => live.Contains(a.Key)).ToImmutableDictionary());

        // The snapshots on the stacks describe principals as they were before the reload.
        _undo.Clear();
        _redo.Clear();
        StateChanged();
    }

    public void LoadGrants(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants)
    {
        _baselineGrants[principal] = grants;
        _baselineKeys[principal] = grants.Select(g => new PrincipalGrantKey(g.Privilege, g.Scope)).ToImmutableHashSet();
        StateChanged();
    }

    /// <summary>A staged create has nothing on the server to fetch, so it counts as loaded with no grants.</summary>
    public bool HasLoadedGrants(PrincipalRef principal) =>
        _baselineGrants.ContainsKey(principal) || _state.Creates.Any(c => c.Ref == principal);

    // MARK: Reading

    public IReadOnlyList<PrincipalRow> Rows()
    {
        var rows = new List<PrincipalRow>(Principals.Count + _state.Creates.Count);
        rows.AddRange(Principals.Select(p => new PrincipalRow(p, Stage(p.Ref))));
        rows.AddRange(_state.Creates.Select(c => new PrincipalRow(
            new PrincipalInfo(c.Ref, !c.CanLogin, c.CanLogin, c.Attributes, c.MemberOf, c.ConnectionLimit, c.Comment),
            PrincipalStage.Created)));
        return rows;
    }

    public PrincipalStage Stage(PrincipalRef principal)
    {
        if (_state.Drops.ContainsKey(principal))
        {
            return PrincipalStage.Dropped;
        }

        if (_state.Creates.Any(c => c.Ref == principal))
        {
            return PrincipalStage.Created;
        }

        return EffectiveGrantChangeCount(principal) > 0 || _state.Passwords.ContainsKey(principal) || _state.Alters.ContainsKey(principal)
            ? PrincipalStage.Modified
            : PrincipalStage.Unchanged;
    }

    /// <summary>What the attributes form edits: the staged alter or create, else the principal as the server has it.</summary>
    public PrincipalDefinition? Draft(PrincipalRef principal)
    {
        if (_state.Alters.TryGetValue(principal, out var alter))
        {
            return alter;
        }

        if (_state.Creates.FirstOrDefault(c => c.Ref == principal) is { } create)
        {
            return create;
        }

        return Principals.FirstOrDefault(p => p.Ref == principal) is { } info ? PrincipalDefinition.From(info) : null;
    }

    public bool HasPendingPassword(PrincipalRef principal) => _state.Passwords.ContainsKey(principal);

    public bool IsGranted(string privilege, PrivilegeScope scope, PrincipalRef principal)
    {
        var key = new PrincipalGrantKey(privilege, scope);
        var baseline = BaselineKeys(principal).Contains(key);
        return _state.Deltas.TryGetValue(principal, out var delta) ? delta.Resolves(key, baseline) : baseline;
    }

    /// <summary>
    /// A privilege across several selected objects: true where every one holds it, false where none does, and null
    /// for some, so the checklist shows a mixed box and a click grants it on all of them.
    /// </summary>
    public bool? GrantState(string privilege, IReadOnlyCollection<PrivilegeScope> scopes, PrincipalRef principal)
    {
        var granted = scopes.Count(s => IsGranted(privilege, s, principal));
        return granted == 0 ? false : granted == scopes.Count ? true : null;
    }

    public bool IsGrantable(string privilege, PrivilegeScope scope, PrincipalRef principal) =>
        _baselineGrants.TryGetValue(principal, out var grants) && grants.Any(g => g.IsGrantable && g.Privilege == privilege && g.Scope == scope);

    /// <summary>Whether the checklist row differs from the server because of a staged edit.</summary>
    public bool IsStaged(string privilege, PrivilegeScope scope, PrincipalRef principal) =>
        IsGranted(privilege, scope, principal) != BaselineKeys(principal).Contains(new PrincipalGrantKey(privilege, scope));

    public IReadOnlySet<PrincipalGrantKey> ResolvedGrantKeys(PrincipalRef principal)
    {
        var baseline = BaselineKeys(principal);
        return _state.Deltas.TryGetValue(principal, out var delta) ? baseline.Except(delta.Removed).Union(delta.Added) : baseline;
    }

    /// <summary>Every scope the principal holds something on, with their ancestors, for the tree's Granted view.</summary>
    public IReadOnlySet<PrivilegeScope> GrantedScopeClosure(PrincipalRef principal)
    {
        if (_closureCache.TryGetValue(principal, out var cached))
        {
            return cached;
        }

        var closure = new HashSet<PrivilegeScope>();
        foreach (var key in ResolvedGrantKeys(principal))
        {
            for (var scope = key.Scope; scope is not null; scope = scope.Parent)
            {
                closure.Add(scope);
            }
        }

        _closureCache[principal] = closure;
        return closure;
    }

    public IReadOnlyList<string> GrantedPrivileges(PrivilegeScope scope, PrincipalRef principal) =>
        ResolvedGrantKeys(principal).Where(k => k.Scope == scope).Select(k => k.Privilege).ToArray();

    public int DescendantGrantCount(PrivilegeScope scope, PrincipalRef principal) =>
        ResolvedGrantKeys(principal).Count(k => scope.Contains(k.Scope));

    public IReadOnlyList<PrivilegeSection> Sections(PrivilegeScope scope) => PrivilegeSection.Group(Catalog.For(scope));

    public ScopeSummary Summary(PrivilegeScope scope, PrincipalRef principal, bool isBrowsingRestricted)
    {
        var granted = GrantedPrivileges(scope, principal);
        return ScopeSummary.Make(
            granted,
            Catalog.For(scope),
            DescendantGrantCount(scope, principal),
            granted.Any(p => IsGrantable(p, scope, principal)),
            isBrowsingRestricted);
    }

    public IReadOnlyList<string> RoleClosure(PrincipalRef principal) => PrivilegeEffectivenessResolver.RoleClosure(principal, Principals);

    public PrivilegeEffectiveness Effectiveness(string privilege, PrivilegeScope scope, PrincipalRef principal) =>
        PrivilegeEffectivenessResolver.Resolve(privilege, scope, ResolvedGrantKeys(principal), InheritanceContext(principal));

    public PrivilegeInheritanceContext InheritanceContext(PrincipalRef principal)
    {
        var closure = RoleClosure(principal);
        var grants = new Dictionary<PrincipalRef, IReadOnlySet<PrincipalGrantKey>>();
        foreach (var role in closure)
        {
            var reference = new PrincipalRef(role);
            if (HasLoadedGrants(reference))
            {
                grants[reference] = ResolvedGrantKeys(reference);
            }
        }

        return new PrivilegeInheritanceContext(grants, closure, InheritsAutomatically(principal), Cascades);
    }

    // MARK: Editing

    /// <summary>Grants or revokes every privilege on every scope as one undo step.</summary>
    public void SetGranted(bool granted, IReadOnlyCollection<string> privileges, IReadOnlyCollection<PrivilegeScope> scopes, PrincipalRef principal, string? actionName = null)
    {
        if (privileges.Count == 0 || scopes.Count == 0)
        {
            return;
        }

        var previous = DeltaOf(principal);
        var baseline = BaselineKeys(principal);
        var delta = previous;
        foreach (var scope in scopes)
        {
            foreach (var privilege in privileges)
            {
                var key = new PrincipalGrantKey(privilege, scope);
                delta = delta.Stage(key, granted, baseline.Contains(key));
            }
        }

        if (!delta.SameAs(previous))
        {
            Commit(actionName ?? CoreStrings.Get(granted ? "Principal/UndoGrant" : "Principal/UndoRevoke"), _state with { Deltas = SetDelta(principal, delta) });
        }
    }

    /// <summary>Stages every privilege <paramref name="source"/> holds that <paramref name="target"/> lacks.</summary>
    public void CopyGrants(PrincipalRef source, PrincipalRef target)
    {
        var targetKeys = ResolvedGrantKeys(target);
        var baseline = BaselineKeys(target);
        var previous = DeltaOf(target);
        var delta = previous;
        foreach (var key in ResolvedGrantKeys(source).Where(k => !targetKeys.Contains(k)))
        {
            delta = delta.Stage(key, true, baseline.Contains(key));
        }

        if (!delta.SameAs(previous))
        {
            Commit(CoreStrings.Format("Principal/UndoCopyPrivileges", source), _state with { Deltas = SetDelta(target, delta) });
        }
    }

    public void StageCreate(PrincipalDefinition definition)
    {
        if (_state.Creates.Any(c => c.Ref == definition.Ref) || Principals.Any(p => p.Ref == definition.Ref))
        {
            return;
        }

        Commit(CoreStrings.Format("Principal/UndoCreate", definition.Ref), _state with { Creates = _state.Creates.Add(definition) });
    }

    public void UnstageCreate(PrincipalRef principal)
    {
        if (!_state.Creates.Any(c => c.Ref == principal))
        {
            return;
        }

        Commit(CoreStrings.Format("Principal/UndoRemove", principal), _state with
        {
            Creates = _state.Creates.RemoveAll(c => c.Ref == principal),
            Deltas = _state.Deltas.Remove(principal),
            Passwords = _state.Passwords.Remove(principal),
            Alters = _state.Alters.Remove(principal),
        });
    }

    public void StageDrop(PrincipalRef principal, PrincipalDropOptions options)
    {
        if (!_state.Drops.ContainsKey(principal))
        {
            Commit(CoreStrings.Format("Principal/UndoDrop", principal), _state with { Drops = _state.Drops.Add(principal, options) });
        }
    }

    /// <summary>
    /// Stages dropping several principals as one undo step, as a multi-row Drop is one action. A principal that exists
    /// only as a staged create is removed instead, since there is nothing on the server to drop.
    /// </summary>
    public void StageDrops(IReadOnlyCollection<PrincipalRef> principals, PrincipalDropOptions options, string? actionName = null)
    {
        var next = _state;
        foreach (var principal in principals)
        {
            if (next.Creates.Any(c => c.Ref == principal))
            {
                next = next with
                {
                    Creates = next.Creates.RemoveAll(c => c.Ref == principal),
                    Deltas = next.Deltas.Remove(principal),
                    Passwords = next.Passwords.Remove(principal),
                    Alters = next.Alters.Remove(principal),
                };
            }
            else if (!next.Drops.ContainsKey(principal) && Principals.Any(p => p.Ref == principal))
            {
                next = next with { Drops = next.Drops.Add(principal, options) };
            }
        }

        if (!ReferenceEquals(next, _state))
        {
            Commit(actionName ?? (principals.Count == 1 ? CoreStrings.Format("Principal/UndoDrop", principals.First()) : CoreStrings.Plural("Principal/UndoDropMany", principals.Count)), next);
        }
    }

    public void UnstageDrop(PrincipalRef principal)
    {
        if (_state.Drops.ContainsKey(principal))
        {
            Commit(CoreStrings.Format("Principal/UndoKeep", principal), _state with { Drops = _state.Drops.Remove(principal) });
        }
    }

    public void StageSetPassword(PrincipalRef principal, string password) =>
        Commit(CoreStrings.Format("Principal/UndoChangePassword", principal), _state with { Passwords = _state.Passwords.SetItem(principal, password) });

    /// <summary>
    /// Stages an attributes edit. On a staged create it folds into the CREATE, since there is nothing yet to ALTER; the
    /// form carries no password, so the fold keeps the one the create sheet set rather than creating the account without it.
    /// </summary>
    public void StageAlter(PrincipalRef principal, PrincipalDefinition definition)
    {
        var index = _state.Creates.FindIndex(c => c.Ref == principal);
        if (index >= 0)
        {
            var staged = _state.Creates[index];
            var folded = definition.HasPassword ? definition : definition with { Password = staged.Password };
            if (!folded.Equals(staged))
            {
                Commit(CoreStrings.Get("Principal/UndoChangeAttributes"), _state with { Creates = _state.Creates.SetItem(index, folded) });
            }

            return;
        }

        var original = Principals.FirstOrDefault(p => p.Ref == principal);
        var alters = original is not null && definition.Equals(PrincipalDefinition.From(original))
            ? _state.Alters.Remove(principal)
            : _state.Alters.SetItem(principal, definition);
        _state.Alters.TryGetValue(principal, out var before);
        alters.TryGetValue(principal, out var after);
        if (!Equals(before, after))
        {
            Commit(CoreStrings.Get("Principal/UndoChangeAttributes"), _state with { Alters = alters });
        }
    }

    public void Discard()
    {
        _state = EditState.Empty;
        _undo.Clear();
        _redo.Clear();
        StateChanged();
    }

    public void Undo() => Step(_undo, _redo);

    public void Redo() => Step(_redo, _undo);

    // MARK: Output

    /// <summary>
    /// Every staged change, in a stable order; <see cref="PrincipalScript"/> sorts them into run order. A rename runs
    /// with the alters, before passwords and grants, so those name the principal by its new name. A principal being
    /// dropped has its alter left out, since altering it first would only make the DROP name the wrong principal.
    /// </summary>
    public IReadOnlyList<PrincipalChange> PendingChanges()
    {
        var changes = new List<PrincipalChange>();
        var renames = new Dictionary<PrincipalRef, PrincipalRef>();
        changes.AddRange(_state.Creates.Select(c => new CreatePrincipal(c)));
        foreach (var (principal, definition) in _state.Alters.OrderBy(a => a.Key.DisplayName, StringComparer.Ordinal))
        {
            if (_state.Drops.ContainsKey(principal) || Principals.FirstOrDefault(p => p.Ref == principal) is not { } original)
            {
                continue;
            }

            changes.Add(new AlterPrincipal(PrincipalDefinition.From(original), definition));
            if (definition.Ref != principal)
            {
                renames[principal] = definition.Ref;
            }
        }

        PrincipalRef Current(PrincipalRef principal) => renames.TryGetValue(principal, out var renamed) ? renamed : principal;

        changes.AddRange(_state.Passwords.Where(p => !_state.Drops.ContainsKey(p.Key)).OrderBy(p => p.Key.DisplayName, StringComparer.Ordinal).Select(p => new SetPrincipalPassword(Current(p.Key), p.Value)));
        changes.AddRange(GrantChanges().Select(g => new ModifyGrants(g with { Principal = Current(g.Principal) })));
        changes.AddRange(_state.Drops.OrderBy(d => d.Key.DisplayName, StringComparer.Ordinal).Select(d => new DropPrincipal(d.Key, d.Value)));
        return changes;
    }

    /// <summary>
    /// The grant edits measured against the server, so a privilege ticked and unticked again is no change. A principal
    /// being dropped takes its grants with it, so its grant edits are left out.
    /// </summary>
    public IReadOnlyList<PrincipalGrantChanges> GrantChanges()
    {
        var result = new List<PrincipalGrantChanges>();
        foreach (var (principal, delta) in _state.Deltas.OrderBy(d => d.Key.DisplayName, StringComparer.Ordinal))
        {
            if (_state.Drops.ContainsKey(principal))
            {
                continue;
            }

            var baseline = BaselineKeys(principal);
            var added = delta.Added.Where(k => !baseline.Contains(k)).OrderBy(Order).ThenBy(k => k.Privilege, StringComparer.Ordinal)
                .Select(k => new PrincipalGrant(k.Privilege, k.Scope)).ToArray();
            var removed = delta.Removed.Where(baseline.Contains).OrderBy(Order).ThenBy(k => k.Privilege, StringComparer.Ordinal)
                .Select(k => new PrincipalGrant(k.Privilege, k.Scope, IsGrantable(k.Privilege, k.Scope, principal))).ToArray();
            if (added.Length > 0 || removed.Length > 0)
            {
                result.Add(new PrincipalGrantChanges(principal, added, removed));
            }
        }

        return result;

        static (PrivilegeLevel, string) Order(PrincipalGrantKey key) => (key.Scope.GrantTarget.Level, key.Scope.SortKey);
    }

    /// <summary>A warning when the edits would drop, alter or strip every privilege from the account this connection uses.</summary>
    public string? SelfImpact(PrincipalRef? connected)
    {
        if (connected is null)
        {
            return null;
        }

        bool Matches(PrincipalRef principal) => string.Equals(principal.Name, connected.Name, StringComparison.OrdinalIgnoreCase);

        if (_state.Drops.Keys.Any(Matches))
        {
            return CoreStrings.Format("Principal/SelfImpactDrop", connected.Name);
        }

        if (_state.Alters.Keys.Any(Matches))
        {
            return CoreStrings.Format("Principal/SelfImpactAlter", connected.Name);
        }

        var losesEverything = GrantChanges().Any(c => Matches(c.Principal) && ResolvedGrantKeys(c.Principal).Count == 0 && BaselineKeys(c.Principal).Count > 0);
        return losesEverything ? CoreStrings.Format("Principal/SelfImpactRevokeAll", connected.Name) : null;
    }

    // MARK: Bookkeeping

    private ImmutableHashSet<PrincipalGrantKey> BaselineKeys(PrincipalRef principal) =>
        _baselineKeys.TryGetValue(principal, out var keys) ? keys : ImmutableHashSet<PrincipalGrantKey>.Empty;

    private GrantDelta DeltaOf(PrincipalRef principal) =>
        _state.Deltas.TryGetValue(principal, out var delta) ? delta : GrantDelta.Empty;

    private int EffectiveGrantChangeCount(PrincipalRef principal)
    {
        if (!_state.Deltas.TryGetValue(principal, out var delta))
        {
            return 0;
        }

        var baseline = BaselineKeys(principal);
        return delta.Added.Count(k => !baseline.Contains(k)) + delta.Removed.Count(baseline.Contains);
    }

    private ImmutableDictionary<PrincipalRef, GrantDelta> SetDelta(PrincipalRef principal, GrantDelta delta) =>
        delta.IsEmpty ? _state.Deltas.Remove(principal) : _state.Deltas.SetItem(principal, delta);

    private bool InheritsAutomatically(PrincipalRef principal)
    {
        var info = Principals.FirstOrDefault(p => p.Ref == principal);
        var inherit = info?.Attributes.FirstOrDefault(a => a.Key == "INHERIT");
        return inherit?.IsEnabled ?? true;
    }

    private void Commit(string actionName, EditState next)
    {
        _undo.Add((actionName, _state));
        if (_undo.Count > UndoLimit)
        {
            _undo.RemoveAt(0);
        }

        _redo.Clear();
        _state = next;
        StateChanged();
    }

    private void Step(List<(string Name, EditState State)> from, List<(string Name, EditState State)> to)
    {
        if (from.Count == 0)
        {
            return;
        }

        var (name, state) = from[^1];
        from.RemoveAt(from.Count - 1);
        to.Add((name, _state));
        _state = state;
        StateChanged();
    }

    private void StateChanged()
    {
        _closureCache.Clear();
        var grants = _state.Deltas.Keys.Where(p => !_state.Drops.ContainsKey(p)).Sum(EffectiveGrantChangeCount);
        ChangeCount = _state.Creates.Count + _state.Drops.Count + _state.Passwords.Count + _state.Alters.Count + grants;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private sealed record GrantDelta(ImmutableHashSet<PrincipalGrantKey> Added, ImmutableHashSet<PrincipalGrantKey> Removed)
    {
        public static GrantDelta Empty { get; } = new(ImmutableHashSet<PrincipalGrantKey>.Empty, ImmutableHashSet<PrincipalGrantKey>.Empty);

        public bool IsEmpty => Added.IsEmpty && Removed.IsEmpty;

        /// <summary>A key set back to what the server has is no edit at all, so it leaves both sets.</summary>
        public GrantDelta Stage(PrincipalGrantKey key, bool granted, bool baselineHasKey)
        {
            if (granted == baselineHasKey)
            {
                return new GrantDelta(Added.Remove(key), Removed.Remove(key));
            }

            return granted ? new GrantDelta(Added.Add(key), Removed.Remove(key)) : new GrantDelta(Added.Remove(key), Removed.Add(key));
        }

        public bool Resolves(PrincipalGrantKey key, bool baselineHasKey) =>
            Added.Contains(key) || (!Removed.Contains(key) && baselineHasKey);

        public bool SameAs(GrantDelta other) => Added.SetEquals(other.Added) && Removed.SetEquals(other.Removed);
    }

    private sealed record EditState(
        ImmutableDictionary<PrincipalRef, GrantDelta> Deltas,
        ImmutableList<PrincipalDefinition> Creates,
        ImmutableDictionary<PrincipalRef, PrincipalDropOptions> Drops,
        ImmutableDictionary<PrincipalRef, string> Passwords,
        ImmutableDictionary<PrincipalRef, PrincipalDefinition> Alters)
    {
        public static EditState Empty { get; } = new(
            ImmutableDictionary<PrincipalRef, GrantDelta>.Empty,
            ImmutableList<PrincipalDefinition>.Empty,
            ImmutableDictionary<PrincipalRef, PrincipalDropOptions>.Empty,
            ImmutableDictionary<PrincipalRef, string>.Empty,
            ImmutableDictionary<PrincipalRef, PrincipalDefinition>.Empty);
    }
}
