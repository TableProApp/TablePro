using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.MySql;

/// <summary>Check constraints, partitions and table options for the structure tab.</summary>
public sealed partial class MySqlSession : ITableDetailsProvider
{
    private MySqlServer Server => MySqlServer.Parse(ServerVersion, IsMariaDb);

    public StructureEdits SupportedEdits =>
        (Server.HasCheckConstraints ? StructureEdits.CheckConstraints : StructureEdits.None)
        | StructureEdits.AddPartition | StructureEdits.DropPartition | StructureEdits.TruncatePartition | StructureEdits.TableOptions;

    public IReadOnlyList<TableOptionSpec> EditableTableOptions => MySqlDdl.TableOptionSpecs;

    public Task<TableDetails> GetTableDetailsAsync(ObjectName table, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var parameters = Bind(table);
                var server = Server;
                IReadOnlyList<CheckConstraintInfo> checks = [];
                if (server.HasCheckConstraints)
                {
                    checks = await QueryAsync(
                        connection,
                        server.IsMariaDb ? MySqlCatalog.MariaDbCheckConstraints : MySqlCatalog.MySqlCheckConstraints,
                        static r => new CheckConstraintInfo(r.GetString(0), ConstraintText.StripEnclosingParentheses(r.GetString(1)))
                        {
                            IsValidated = !string.Equals(NullableString(r, 2), "NO", StringComparison.OrdinalIgnoreCase),
                        },
                        ct,
                        parameters);
                }

                var options = await QueryAsync(
                    connection,
                    MySqlCatalog.TableOptions,
                    static r => MySqlDdl.ReadOptions(
                        NullableString(r, 0),
                        NullableString(r, 1),
                        NullableString(r, 2),
                        r.IsDBNull(3) ? null : Convert.ToUInt64(r.GetValue(3), CultureInfo.InvariantCulture),
                        NullableString(r, 4)),
                    ct,
                    parameters);

                var partitions = await QueryAsync(
                    connection,
                    MySqlCatalog.Partitions,
                    static r => new MySqlPartitionRow(
                        r.GetString(0),
                        NullableString(r, 1),
                        NullableString(r, 2),
                        NullableString(r, 3),
                        NullableString(r, 4),
                        Int32(r, 5),
                        Int32(r, 6),
                        Int64(r, 7),
                        Int64(r, 8),
                        NullableString(r, 9),
                        NullableString(r, 10)),
                    ct,
                    parameters);

                return new TableDetails(checks, MySqlDdl.Partitioning(partitions), options.Count > 0 ? options[0] : []);
            },
            cancellationToken);

    private static int? Int32(System.Data.Common.DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal), CultureInfo.InvariantCulture);

    private static long? Int64(System.Data.Common.DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : Convert.ToInt64(reader.GetValue(ordinal), CultureInfo.InvariantCulture);
}
