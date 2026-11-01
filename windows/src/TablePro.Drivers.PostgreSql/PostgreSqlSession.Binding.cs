using System.Data.Common;
using Npgsql;
using NpgsqlTypes;

namespace TablePro.Drivers.PostgreSql;

/// <summary>
/// Browsing, counting and saving with text values sent untyped. Npgsql types a string parameter as <c>text</c>, and
/// PostgreSQL will neither assign text to a json, uuid, inet, enum, interval or array column nor compare it with an
/// integer one. The grid hands those edits over as text and the filter strip binds every value as text, so they go out
/// as <see cref="NpgsqlDbType.Unknown"/> and the server reads each as the column's type, as it reads a quoted literal.
/// </summary>
public sealed partial class PostgreSqlSession
{
    // What Npgsql names a column whose type it has not loaded.
    private const string UnknownTypeName = "-.-";

    protected override DbParameter CreateParameter(DbCommand command, string name, object? value) => Parameter(name, value);

    /// <summary>
    /// Npgsql reads the server's types once per connection, so an enum or domain created since then has no reader and
    /// every cell of its column showed an error until the tab reconnected.
    /// </summary>
    protected override bool HasUnreadableColumns(DbDataReader reader)
    {
        ArgumentNullException.ThrowIfNull(reader);
        for (var i = 0; i < reader.FieldCount; i++)
        {
            if (reader.GetDataTypeName(i) == UnknownTypeName)
            {
                return true;
            }
        }

        return false;
    }

    protected override Task ReloadTypesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        ((NpgsqlConnection)connection).ReloadTypesAsync(cancellationToken);

    protected override bool ChangesServerTypes(string statement) => PostgreSqlDdl.ChangesTypes(statement);

    internal static NpgsqlParameter Parameter(string name, object? value) =>
        value is string or char
            ? new NpgsqlParameter(name, NpgsqlDbType.Unknown) { Value = value }
            : new NpgsqlParameter(name, value ?? DBNull.Value);
}
