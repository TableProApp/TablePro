using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.SqlServer;

/// <summary>Check constraints and table options for the structure tab.</summary>
public sealed partial class SqlServerSession : ITableDetailsProvider
{
    public StructureEdits SupportedEdits => StructureEdits.CheckConstraints | StructureEdits.TableOptions;

    public IReadOnlyList<TableOptionSpec> EditableTableOptions => SqlServerDdl.TableOptionSpecs;

    public Task<TableDetails> GetTableDetailsAsync(ObjectName table, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var parameters = Bind(table);
                var rows = await QueryAsync(
                    connection,
                    SqlServerCatalog.CheckConstraints,
                    static r => (Name: r.GetString(0), Definition: r.GetString(1), NotTrusted: r.GetBoolean(2), Column: NullableString(r, 3)),
                    ct,
                    parameters);

                // One row per column the check reads, folded back into one constraint each, in the order they came.
                var checks = new List<CheckConstraintInfo>();
                foreach (var group in rows.GroupBy(r => r.Name, StringComparer.Ordinal))
                {
                    var first = group.First();
                    checks.Add(new CheckConstraintInfo(first.Name, ConstraintText.StripEnclosingParentheses(first.Definition))
                    {
                        IsValidated = !first.NotTrusted,
                        Columns = group.Where(r => r.Column is not null).Select(r => r.Column!).ToArray(),
                    });
                }

                var options = await QueryAsync(
                    connection,
                    SqlServerCatalog.TableOptions,
                    static r => SqlServerDdl.ReadOptions(NullableString(r, 0), NullableString(r, 1), NullableString(r, 2), NullableString(r, 3)),
                    ct,
                    parameters);

                return new TableDetails(checks, null, options.Count > 0 ? options[0] : []);
            },
            cancellationToken);
}
