using System.Collections.Concurrent;
using Oracle.ManagedDataAccess.Client;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Oracle;

/// <summary>
/// PL/SQL debugging through DBMS_DEBUG. The macOS app tries DBMS_DEBUG_JDWP first when the database can connect back to
/// it; this port speaks only DBMS_DEBUG, which the macOS app falls back to and which needs nothing but two client sessions.
/// </summary>
public sealed partial class OracleSession : IRoutineDebugger
{
    private const string EnableServerOutput = "CALL SYS.DBMS_OUTPUT.ENABLE(NULL)";

    // The entry points the last plan read, so the start does not read them again; keyed by entry identity.
    private readonly ConcurrentDictionary<string, OracleDebugEntryPoint> _debugEntryPoints = new(StringComparer.Ordinal);

    public RoutineDebugTarget? GetDebugTarget(DatabaseObject routine)
    {
        OracleDebugUnitKind? kind = routine.Kind switch
        {
            ObjectKind.Procedure when routine.Comment == OracleDdl.PackageMarker => OracleDebugUnitKind.PackageBody,
            ObjectKind.Procedure => OracleDebugUnitKind.Procedure,
            ObjectKind.Function => OracleDebugUnitKind.Function,
            _ => null,
        };
        return kind is { } k && (routine.Name.Schema ?? _defaultSchema) is { } owner ? Target(new OracleDebugUnit(owner, routine.Name.Name, k)) : null;
    }

    public async Task<IReadOnlyList<RoutineDebugTarget>> GetDebugTargetsAsync(string? schema, CancellationToken cancellationToken)
    {
        var owner = Owner(schema);
        await using var channel = await OpenDebugChannelAsync(cancellationToken);
        var rows = await channel.QueryAsync(OracleDebugStatements.Targets(owner), cancellationToken);
        return
        [
            .. rows
                .Where(r => r.Count > 1 && r[0] is not null && OracleDebugUnitKinds.FromTypeName(r[1]) is not null)
                .Select(r => Target(new OracleDebugUnit(owner, r[0]!, OracleDebugUnitKinds.FromTypeName(r[1])!.Value))),
        ];
    }

    public async Task<RoutineDebugPlan> PrepareDebugAsync(RoutineDebugTarget target, CancellationToken cancellationToken)
    {
        var unit = OracleDebugUnit.FromIdentity(target.Identity) ?? throw new RoutineDebugException(OracleDebugText.UnitUnreadable(target.DisplayName), (string?)null);
        await using var channel = await OpenDebugChannelAsync(cancellationToken);
        var privileges = await channel.QueryAsync(OracleDebugStatements.Privileges(unit), cancellationToken);
        if (OracleDebugStatements.MissingPrivilege(privileges.Count > 0 ? privileges[0] : [], unit) is { } missing)
        {
            throw OracleDebugText.MissingPrivilege(missing, unit);
        }

        var readiness = await channel.QueryAsync(OracleDebugStatements.Readiness(unit), cancellationToken);
        RoutineDebugPreparation? preparation = OracleDebugStatements.ReadinessOf(readiness.Count > 0 ? readiness[0] : null) switch
        {
            OracleDebugReadiness.NotVisible => throw new RoutineDebugException(OracleDebugText.UnitUnreadable(target.DisplayName), (string?)null),
            OracleDebugReadiness.NeedsDebugCompile => new RoutineDebugPreparation(
                $"{target.DisplayName} isn't compiled for debugging.",
                OracleDebugText.CompileForDebug(unit.Kind),
                "Compile for Debug",
                [unit.Kind.CompileForDebugStatement(unit.Owner, unit.Name)]),
            _ => null,
        };

        var entryPoints = OracleDebugStatements.ParseEntryPoints(await channel.QueryAsync(OracleDebugStatements.EntryPoints(unit), cancellationToken), unit);
        if (entryPoints.Count == 0)
        {
            throw new RoutineDebugException(OracleDebugText.NoEntryPoints(target.DisplayName), (string?)null);
        }

        foreach (var stale in _debugEntryPoints.Where(p => p.Value.Entry.Unit == unit.CodeUnit).Select(p => p.Key).ToArray())
        {
            _debugEntryPoints.TryRemove(stale, out _);
        }

        foreach (var entryPoint in entryPoints)
        {
            _debugEntryPoints[entryPoint.Entry.Identity] = entryPoint;
        }

        return new RoutineDebugPlan(target, [.. entryPoints.Select(EntryPoint)], MayWrite: true, preparation, OracleDebugText.RunNote);
    }

    public async Task RunPreparationAsync(RoutineDebugPreparation preparation, CancellationToken cancellationToken)
    {
        await using var channel = await OpenDebugChannelAsync(cancellationToken);
        await using var registration = cancellationToken.Register(channel.Cancel);
        foreach (var statement in preparation.Statements)
        {
            await channel.ExecuteAsync(statement, cancellationToken: cancellationToken);
        }
    }

    public async Task<IRoutineDebugSession> StartDebugAsync(RoutineDebugRequest request, CancellationToken cancellationToken)
    {
        var entry = OracleDebugEntry.FromIdentity(request.EntryPoint.Identity)
            ?? throw new RoutineDebugException(OracleDebugText.UnitUnreadable(request.EntryPoint.DisplayName), (string?)null);
        var supervisor = await OpenDebugChannelAsync(cancellationToken);
        IOracleDebugChannel target;
        OracleDebugEntryPoint entryPoint;
        IReadOnlyList<OracleDebugEntryPoint> overloads;
        try
        {
            if (_debugEntryPoints.TryGetValue(entry.Identity, out var cached))
            {
                entryPoint = cached;
                overloads = [.. _debugEntryPoints.Values.Where(e => e.Entry.Unit == entry.Unit && e.Entry.Subprogram == entry.Subprogram)];
            }
            else
            {
                var all = OracleDebugStatements.ParseEntryPoints(await supervisor.QueryAsync(OracleDebugStatements.EntryPoints(entry.Unit), cancellationToken), entry.Unit);
                entryPoint = all.FirstOrDefault(e => e.Entry == entry) ?? throw new RoutineDebugException(OracleDebugText.NoEntryPoints(entry.Subprogram), (string?)null);
                overloads = [.. all.Where(e => e.Entry.Subprogram == entry.Subprogram)];
            }

            target = await OpenDebugChannelAsync(cancellationToken);
        }
        catch
        {
            await supervisor.DisposeAsync();
            throw;
        }

        return await OracleDbmsDebugSession.LaunchAsync(target, supervisor, entryPoint, overloads, request, cancellationToken);
    }

    private static RoutineDebugTarget Target(OracleDebugUnit unit) =>
        new(unit.Identity, new ObjectName(unit.Owner, unit.Name), unit.Name, unit.Kind.DisplayName());

    private static DebugEntryPoint EntryPoint(OracleDebugEntryPoint entryPoint) => new(
        entryPoint.Entry.Identity,
        entryPoint.DisplayName,
        [
            .. entryPoint.Parameters.Select(p => new DebugParameter(
                p.Name,
                p.DisplayType,
                p.Mode switch
                {
                    OracleDebugParameterMode.Output => DebugParameterMode.Output,
                    OracleDebugParameterMode.InputOutput => DebugParameterMode.InputOutput,
                    _ => DebugParameterMode.Input,
                },
                p.HasDefault)),
        ]);

    /// <summary>
    /// A connection outside the pool, with the session's NLS settings and startup statements, so arguments convert in the
    /// formats the editor shows and debug mode never reaches a pooled connection.
    /// </summary>
    private async Task<IOracleDebugChannel> OpenDebugChannelAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var builder = new OracleConnectionStringBuilder(_connectionString) { Pooling = false };
        var connection = new OracleConnection(builder.ConnectionString) { SuppressGetDecimalInvalidCastException = true };
        try
        {
            await connection.OpenAsync(cancellationToken);
            var channel = new OracleDebugChannel(connection);
            await channel.ExecuteAsync(OracleCatalog.SessionSettings, cancellationToken: cancellationToken);

            // The invocation block reads the routine's DBMS_OUTPUT lines, which the server buffers only once enabled.
            // A CALL resolves SYS at SQL level, so a package named SYS in the session's schema cannot capture it.
            await channel.ExecuteAsync(EnableServerOutput, cancellationToken: cancellationToken);
            foreach (var statement in _startupStatements)
            {
                await channel.ExecuteAsync(statement, cancellationToken: cancellationToken);
            }

            return channel;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }
}
