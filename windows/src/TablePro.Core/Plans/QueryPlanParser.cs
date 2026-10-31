using TablePro.Core.Plans.Parsers;

namespace TablePro.Core.Plans;

/// <summary>Maps a plan format to the parser that reads it. Every parser is pure: text in, a plan or null out.</summary>
public static class QueryPlanParser
{
    public static bool CanParse(PlanFormat format) => format != PlanFormat.PlainText;

    /// <summary>The plan, or null when the text is not one this format's parser can read.</summary>
    public static QueryPlan? Parse(string rawText, PlanFormat format)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        if (string.IsNullOrWhiteSpace(rawText))
        {
            return null;
        }

        return format switch
        {
            PlanFormat.PostgresJson => PostgreSqlPlanParser.Parse(rawText),
            PlanFormat.MySql => MySqlPlanParser.Parse(rawText),
            PlanFormat.SqliteQueryPlan => SqlitePlanParser.Parse(rawText),
            PlanFormat.CockroachText => CockroachDbPlanParser.Parse(rawText),
            PlanFormat.IndentedText => IndentedTextPlanParser.Parse(rawText),
            PlanFormat.DamengText => DamengPlanParser.Parse(rawText),
            PlanFormat.OraclePlanRows => OraclePlanParser.Parse(rawText),
            PlanFormat.SqlServerShowplanXml => SqlServerShowplanParser.Parse(rawText),
            PlanFormat.DuckDbJson => DuckDbPlanParser.Parse(rawText),
            _ => null,
        };
    }
}
