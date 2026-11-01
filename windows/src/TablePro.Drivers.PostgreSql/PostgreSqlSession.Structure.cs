using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.PostgreSql;

/// <summary>Check constraints, partitions and table options for the structure tab.</summary>
public sealed partial class PostgreSqlSession : ITableDetailsProvider
{
    public StructureEdits SupportedEdits =>
        StructureEdits.CheckConstraints | StructureEdits.AddPartition | StructureEdits.DropPartition | StructureEdits.TruncatePartition | StructureEdits.TableOptions;

    public IReadOnlyList<TableOptionSpec> EditableTableOptions => PostgreSqlDdl.TableOptionSpecs;

    public Task<TableDetails> GetTableDetailsAsync(ObjectName table, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var parameters = Bind(table);
                var checks = await QueryAsync(
                    connection,
                    PostgreSqlCatalog.CheckConstraints,
                    static r => new CheckConstraintInfo(r.GetString(0), ConstraintText.CheckClauseExpression(r.GetString(1)))
                    {
                        IsValidated = r.GetBoolean(2),
                        Columns = r.GetFieldValue<string[]>(3),
                    },
                    ct,
                    parameters);

                var rows = await QueryAsync(
                    connection,
                    PostgreSqlCatalog.TableOptions,
                    static r => (
                        Options: PostgreSqlDdl.ReadOptions(NullableString(r, 0), r.IsDBNull(1) ? [] : r.GetFieldValue<string[]>(1), r.GetString(2), NullableString(r, 3)),
                        PartitionKey: NullableString(r, 4)),
                    ct,
                    parameters);
                if (rows.Count == 0)
                {
                    return new TableDetails(checks, null, []);
                }

                var (options, partitionKey) = rows[0];
                PartitioningInfo? partitioning = null;
                if (partitionKey is not null)
                {
                    var partitions = await QueryAsync(
                        connection,
                        PostgreSqlCatalog.Partitions,
                        static r => new PartitionInfo(r.GetString(0), NullableString(r, 2))
                        {
                            Schema = r.GetString(1),
                            IsSubpartitioned = r.GetBoolean(3),
                            RowEstimate = r.IsDBNull(4) ? null : r.GetInt64(4),
                            SizeBytes = r.IsDBNull(5) ? null : r.GetInt64(5),
                            IsRelation = true,
                        },
                        ct,
                        parameters);
                    var (method, key) = PostgreSqlDdl.SplitPartitionKey(partitionKey);
                    partitioning = new PartitioningInfo(method, key, partitions);
                }

                return new TableDetails(checks, partitioning, options);
            },
            cancellationToken);
}
