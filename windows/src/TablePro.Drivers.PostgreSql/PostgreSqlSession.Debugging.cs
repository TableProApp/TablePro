using Npgsql;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.PostgreSql;

/// <summary>
/// PL/pgSQL debugging through pldebugger's pldbgapi extension, in direct mode: no preload and no superuser needed, only
/// ownership of the routine and the extension in the database.
/// </summary>
public sealed partial class PostgreSqlSession : IRoutineDebugger
{
    // CockroachDB, Redshift and PGlite share this session but have no pldebugger, so they offer nothing to debug.
    private bool CanDebugRoutines => Profile.Engine == DatabaseEngine.PostgreSql;

    public RoutineDebugTarget? GetDebugTarget(DatabaseObject routine) => CanDebugRoutines ? PostgreSqlDebugProtocol.Target(routine) : null;

    public async Task<IReadOnlyList<RoutineDebugTarget>> GetDebugTargetsAsync(string? schema, CancellationToken cancellationToken)
    {
        if (!CanDebugRoutines)
        {
            return [];
        }

        await using var connection = await OpenDebugConnectionAsync(cancellationToken);
        var rows = await connection.QueryAsync(
            PostgreSqlDebugProtocol.TargetListQuery(connection.ServerVersion, byName: false),
            [SchemaOrDefault(schema)],
            cancellationToken);
        return [.. rows.Select(PostgreSqlDebugProtocol.Target).OfType<RoutineDebugTarget>()];
    }

    /// <summary>
    /// A sidebar entry is a name, so every debuggable overload of it becomes an entry point. With one overload its own
    /// refusal is the answer; with several, those that cannot be debugged are left out.
    /// </summary>
    public async Task<RoutineDebugPlan> PrepareDebugAsync(RoutineDebugTarget target, CancellationToken cancellationToken)
    {
        if (!CanDebugRoutines)
        {
            throw PostgreSqlDebugErrors.Unavailable();
        }

        await using var connection = await OpenDebugConnectionAsync(cancellationToken);
        IReadOnlyList<string> identities = target.Identity.Length > 0
            ? [target.Identity]
            : [.. (await connection.QueryAsync(
                    PostgreSqlDebugProtocol.TargetListQuery(connection.ServerVersion, byName: true),
                    [SchemaOrDefault(target.Name.Schema), target.Name.Name],
                    cancellationToken))
                .Select(row => row.Count > 0 ? row[0] : null)
                .OfType<string>()];
        if (identities.Count == 0)
        {
            throw PostgreSqlDebugErrors.NoOverloads(target.DisplayName);
        }

        var entryPoints = new List<DebugEntryPoint>();
        Exception? refusal = null;
        string? note = null;
        foreach (var identity in identities)
        {
            var oid = PostgreSqlDebugProtocol.Oid(identity) ?? throw PostgreSqlDebugErrors.RoutineNotFound(target.DisplayName);
            try
            {
                var routine = await PostgreSqlRoutineDebugSession.ReadRoutineAsync(connection, oid, target.DisplayName, cancellationToken);
                routine.DebuggerSchema();
                entryPoints.Add(routine.EntryPoint);
                note ??= routine.RunNote;
            }
            catch (RoutineDebugException ex)
            {
                refusal ??= ex;
            }
        }

        if (entryPoints.Count == 0)
        {
            throw refusal ?? PostgreSqlDebugErrors.NoOverloads(target.DisplayName);
        }

        // Any routine can write: a STABLE label does not stop a default such as nextval() or a volatile callee.
        return new RoutineDebugPlan(target, entryPoints, MayWrite: true, Note: note);
    }

    public Task RunPreparationAsync(RoutineDebugPreparation preparation, CancellationToken cancellationToken) => Task.CompletedTask;

    public async Task<IRoutineDebugSession> StartDebugAsync(RoutineDebugRequest request, CancellationToken cancellationToken)
    {
        if (!CanDebugRoutines)
        {
            throw PostgreSqlDebugErrors.Unavailable();
        }

        var target = await OpenDebugConnectionAsync(cancellationToken);
        IPostgreSqlDebugConnection proxy;
        try
        {
            proxy = await OpenDebugConnectionAsync(cancellationToken);
        }
        catch
        {
            await target.DisposeAsync();
            throw;
        }

        return await PostgreSqlRoutineDebugSession.StartAsync(target, proxy, OpenDebugConnectionAsync, request, cancellationToken);
    }

    /// <summary>
    /// A connection outside the pool, with the profile's startup commands, so the run's debugger state never reaches a
    /// connection the sidebar or an editor tab borrows later.
    /// </summary>
    private async Task<IPostgreSqlDebugConnection> OpenDebugConnectionAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var builder = new NpgsqlConnectionStringBuilder(PostgreSqlConnectionStringFactory.Build(Request))
        {
            Pooling = false,
            ApplicationName = "TablePro Debugger",
        };
        if (Request.Profile.UsesSignInToken())
        {
            builder.Password = await SignInTokens.GetAsync(Request.Profile, Request.Password, cancellationToken);
        }

        var connection = new NpgsqlConnection(builder.ConnectionString);
        try
        {
            await connection.OpenAsync(cancellationToken);
            foreach (var sql in _startupCommands)
            {
                await using var command = new NpgsqlCommand(sql, connection);
                await command.ExecuteNonQueryAsync(cancellationToken);
            }

            return new NpgsqlDebugConnection(connection);
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }
}
