using System.Globalization;
using System.Text;
using TablePro.Core.Schema;

namespace TablePro.Ai.Prompts;

/// <summary>
/// Renders table structure for a prompt within a token budget. Tables come in the order given, so the caller puts the
/// ones the question and the editor name first; whole tables that do not fit drop to a list of names, then to a count.
/// </summary>
public static class SchemaContextBuilder
{
    public const int DefaultTokenBudget = 6_000;

    /// <summary>Roughly what one token holds in English and SQL for the providers' tokenizers.</summary>
    public const int CharactersPerToken = 4;

    private const string OtherTablesLead = "Other tables (structure not shown): ";

    public static int EstimateTokens(string text) =>
        string.IsNullOrEmpty(text) ? 0 : (text.Length + CharactersPerToken - 1) / CharactersPerToken;

    public static string Render(SchemaContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (context.Tables.Count == 0 || context.TokenBudget <= 0)
        {
            return string.Empty;
        }

        var budget = (long)context.TokenBudget * CharactersPerToken;
        var output = new StringBuilder();
        var block = new StringBuilder();
        var index = 0;
        for (; index < context.Tables.Count; index++)
        {
            block.Clear();
            AppendTable(block, context.Tables[index], context, int.MaxValue);
            var separator = output.Length > 0 ? 1 : 0;
            if (output.Length + separator + block.Length > budget)
            {
                break;
            }

            if (separator > 0)
            {
                output.Append('\n');
            }

            output.Append(block);
        }

        // The table the user asked about matters most, so a first table too big for the budget is cut, not dropped.
        if (index == 0)
        {
            AppendTable(output, context.Tables[0], context, budget);
            index = 1;
        }

        if (index < context.Tables.Count)
        {
            AppendOthers(output, context.Tables, index, budget);
        }

        return output.ToString();
    }

    private static void AppendTable(StringBuilder sb, TableStructure table, SchemaContext context, long budget)
    {
        var start = sb.Length;
        sb.Append("- ").Append(Name(table.Table, context.DefaultSchema));
        if (context.RowEstimates.TryGetValue(table.Table, out var rows) && rows >= 0)
        {
            sb.Append(CultureInfo.InvariantCulture, $" (~{rows} rows)");
        }

        var lines = new List<string>(table.Columns.Count + table.ForeignKeys.Count + table.Indexes.Count);
        foreach (var column in table.Columns.OrderBy(c => c.Ordinal))
        {
            var line = new StringBuilder("  - ").Append(Quote(column.Name)).Append(' ').Append(Flat(column.DataType.Trim()));
            if (column.IsPrimaryKey)
            {
                line.Append(" PK");
            }

            if (!column.IsNullable && !column.IsPrimaryKey)
            {
                line.Append(" NOT NULL");
            }

            if (column.IsIdentity)
            {
                line.Append(" IDENTITY");
            }

            if (!string.IsNullOrWhiteSpace(column.DefaultValue))
            {
                line.Append(" DEFAULT ").Append(Flat(column.DefaultValue.Trim()));
            }

            if (!string.IsNullOrWhiteSpace(column.Comment))
            {
                line.Append(" -- ").Append(Flat(column.Comment.Trim()));
            }

            lines.Add(line.ToString());
        }

        foreach (var fk in table.ForeignKeys)
        {
            lines.Add($"  FK ({QuoteList(fk.Columns)}) -> {Name(fk.ReferencedTable, context.DefaultSchema)} ({QuoteList(fk.ReferencedColumns)})");
        }

        foreach (var index in table.Indexes)
        {
            if (index.IsPrimary)
            {
                continue;
            }

            lines.Add($"  {(index.IsUnique ? "UNIQUE INDEX" : "INDEX")} {Quote(index.Name)} ({QuoteList(index.Columns)})");
        }

        for (var i = 0; i < lines.Count; i++)
        {
            if (sb.Length - start + 1 + lines[i].Length > budget)
            {
                sb.Append(CultureInfo.InvariantCulture, $"\n  ... {lines.Count - i} more lines not shown");
                return;
            }

            sb.Append('\n').Append(lines[i]);
        }
    }

    private static void AppendOthers(StringBuilder sb, IReadOnlyList<TableStructure> tables, int from, long budget)
    {
        var listed = 0;
        var start = sb.Length;
        sb.Append(sb.Length > 0 ? "\n" : string.Empty).Append(OtherTablesLead);
        for (var i = from; i < tables.Count; i++)
        {
            var name = Quote(tables[i].Table.ToString());
            var tailRoom = 32;
            if (sb.Length + name.Length + 2 + tailRoom > budget)
            {
                break;
            }

            if (listed > 0)
            {
                sb.Append(", ");
            }

            sb.Append(name);
            listed++;
        }

        var remaining = tables.Count - from - listed;
        if (listed == 0)
        {
            sb.Length = start;
            sb.Append(sb.Length > 0 ? "\n" : string.Empty).Append(CultureInfo.InvariantCulture, $"... and {remaining} more tables not shown.");
            return;
        }

        if (remaining > 0)
        {
            sb.Append(CultureInfo.InvariantCulture, $", and {remaining} more");
        }

        sb.Append('.');
    }

    /// <summary>A table outside the default schema carries its schema, so two tables of one name read as two.</summary>
    private static string Name(ObjectName name, string? defaultSchema) =>
        string.IsNullOrEmpty(name.Schema) || string.Equals(name.Schema, defaultSchema, StringComparison.OrdinalIgnoreCase)
            ? Quote(name.Name)
            : $"{Quote(name.Schema)}.{Quote(name.Name)}";

    private static string QuoteList(IReadOnlyList<string> names) => string.Join(", ", names.Select(Quote));

    /// <summary>A catalog name in double quotes on one line, so a name that reads like an instruction stays a name.</summary>
    internal static string Quote(string name) => string.Concat("\"", Flat(name).Replace("\"", "\"\"", StringComparison.Ordinal), "\"");

    internal static string Flat(string text)
    {
        if (!text.AsSpan().ContainsAnyInRange('\0', '\x1f') && !text.AsSpan().ContainsAnyInRange('\x7f', '\x9f'))
        {
            return text;
        }

        return string.Create(text.Length, text, static (span, source) =>
        {
            for (var i = 0; i < source.Length; i++)
            {
                span[i] = char.IsControl(source[i]) ? ' ' : source[i];
            }
        });
    }
}
