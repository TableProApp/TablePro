using TablePro.App.Services;
using TablePro.Core.Connections;
using TablePro.Core.Copy;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.App.ViewModels;

/// <summary>
/// The state of Copy Objects: which objects of the current schema go, to which connection and schema, with what and
/// what to do about objects already there; then the plan the review shows and the run.
/// </summary>
public sealed class CopyObjectsViewModel
{
    private static readonly HashSet<ObjectKind> CopyableKinds =
        [ObjectKind.Table, ObjectKind.View, ObjectKind.MaterializedView, ObjectKind.Function, ObjectKind.Procedure, ObjectKind.Sequence];

    private readonly WorkspaceContext _context;

    public CopyObjectsViewModel(WorkspaceContext context, IReadOnlyList<DatabaseObject> preselected, CopyTargets targets)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(preselected);
        _context = context;
        Targets = targets;
        TargetProfile = targets.Profiles.Count > 0 ? targets.Profiles[0] : context.Session.Profile;

        // The picked objects first, then the rest of their schema, so a whole schema is a few clicks away.
        Objects = [.. preselected.Where(o => CopyableKinds.Contains(o.Kind)).Concat(context.Session.Objects.Where(o => CopyableKinds.Contains(o.Kind))).DistinctBy(o => (o.Kind, o.Name))];
        Selected = preselected.Select(o => (o.Kind, o.Name)).ToHashSet();
    }

    public CopyTargets Targets { get; }

    public IReadOnlyList<DatabaseObject> Objects { get; }

    public HashSet<(ObjectKind Kind, ObjectName Name)> Selected { get; }

    public ConnectionProfile TargetProfile { get; set; }

    public CopyContent Content { get; set; } = CopyContent.StructureAndData;

    public CopyExistingPolicy ExistingPolicy { get; set; } = CopyExistingPolicy.Skip;

    public CopyErrorHandling ErrorHandling { get; set; } = CopyErrorHandling.Stop;

    public string? TargetSchema { get; set; }

    public IReadOnlyList<string> TargetSchemas { get; private set; } = [];

    public CopyTargetLease? Lease { get; private set; }

    public CopyPlan? Plan { get; private set; }

    public string SourceName => _context.Session.Profile.Name;

    public bool IsSameConnection => TargetProfile.Id == _context.Session.Profile.Id;

    /// <summary>Why the chosen target cannot take this copy at all, before connecting to it.</summary>
    public string? Refusal => CopyTypeMapper.Refusal(_context.Session.Profile.Engine, TargetProfile.Engine);

    public IReadOnlyList<DatabaseObject> SelectedObjects => [.. Objects.Where(o => Selected.Contains((o.Kind, o.Name)))];

    /// <summary>Connects to the target and reads its schemas; false when the user cancelled a password prompt.</summary>
    public async Task<bool> ConnectAsync(CancellationToken cancellationToken)
    {
        Lease = await Targets.OpenAsync(TargetProfile, _context.Dialogs, cancellationToken);
        if (Lease is null)
        {
            return false;
        }

        var session = Lease.Session;
        TargetSchemas = session.Profile.Descriptor.HasSchemas ? await session.GetSchemasAsync(cancellationToken) : [];

        // The same schema name where the target has it, so a copy between twins lands where expected; within one
        // connection the current schema is the source, so the default is the connection's own.
        var sourceSchema = _context.Session.CurrentSchema;
        TargetSchema = TargetSchemas.Count == 0
            ? null
            : !IsSameConnection && sourceSchema is not null && TargetSchemas.Contains(sourceSchema, StringComparer.Ordinal) ? sourceSchema
            : session.DefaultSchema is { } preferred && TargetSchemas.Contains(preferred) && preferred != sourceSchema ? preferred
            : TargetSchemas.FirstOrDefault(s => s != sourceSchema) ?? TargetSchemas[0];
        return true;
    }

    public CopyRequest Request() => new(_context.Session.Database, SelectedObjects, Lease!.Session, TargetSchema, Content, ExistingPolicy, ErrorHandling);

    public async Task<CopyPlan> PlanAsync(CancellationToken cancellationToken)
    {
        Plan = await CopyPlanner.PlanAsync(Request(), cancellationToken);
        return Plan;
    }

    public Task<CopyResult> RunAsync(IProgress<CopyProgress> progress, CancellationToken cancellationToken) =>
        CopyRunner.RunAsync(Request(), Plan!, progress, cancellationToken);

    public async ValueTask ReleaseAsync()
    {
        if (Lease is not null)
        {
            await Lease.DisposeAsync();
            Lease = null;
        }
    }
}
