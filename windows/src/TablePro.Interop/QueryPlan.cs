using System.Text;
using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// One EXPLAIN option an engine offers, in menu order.
public sealed record ExplainVariant(
    string Id,
    string Label,
    string SqlPrefix,
    string Format,
    bool IsSqlPrefix,
    bool RunsStatement);

// An index the engine's plan says would help, and the statement that creates it.
public sealed record QueryPlanMissingIndex(double? Impact, string CreateStatement);

// One node of a parsed plan tree. CostFraction is the node's share of the plan's total work, null when no cost was
// reported anywhere, which is not a share of zero.
public sealed record QueryPlanNode(
    string Operation,
    string? Relation,
    string? Schema,
    string? Alias,
    double? EstimatedStartupCost,
    double? EstimatedTotalCost,
    long? EstimatedRows,
    long? EstimatedWidth,
    double? ActualStartupTime,
    double? ActualTotalTime,
    long? ActualRows,
    long? ActualLoops,
    double? CostFraction,
    IReadOnlyDictionary<string, string> Properties,
    IReadOnlyList<string> Warnings,
    long? ReportedTotalActualRows,
    IReadOnlyList<QueryPlanMissingIndex> MissingIndexes,
    IReadOnlyList<QueryPlanNode> Children);

// A parsed EXPLAIN plan. RawText is the engine's output, shown in the plan view's Raw mode.
public sealed record QueryPlan(
    QueryPlanNode Root,
    double? PlanningTime,
    double? ExecutionTime,
    string RawText);

// The result of running an EXPLAIN variant.
public abstract record ExplainOutcome
{
    private ExplainOutcome()
    {
    }

    // The variant ran and its output parsed into a tree.
    public sealed record Parsed(QueryPlan Plan) : ExplainOutcome;

    // The variant ran but the format has no parser or the output did not parse; the view shows RawText alone.
    public sealed record RawText(string Text) : ExplainOutcome;

    // The server refused the EXPLAIN statement.
    public sealed record Failed(CoreError Error) : ExplainOutcome;

    public sealed record TimedOut(bool ServerCancelled) : ExplainOutcome;
}

// The query-plan boundary: the EXPLAIN options an engine offers, and running one into a parsed plan.
public static class QueryPlans
{
    // The EXPLAIN options the engine offers, in menu order. Empty for an engine without query-plan support.
    public static IReadOnlyList<ExplainVariant> VariantsFor(string engine)
    {
        ArgumentNullException.ThrowIfNull(engine);
        return [.. Native.CoreMethods.ExplainVariants(engine).Select(Variant)];
    }

    // Parse an engine's EXPLAIN output, keyed by the variant's format. Null when the format has no parser or the text
    // does not parse, so the caller shows the raw text instead.
    public static QueryPlan? Parse(string format, string rawText)
    {
        ArgumentNullException.ThrowIfNull(format);
        ArgumentNullException.ThrowIfNull(rawText);
        return Native.CoreMethods.ParseQueryPlan(format, rawText) is { } plan ? Plan(plan) : null;
    }

    // Run the variant on the editor's connection and parse its output. The variant's RunsStatement says a variant
    // executes the user's statement (ANALYZE), which the caller gates before it calls this.
    public static async Task<ExplainOutcome> ExplainAsync(
        QueryEditor editor,
        ExplainVariant variant,
        string statement,
        QueryOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(editor);
        ArgumentNullException.ThrowIfNull(variant);
        ArgumentNullException.ThrowIfNull(statement);
        if (!variant.IsSqlPrefix)
        {
            throw new NotSupportedException("A driver-fetched plan variant is not supported on Windows yet.");
        }

        var sql = variant.SqlPrefix.Length > 0 ? $"{variant.SqlPrefix} {statement}" : statement;
        using var run = editor.Run(sql, options, cancellationToken);
        var outcome = await run.Completion.ConfigureAwait(false);
        switch (outcome)
        {
            case QueryOutcome.Completed:
                break;
            case QueryOutcome.Failed failed:
                return new ExplainOutcome.Failed(failed.Error);
            case QueryOutcome.TimedOut timedOut:
                return new ExplainOutcome.TimedOut(timedOut.ServerCancelled);
            default:
                throw new OperationCanceledException(cancellationToken);
        }

        var text = CollectText(run);
        return Parse(variant.Format, text) is { } plan ? new ExplainOutcome.Parsed(plan) : new ExplainOutcome.RawText(text);
    }

    // The set's rows as text, cells tab-joined and rows newline-joined: the shape every parser reads (one JSON cell for
    // Postgres and MySQL, id/parent/notused/detail columns for SQLite).
    private static string CollectText(QueryRun run)
    {
        using var set = run.GetResultSet(0);
        if (set is null)
        {
            return string.Empty;
        }

        var columnCount = set.GetColumns().Count;
        var builder = new StringBuilder();
        for (var row = 0L; row < set.RowCount; row++)
        {
            if (row > 0)
            {
                builder.Append('\n');
            }

            for (var column = 0; column < columnCount; column++)
            {
                if (column > 0)
                {
                    builder.Append('\t');
                }

                builder.Append(set.GetCellText(row, column));
            }
        }

        return builder.ToString();
    }

    private static ExplainVariant Variant(Native.ExplainVariantInfo variant) =>
        new(variant.Id, variant.Label, variant.SqlPrefix, variant.Format, variant.IsSqlPrefix, variant.RunsStatement);

    private static QueryPlan Plan(Native.QueryPlanInfo plan) =>
        new(Node(plan.Root), plan.PlanningTime, plan.ExecutionTime, plan.RawText);

    private static QueryPlanNode Node(Native.QueryPlanNodeInfo node) => new(
        node.Operation,
        node.Relation,
        node.Schema,
        node.Alias,
        node.EstimatedStartupCost,
        node.EstimatedTotalCost,
        node.EstimatedRows,
        node.EstimatedWidth,
        node.ActualStartupTime,
        node.ActualTotalTime,
        node.ActualRows,
        node.ActualLoops,
        node.CostFraction,
        new Dictionary<string, string>(node.Properties),
        node.Warnings,
        node.ReportedTotalActualRows,
        [.. node.MissingIndexes.Select(MissingIndex)],
        [.. node.Children.Select(Node)]);

    private static QueryPlanMissingIndex MissingIndex(Native.QueryPlanMissingIndexInfo index) =>
        new(index.Impact, index.CreateStatement);
}
