using System.Collections;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.DuckDb;

/// <summary>Check constraints, shown read-only, and the table comment for the structure tab.</summary>
public sealed partial class DuckDbSession : ITableDetailsProvider
{
    public StructureEdits SupportedEdits => StructureEdits.TableOptions;

    public IReadOnlyList<TableOptionSpec> EditableTableOptions => DuckDbDdl.TableOptionSpecs;

    public Task<TableDetails> GetTableDetailsAsync(ObjectName table, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var parameters = Bind(table);
                var position = 0;
                var checks = await QueryAsync(
                    connection,
                    DuckDbCatalog.CheckConstraints,
                    r => new CheckConstraintInfo(
                        NullableString(r, 0) ?? string.Concat(table.Name, "_check_", (++position).ToString(System.Globalization.CultureInfo.InvariantCulture)),
                        ConstraintText.StripEnclosingParentheses(NullableString(r, 1) ?? string.Empty))
                    {
                        Columns = r.IsDBNull(2) ? [] : Strings(r.GetValue(2)),
                    },
                    ct,
                    parameters);
                var comment = await ScalarAsync(connection, DuckDbCatalog.TableComment, ct, parameters) as string;
                return new TableDetails(checks, null, [new TableOption(TableOptionNames.Comment, string.IsNullOrEmpty(comment) ? null : comment)]);
            },
            cancellationToken);

    // DuckDB.NET hands a LIST column back as a typed list; only its strings matter here.
    private static string[] Strings(object value) =>
        value is IEnumerable items and not string ? items.Cast<object?>().Select(i => Convert.ToString(i, System.Globalization.CultureInfo.InvariantCulture) ?? string.Empty).ToArray() : [];
}
