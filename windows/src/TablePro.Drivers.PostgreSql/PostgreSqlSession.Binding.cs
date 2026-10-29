using System.Data.Common;
using System.Globalization;
using Npgsql;
using NpgsqlTypes;
using TablePro.Core.Browse;
using TablePro.Core.Data;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.PostgreSql;

/// <summary>
/// Browsing, counting and saving with text values sent untyped. Npgsql types a string parameter as <c>text</c>, and
/// PostgreSQL will neither assign text to a json, uuid, inet, enum, interval or array column nor compare it with an
/// integer one. The grid hands those edits over as text and the filter strip binds every value as text, so they go out
/// as <see cref="NpgsqlDbType.Unknown"/> and the server reads each as the column's type, as it reads a quoted literal.
/// </summary>
public sealed partial class PostgreSqlSession
{
    public new Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var spec = Dialect.BuildBrowse(request);
                for (var attempt = 0; ; attempt++)
                {
                    await using var command = CreateUntypedCommand(connection, spec);
                    await using var reader = await command.ExecuteReaderAsync(ct);

                    // Npgsql reads the server's types once per data source, so an enum or domain created since then
                    // has no reader and every cell of its column showed an error. Reading the types again fixes it.
                    if (attempt == 0 && HasUnknownType(reader))
                    {
                        await reader.DisposeAsync();
                        await ((NpgsqlConnection)connection).ReloadTypesAsync(ct);
                        continue;
                    }

                    return await ResultSetReader.ReadAsync(reader, request.Limit, ct);
                }
            },
            cancellationToken);

    // What Npgsql names a column whose type it has not loaded.
    private const string UnknownTypeName = "-.-";

    private static bool HasUnknownType(NpgsqlDataReader reader)
    {
        for (var i = 0; i < reader.FieldCount; i++)
        {
            if (reader.GetDataTypeName(i) == UnknownTypeName)
            {
                return true;
            }
        }

        return false;
    }

    public new Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var command = CreateUntypedCommand(connection, Dialect.BuildCount(table, filter));
                return Convert.ToInt64(await command.ExecuteScalarAsync(ct), CultureInfo.InvariantCulture);
            },
            cancellationToken);

    protected override async Task<int> ExecuteChangeAsync(DbConnection connection, DbTransaction transaction, ObjectName table, RowChange change, CancellationToken cancellationToken)
    {
        var spec = ChangeSqlBuilder.Build(Dialect, table, change);
        await using var command = CreateUntypedCommand(connection, spec);
        command.Transaction = (NpgsqlTransaction)transaction;
        var affected = await command.ExecuteNonQueryAsync(cancellationToken);

        // An insert into a view or with a trigger can report other counts; only keyed changes must hit one row.
        return change is not RowInsert && affected != 1
            ? throw new RowCountMismatchException(1, affected, spec.Text)
            : Math.Max(affected, 0);
    }

    internal static NpgsqlParameter Parameter(string name, object? value) =>
        value is string or char
            ? new NpgsqlParameter(name, NpgsqlDbType.Unknown) { Value = value }
            : new NpgsqlParameter(name, value ?? DBNull.Value);

    private static NpgsqlCommand CreateUntypedCommand(DbConnection connection, SqlCommandSpec spec)
    {
        var command = ((NpgsqlConnection)connection).CreateCommand();
        command.CommandText = spec.Text;
        foreach (var (name, value) in spec.Parameters)
        {
            command.Parameters.Add(Parameter(name, value));
        }

        return command;
    }
}
