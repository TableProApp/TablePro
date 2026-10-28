using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Oracle;

/// <summary>Check constraints, partitions and table options for the structure tab.</summary>
public sealed partial class OracleSession : ITableDetailsProvider
{
    public StructureEdits SupportedEdits =>
        StructureEdits.CheckConstraints | StructureEdits.AddPartition | StructureEdits.DropPartition | StructureEdits.TruncatePartition | StructureEdits.TableOptions;

    public IReadOnlyList<TableOptionSpec> EditableTableOptions => OracleDdl.TableOptionSpecs;

    public Task<TableDetails> GetTableDetailsAsync(ObjectName table, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var parameters = Bind(table);
                var rows = await OracleQueryAsync(
                    connection,
                    OracleCatalog.CheckConstraints,
                    static r => (Name: r.GetString(0), Condition: NullableString(r, 1) ?? string.Empty, Validated: NullableString(r, 2) != "NOT VALIDATED"),
                    ct,
                    parameters);
                var columns = (await OracleQueryAsync(connection, OracleCatalog.CheckConstraintColumns, static r => (Name: r.GetString(0), Column: r.GetString(1)), ct, parameters))
                    .ToLookup(r => r.Name, r => r.Column, StringComparer.Ordinal);
                var checks = rows
                    .Where(r => !OracleDdl.IsNotNullCheck(r.Condition))
                    .Select(r => new CheckConstraintInfo(r.Name, r.Condition.Trim()) { IsValidated = r.Validated, Columns = columns[r.Name].ToArray() })
                    .ToArray();

                var options = await OracleQueryAsync(
                    connection,
                    OracleCatalog.TableOptions,
                    static r => OracleDdl.ReadOptions(NullableString(r, 0), Int32(r, 1), NullableString(r, 2), NullableString(r, 3), NullableString(r, 4), NullableString(r, 5)),
                    ct,
                    parameters);

                return new TableDetails(checks, await ReadPartitioningAsync(connection, parameters, ct), options.Count > 0 ? options[0] : []);
            },
            cancellationToken);

    private static async Task<PartitioningInfo?> ReadPartitioningAsync(System.Data.Common.DbConnection connection, (string, object?)[] parameters, CancellationToken cancellationToken)
    {
        var schemes = await OracleQueryAsync(
            connection,
            OracleCatalog.Partitioning,
            static r => (Method: r.GetString(0), SubMethod: NullableString(r, 1), Key: NullableString(r, 2) ?? string.Empty, SubKey: NullableString(r, 3)),
            cancellationToken,
            parameters);
        if (schemes.Count == 0)
        {
            return null;
        }

        var scheme = schemes[0];
        var partitions = await OracleQueryAsync(
            connection,
            OracleCatalog.Partitions,
            r => new PartitionInfo(r.GetString(0), OracleDdl.PartitionBound(scheme.Method, NullableString(r, 1)))
            {
                Ordinal = Int32(r, 2),
                RowEstimate = Int64(r, 3),
                IsSubpartitioned = Int32(r, 4) is > 0,
            },
            cancellationToken,
            parameters);

        var list = new List<PartitionInfo>(partitions.Count);
        ILookup<string, PartitionInfo>? children = null;
        if (partitions.Any(p => p.IsSubpartitioned))
        {
            children = (await OracleQueryAsync(
                    connection,
                    OracleCatalog.Subpartitions,
                    static r => new PartitionInfo(r.GetString(1)) { Parent = r.GetString(0), Ordinal = Int32(r, 2), RowEstimate = Int64(r, 3) },
                    cancellationToken,
                    parameters))
                .ToLookup(p => p.Parent!, StringComparer.Ordinal);
        }

        foreach (var partition in partitions)
        {
            list.Add(partition);
            if (children is not null)
            {
                list.AddRange(children[partition.Name]);
            }
        }

        var subMethod = scheme.SubMethod is null or "NONE" ? null : $"{scheme.SubMethod} ({scheme.SubKey})";
        return new PartitioningInfo(scheme.Method, scheme.Key, list) { Subpartitioning = subMethod };
    }
}
