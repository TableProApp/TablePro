using System.Globalization;
using System.Text;
using System.Text.Json;
using TablePro.Core.Results;

namespace TablePro.Core.Plans;

/// <summary>
/// Turns the result sets a plan request produced into the one block of text its parser reads. One rule for every entry
/// point, so the Explain action and a hand-typed EXPLAIN produce identical text.
/// </summary>
public static class PlanText
{
    private const string ShowplanStart = "<ShowPlanXML";

    public static string FromResults(PlanFormat format, IReadOnlyList<ResultSet> results)
    {
        ArgumentNullException.ThrowIfNull(results);
        if (results.Count == 0)
        {
            return string.Empty;
        }

        return format switch
        {
            // An actual plan arrives after the statement's own result sets, so the plan is whichever cell holds one.
            PlanFormat.SqlServerShowplanXml => Showplans(results),
            PlanFormat.OraclePlanRows => RowsAsJson(results[^1]),
            _ => Flatten(results[^1]),
        };
    }

    /// <summary>Columns joined by tabs and rows by newlines, nulls left out, values spelled invariantly.</summary>
    public static string Flatten(ResultSet result)
    {
        ArgumentNullException.ThrowIfNull(result);
        var text = new StringBuilder();
        foreach (var row in result.Rows)
        {
            if (text.Length > 0)
            {
                text.Append('\n');
            }

            var first = true;
            foreach (var value in row)
            {
                if (value is null)
                {
                    continue;
                }

                if (!first)
                {
                    text.Append('\t');
                }

                text.Append(Spell(value));
                first = false;
            }
        }

        return text.ToString();
    }

    private static string Showplans(IReadOnlyList<ResultSet> results)
    {
        var text = new StringBuilder();
        foreach (var result in results)
        {
            foreach (var row in result.Rows)
            {
                foreach (var value in row)
                {
                    if (value is string s && s.Contains(ShowplanStart, StringComparison.Ordinal))
                    {
                        text.Append(s).Append('\n');
                    }
                }
            }
        }

        return text.ToString();
    }

    /// <summary>The rows as an array of objects keyed by column name, which is the shape the Oracle parser reads.</summary>
    private static string RowsAsJson(ResultSet result)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartArray();
            foreach (var row in result.Rows)
            {
                writer.WriteStartObject();
                for (var i = 0; i < row.Length && i < result.Columns.Count; i++)
                {
                    var name = result.Columns[i].Name.ToUpperInvariant();
                    switch (row[i])
                    {
                        case null:
                            break;
                        case string s:
                            writer.WriteString(name, s);
                            break;
                        case IConvertible number when result.Columns[i].IsNumeric:
                            writer.WriteNumber(name, number.ToDouble(CultureInfo.InvariantCulture));
                            break;
                        case var other:
                            writer.WriteString(name, Spell(other));
                            break;
                    }
                }

                writer.WriteEndObject();
            }

            writer.WriteEndArray();
        }

        return Encoding.UTF8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length);
    }

    private static string Spell(object value) => value switch
    {
        string s => s,
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString() ?? string.Empty,
    };
}
