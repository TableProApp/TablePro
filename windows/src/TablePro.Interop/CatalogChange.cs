using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// What the engine does to whole tables, schemas and databases, so a menu offers only those.
public sealed record CatalogAbilities(
    bool TruncateTable,
    bool TruncateCascade,
    bool TruncateRestartIdentity,
    bool TruncateRefusedWhenReferenced,
    bool DropTable,
    bool DropTableCascade,
    bool CreateSchema,
    bool DropSchema,
    bool DropSchemaCascade,
    bool SchemaOwner,
    bool CreateDatabase,
    bool DropDatabase,
    bool DropDatabaseForce,
    DatabaseFields DatabaseFields,
    bool Keyspaces,
    bool OnCluster)
{
    public static CatalogAbilities None { get; } = new(
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        DatabaseFields.None, false, false);
}

// The options a new database takes beside its name.
public sealed record DatabaseFields(
    bool Owner,
    bool Template,
    bool Encoding,
    bool Locale,
    bool CharacterSet,
    bool Collation,
    bool Replication,
    bool Tablets,
    bool FirstCollection)
{
    public static DatabaseFields None { get; } = new(false, false, false, false, false, false, false, false, false);
}

public sealed record CharacterSet(string Name, string DefaultCollation, IReadOnlyList<string> Collations);

// What the server offers for a new database's options; an empty list leaves only the server's default.
public sealed record NewDatabaseChoices(
    IReadOnlyList<string> Owners,
    IReadOnlyList<string> Templates,
    IReadOnlyList<string> Encodings,
    IReadOnlyList<string> Locales,
    IReadOnlyList<CharacterSet> CharacterSets,
    IReadOnlyList<string> Collations,
    IReadOnlyList<string> Clusters,
    IReadOnlyList<string> DataCenters,
    string? DefaultOwner,
    string? DefaultEncoding,
    string? DefaultLocale,
    string? DefaultCharacterSet,
    string? DefaultCollation)
{
    public static NewDatabaseChoices None { get; } = new([], [], [], [], [], [], [], [], null, null, null, null, null);
}

public sealed record DataCenterReplicas(string DataCenter, int Replicas);

public abstract record KeyspaceReplication
{
    private KeyspaceReplication()
    {
    }

    public sealed record Simple(int Factor) : KeyspaceReplication;

    public sealed record NetworkTopology(IReadOnlyList<DataCenterReplicas> Factors) : KeyspaceReplication;
}

// A new database or keyspace; null leaves an option to the server.
public sealed record DatabaseDraft(string Name)
{
    public string? Owner { get; init; }

    public string? Template { get; init; }

    public string? Encoding { get; init; }

    public string? Locale { get; init; }

    public string? CharacterSet { get; init; }

    public string? Collation { get; init; }

    public string? Cluster { get; init; }

    public KeyspaceReplication? Replication { get; init; }

    public bool DurableWrites { get; init; } = true;

    public bool? Tablets { get; init; }

    public string? FirstCollection { get; init; }
}

public abstract record CatalogOperation
{
    private CatalogOperation()
    {
    }

    public sealed record TruncateTable(TableName Table, bool Cascade, bool RestartIdentity, string? Cluster)
        : CatalogOperation;

    public sealed record DropTable(TableName Table, bool Cascade) : CatalogOperation;

    public sealed record CreateSchema(string Name, string? Owner) : CatalogOperation;

    public sealed record DropSchema(string Name, bool Cascade) : CatalogOperation;

    public sealed record CreateDatabase(DatabaseDraft Draft) : CatalogOperation;

    public sealed record DropDatabase(string Name, bool Force, string? Cluster) : CatalogOperation;
}

public abstract record CatalogChangeOutcome
{
    private CatalogChangeOutcome()
    {
    }

    public sealed record Done : CatalogChangeOutcome
    {
        public static Done Instance { get; } = new();
    }

    // Nothing changed.
    public sealed record Failed(CoreError Error) : CatalogChangeOutcome;

    // The change may have landed in part or in full.
    public sealed record Unknown(CoreError Error) : CatalogChangeOutcome;
}

// One catalog change, which runs only the statements it was planned with, once.
public sealed class CatalogChange : IDisposable
{
    private readonly Native.CatalogChange _change;

    internal CatalogChange(Native.CatalogChange change, CatalogOperation operation)
    {
        _change = change;
        Operation = operation;
        Statements = change.Statements();
        Gate = Mapping.Gate(change.Gate());
        IsDestructive = change.Destructive();
    }

    // What was planned, with the options it was planned with.
    public CatalogOperation Operation { get; }

    public IReadOnlyList<string> Statements { get; }

    // Emptying or dropping asks at every level but Read-only, which refuses; creating asks where writes ask.
    public SaveGate Gate { get; }

    public bool IsDestructive { get; }

    // Confirmed says the gate's question was answered; nothing is sent when the level or the plan moved since.
    public async Task<CatalogChangeOutcome> RunAsync(bool confirmed, CancellationToken cancellationToken = default)
    {
        var outcome = await CoreCall.RunAsync(token => _change.Run(confirmed, token), cancellationToken)
            .ConfigureAwait(false);
        return outcome switch
        {
            Native.CatalogChangeOutcome.Done => CatalogChangeOutcome.Done.Instance,
            Native.CatalogChangeOutcome.Failed failed => new CatalogChangeOutcome.Failed(Mapping.Error(failed.Error)),
            Native.CatalogChangeOutcome.Unknown unknown => new CatalogChangeOutcome.Unknown(Mapping.Error(unknown.Error)),
            _ => throw new InvalidOperationException("The core reported a catalog outcome this build does not know."),
        };
    }

    public void Dispose() => _change.Dispose();
}

public sealed partial class DatabaseSession
{
    // Read again on each call, since a reconnect can reach another server version.
    public CatalogAbilities CatalogAbilities => Catalog.Abilities(_session.CatalogAbilities());

    public bool ProtectsDatabase(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return _session.ProtectsDatabase(name);
    }

    public bool ProtectsSchema(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return _session.ProtectsSchema(name);
    }

    public async Task<NewDatabaseChoices> GetDatabaseChoicesAsync(CancellationToken cancellationToken = default)
    {
        var choices = await CoreCall.RunAsync(token => _session.DatabaseChoices(token), cancellationToken)
            .ConfigureAwait(false);
        return Catalog.Choices(choices);
    }

    // At the connection's Safe Mode level now; an option or name the engine cannot take throws a catalog.* code.
    public CatalogChange PlanCatalogChange(CatalogOperation operation)
    {
        ArgumentNullException.ThrowIfNull(operation);
        var native = Catalog.Operation(operation);
        return new CatalogChange(CoreCall.Run(() => _session.PlanCatalogChange(native)), operation);
    }

    // Read again from the server, as after a schema was created or dropped.
    public async Task<IReadOnlyList<SchemaEntry>> RefreshSchemasAsync(CancellationToken cancellationToken = default)
    {
        var schemas = await CoreCall.RunAsync(token => _session.RefreshSchemas(token), cancellationToken)
            .ConfigureAwait(false);
        return [.. schemas.Select(Mapping.Schema)];
    }
}

internal static class Catalog
{
    public static CatalogAbilities Abilities(Native.CatalogAbilities abilities)
    {
        var fields = abilities.DatabaseFields;
        return new CatalogAbilities(
            abilities.TruncateTable,
            abilities.TruncateCascade,
            abilities.TruncateRestartIdentity,
            abilities.TruncateRefusedWhenReferenced,
            abilities.DropTable,
            abilities.DropTableCascade,
            abilities.CreateSchema,
            abilities.DropSchema,
            abilities.DropSchemaCascade,
            abilities.SchemaOwner,
            abilities.CreateDatabase,
            abilities.DropDatabase,
            abilities.DropDatabaseForce,
            new DatabaseFields(
                fields.Owner,
                fields.Template,
                fields.Encoding,
                fields.Locale,
                fields.CharacterSet,
                fields.Collation,
                fields.Replication,
                fields.Tablets,
                fields.FirstCollection),
            abilities.Keyspaces,
            abilities.OnCluster);
    }

    public static NewDatabaseChoices Choices(Native.DatabaseChoicesInfo choices) => new(
        choices.Owners,
        choices.Templates,
        choices.Encodings,
        choices.Locales,
        [.. choices.CharacterSets.Select(set => new CharacterSet(set.Name, set.DefaultCollation, set.Collations))],
        choices.Collations,
        choices.Clusters,
        choices.DataCenters,
        choices.DefaultOwner,
        choices.DefaultEncoding,
        choices.DefaultLocale,
        choices.DefaultCharacterSet,
        choices.DefaultCollation);

    public static Native.CatalogOperation Operation(CatalogOperation operation) => operation switch
    {
        CatalogOperation.TruncateTable truncate => new Native.CatalogOperation.TruncateTable(
            Mapping.Table(truncate.Table), truncate.Cascade, truncate.RestartIdentity, truncate.Cluster),
        CatalogOperation.DropTable drop => new Native.CatalogOperation.DropTable(Mapping.Table(drop.Table), drop.Cascade),
        CatalogOperation.CreateSchema create => new Native.CatalogOperation.CreateSchema(create.Name, create.Owner),
        CatalogOperation.DropSchema drop => new Native.CatalogOperation.DropSchema(drop.Name, drop.Cascade),
        CatalogOperation.CreateDatabase create => new Native.CatalogOperation.CreateDatabase(Draft(create.Draft)),
        CatalogOperation.DropDatabase drop => new Native.CatalogOperation.DropDatabase(drop.Name, drop.Force, drop.Cluster),
        _ => throw new ArgumentOutOfRangeException(nameof(operation), operation, "A catalog operation the core does not know."),
    };

    private static Native.DatabaseDraftArg Draft(DatabaseDraft draft) => new(
        draft.Name,
        draft.Owner,
        draft.Template,
        draft.Encoding,
        draft.Locale,
        draft.CharacterSet,
        draft.Collation,
        draft.Cluster,
        draft.Replication switch
        {
            null => null,
            KeyspaceReplication.Simple simple => new Native.ReplicationArg.Simple(checked((uint)simple.Factor)),
            KeyspaceReplication.NetworkTopology topology => new Native.ReplicationArg.NetworkTopology(
                [.. topology.Factors.Select(factor =>
                    new Native.DataCenterReplicas(factor.DataCenter, checked((uint)factor.Replicas)))]),
            _ => throw new ArgumentOutOfRangeException(nameof(draft), draft.Replication, "A replication the core does not know."),
        },
        draft.DurableWrites,
        draft.Tablets,
        draft.FirstCollection);
}
