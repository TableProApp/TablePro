using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.ClickHouse;

/// <summary>Check constraints, partitions and table options for the structure tab.</summary>
public sealed partial class ClickHouseSession : ITableDetailsProvider
{
    public StructureEdits SupportedEdits => StructureEdits.CheckConstraints | StructureEdits.DropPartition | StructureEdits.TableOptions;

    public IReadOnlyList<TableOptionSpec> EditableTableOptions => ClickHouseDdl.TableOptionSpecs;

    public Task<TableDetails> GetTableDetailsAsync(ObjectName table, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var parameters = Bind(table);
                var rows = await QueryAsync(
                    connection,
                    ClickHouseCatalog.TableDetails,
                    static r => (
                        Options: ClickHouseDdl.ReadOptions(NullableString(r, 0), NullableString(r, 2), NullableString(r, 3), NullableString(r, 4), NullableString(r, 5)),
                        PartitionKey: NullableString(r, 1),
                        Create: NullableString(r, 6) ?? string.Empty),
                    ct,
                    parameters);
                if (rows.Count == 0)
                {
                    return TableDetails.Empty;
                }

                var (options, partitionKey, create) = rows[0];
                PartitioningInfo? partitioning = null;
                if (!string.IsNullOrEmpty(partitionKey))
                {
                    var partitions = await QueryAsync(
                        connection,
                        ClickHouseCatalog.Partitions,
                        static r => new PartitionInfo(r.GetString(0), NullableString(r, 1))
                        {
                            RowEstimate = Convert.ToInt64(r.GetValue(2), CultureInfo.InvariantCulture),
                            SizeBytes = Convert.ToInt64(r.GetValue(3), CultureInfo.InvariantCulture),
                        },
                        ct,
                        parameters);
                    partitioning = new PartitioningInfo("PARTITION BY", partitionKey, partitions);
                }

                return new TableDetails(ClickHouseDdl.CheckConstraints(create), partitioning, options);
            },
            cancellationToken);
}
