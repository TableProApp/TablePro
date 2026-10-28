using System.Globalization;
using System.Text;
using System.Xml;

namespace TablePro.Core.Plans.Parsers;

/// <summary>
/// SQL Server showplan XML, estimated (<c>SET SHOWPLAN_XML ON</c>) or actual (<c>SET STATISTICS XML ON</c>). One
/// document per statement the server planned; several land under one synthetic root.
/// </summary>
public static class SqlServerShowplanParser
{
    private const string DocumentStart = "<ShowPlanXML";
    private const int MaximumDepth = 512;

    private static readonly XmlReaderSettings Settings = new()
    {
        DtdProcessing = DtdProcessing.Prohibit,
        XmlResolver = null,
        IgnoreWhitespace = true,
        IgnoreComments = true,
        MaxCharactersFromEntities = 0,
    };

    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        var statements = new List<Statement>();
        foreach (var document in Documents(rawText))
        {
            try
            {
                statements.AddRange(new Reader().Read(document));
            }
            catch (XmlException)
            {
                // A document the server cut short is skipped; the other statements still show.
            }
        }

        if (QueryPlanTreeBuilder.Root(statements.Select(s => s.Root).ToList()) is not { } root)
        {
            return null;
        }

        var compile = Sum(statements.Select(s => s.CompileTime));
        var elapsed = Sum(statements.Select(s => s.ElapsedTime));
        return QueryPlanTreeBuilder.Finish(root, rawText, PlanFormat.SqlServerShowplanXml, compile, elapsed);
    }

    internal static List<string> Documents(string rawText)
    {
        var documents = new List<string>();
        var start = rawText.IndexOf(DocumentStart, StringComparison.Ordinal);
        while (start >= 0)
        {
            var next = rawText.IndexOf(DocumentStart, start + DocumentStart.Length, StringComparison.Ordinal);
            var end = next < 0 ? rawText.Length : next;
            documents.Add(rawText[start..end].Trim());
            start = next;
        }

        return documents;
    }

    private static double? Sum(IEnumerable<double?> values)
    {
        double? total = null;
        foreach (var value in values)
        {
            if (value is { } v)
            {
                total = (total ?? 0) + v;
            }
        }

        return total;
    }

    private sealed record Statement(QueryPlanNode Root, double? CompileTime, double? ElapsedTime);

    private sealed class Counters
    {
        public double Rows { get; set; }

        public double Executions { get; set; }

        public double? ElapsedMilliseconds { get; set; }

        public double? LogicalReads { get; set; }
    }

    private sealed class Operator(Dictionary<string, string> attributes)
    {
        public Dictionary<string, string> Attributes { get; } = attributes;

        public Dictionary<string, string>? Object { get; set; }

        public Counters? Counters { get; set; }

        public string? Predicate { get; set; }

        public List<string> Warnings { get; } = [];

        public List<QueryPlanNode> Children { get; } = [];
    }

    private sealed class PendingStatement
    {
        public double? CompileTime { get; set; }

        public double? ElapsedTime { get; set; }

        public List<string> Warnings { get; } = [];

        public List<QueryPlanMissingIndex> MissingIndexes { get; } = [];

        public List<QueryPlanNode> Roots { get; } = [];
    }

    private sealed class PendingMissingIndex(double? impact, Dictionary<string, string> table)
    {
        public double? Impact { get; } = impact;

        public Dictionary<string, string> Table { get; } = table;

        public Dictionary<string, List<string>> Columns { get; } = new(StringComparer.Ordinal);

        public string? Usage { get; set; }
    }

    /// <summary>
    /// Walks one document. A RelOp's children sit inside its operator element, so the innermost open RelOp is the
    /// parent of the next one.
    /// </summary>
    private sealed class Reader
    {
        private readonly List<Statement> _statements = [];
        private readonly List<string> _path = [];
        private readonly List<Operator> _operators = [];
        private PendingStatement? _statement;
        private double? _missingIndexImpact;
        private PendingMissingIndex? _missingIndex;

        public List<Statement> Read(string document)
        {
            using var reader = XmlReader.Create(new StringReader(document), Settings);
            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.Element)
                {
                    var name = reader.LocalName;
                    var empty = reader.IsEmptyElement;
                    Start(name, Attributes(reader));
                    if (empty)
                    {
                        End(name);
                    }
                }
                else if (reader.NodeType == XmlNodeType.EndElement)
                {
                    End(reader.LocalName);
                }
            }

            return _statements;
        }

        private static Dictionary<string, string> Attributes(XmlReader reader)
        {
            var attributes = new Dictionary<string, string>(reader.AttributeCount, StringComparer.Ordinal);
            if (reader.MoveToFirstAttribute())
            {
                do
                {
                    attributes[reader.LocalName] = reader.Value;
                }
                while (reader.MoveToNextAttribute());

                reader.MoveToElement();
            }

            return attributes;
        }

        private void Start(string name, Dictionary<string, string> attributes)
        {
            var parent = _path.Count > 0 ? _path[^1] : null;
            _path.Add(name);
            if (_path.Count >= MaximumDepth)
            {
                throw new XmlException("The showplan nests too deeply.");
            }

            switch (name)
            {
                case "QueryPlan" when _operators.Count == 0:
                    _statement = new PendingStatement { CompileTime = Number(attributes, "CompileTime") };
                    break;
                case "QueryTimeStats" when _operators.Count == 0 && _statement is not null:
                    _statement.ElapsedTime = Number(attributes, "ElapsedTime");
                    break;
                case "RelOp":
                    _operators.Add(new Operator(attributes));
                    break;
                case "Object" when _operators.Count > 0 && _operators[^1].Object is null:
                    _operators[^1].Object = attributes;
                    break;
                case "RunTimeCountersPerThread" when _operators.Count > 0:
                    Add(attributes, _operators[^1]);
                    break;
                case "ScalarOperator" when parent == "Predicate" && _operators.Count > 0 && _operators[^1].Predicate is null:
                    _operators[^1].Predicate = attributes.GetValueOrDefault("ScalarString");
                    break;
                case "MissingIndexGroup":
                    _missingIndexImpact = Number(attributes, "Impact");
                    break;
                case "MissingIndex":
                    _missingIndex = new PendingMissingIndex(_missingIndexImpact, attributes);
                    break;
                case "ColumnGroup" when _missingIndex is not null:
                    _missingIndex.Usage = attributes.GetValueOrDefault("Usage");
                    break;
                case "Column" when parent == "ColumnGroup" && _missingIndex is { Usage: { } usage } && attributes.TryGetValue("Name", out var column):
                    if (!_missingIndex.Columns.TryGetValue(usage, out var columns))
                    {
                        _missingIndex.Columns[usage] = columns = [];
                    }

                    columns.Add(column);
                    break;
            }

            if (parent == "Warnings" || name == "Warnings")
            {
                RecordWarning(name, attributes);
            }
        }

        private void End(string name)
        {
            _path.RemoveAt(_path.Count - 1);
            switch (name)
            {
                case "RelOp" when _operators.Count > 0:
                    var finished = _operators[^1];
                    _operators.RemoveAt(_operators.Count - 1);
                    var node = MakeNode(finished);
                    if (_operators.Count > 0)
                    {
                        _operators[^1].Children.Add(node);
                    }
                    else
                    {
                        _statement?.Roots.Add(node);
                    }

                    break;
                case "MissingIndex":
                    if (_missingIndex is not null && MakeMissingIndex(_missingIndex) is { } created)
                    {
                        _statement?.MissingIndexes.Add(created);
                    }

                    _missingIndex = null;
                    break;
                case "QueryPlan" when _operators.Count == 0:
                    FinishStatement();
                    break;
            }
        }

        private void FinishStatement()
        {
            if (_statement is not { } pending)
            {
                return;
            }

            _statement = null;
            if (QueryPlanTreeBuilder.Root(pending.Roots) is { } root)
            {
                _statements.Add(new Statement(root.WithDiagnostics(pending.Warnings, pending.MissingIndexes), pending.CompileTime, pending.ElapsedTime));
            }
        }

        private void RecordWarning(string name, Dictionary<string, string> attributes)
        {
            var texts = name == "Warnings"
                ? attributes.Where(a => a.Value is "true" or "1").Select(a => a.Key).Order(StringComparer.Ordinal).Select(Words).ToList()
                : [WarningText(name, attributes)];
            if (texts.Count == 0)
            {
                return;
            }

            if (_operators.Count > 0)
            {
                _operators[^1].Warnings.AddRange(texts);
            }
            else
            {
                _statement?.Warnings.AddRange(texts);
            }
        }
    }

    private static string WarningText(string name, Dictionary<string, string> attributes) => name switch
    {
        "PlanAffectingConvert" => $"Implicit conversion{(attributes.TryGetValue("ConvertIssue", out var issue) ? $" ({issue})" : string.Empty)}: {attributes.GetValueOrDefault("Expression") ?? string.Empty}",
        "SpillToTempDb" => $"Spill to tempdb{(attributes.TryGetValue("SpillLevel", out var level) ? $", level {level}" : string.Empty)}",
        "ColumnsWithNoStatistics" => "Columns with no statistics",
        _ => Words(name),
    };

    /// <summary>"NoJoinPredicate" reads as "No join predicate".</summary>
    private static string Words(string identifier)
    {
        var result = new StringBuilder(identifier.Length + 8);
        for (var i = 0; i < identifier.Length; i++)
        {
            var c = identifier[i];
            if (i > 0 && char.IsUpper(c))
            {
                result.Append(' ');
            }

            result.Append(i > 0 ? char.ToLowerInvariant(c) : c);
        }

        return result.ToString();
    }

    private static void Add(Dictionary<string, string> attributes, Operator target)
    {
        var counters = target.Counters ??= new Counters();
        counters.Rows += Number(attributes, "ActualRows") ?? 0;
        counters.Executions += Number(attributes, "ActualExecutions") ?? 0;
        if (Number(attributes, "ActualElapsedms") is { } elapsed)
        {
            // Threads run at the same time, so the slowest thread is the node's elapsed time.
            counters.ElapsedMilliseconds = Math.Max(counters.ElapsedMilliseconds ?? 0, elapsed);
        }

        if (Number(attributes, "ActualLogicalReads") is { } reads)
        {
            counters.LogicalReads = (counters.LogicalReads ?? 0) + reads;
        }
    }

    private static QueryPlanNode MakeNode(Operator source)
    {
        var attributes = source.Attributes;
        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        var physical = attributes.GetValueOrDefault("PhysicalOp") ?? "Unknown";
        if (attributes.TryGetValue("LogicalOp", out var logical) && logical != physical)
        {
            properties["Logical Operation"] = logical;
        }

        if (source.Object?.GetValueOrDefault("Index") is { } index)
        {
            properties["Index Name"] = Unbracketed(index);
        }

        QueryPlanTreeBuilder.SetIfPresent(properties, "Index Kind", source.Object?.GetValueOrDefault("IndexKind"));
        QueryPlanTreeBuilder.SetIfPresent(properties, "Predicate", source.Predicate);
        QueryPlanTreeBuilder.SetIfPresent(properties, "Execution Mode", attributes.GetValueOrDefault("EstimatedExecutionMode"));
        if (attributes.GetValueOrDefault("Parallel") is "1" or "true")
        {
            properties["Parallel"] = "true";
        }

        QueryPlanTreeBuilder.SetIfPresent(properties, "Estimated I/O", attributes.GetValueOrDefault("EstimateIO"));
        QueryPlanTreeBuilder.SetIfPresent(properties, "Estimated CPU", attributes.GetValueOrDefault("EstimateCPU"));
        var rebinds = (Number(attributes, "EstimateRebinds") ?? 0) + (Number(attributes, "EstimateRewinds") ?? 0);
        if (rebinds > 0)
        {
            properties["Estimated Executions"] = (1 + rebinds).ToString("G6", CultureInfo.InvariantCulture);
        }

        // The counters total every execution and thread; the model holds per-execution values.
        long? actualRows = null, actualLoops = null;
        double? actualTime = null;
        if (source.Counters is { } counters)
        {
            actualLoops = QueryPlanTreeBuilder.BoundedInteger(counters.Executions);
            if (counters.Executions > 0)
            {
                actualRows = QueryPlanTreeBuilder.BoundedInteger(counters.Rows / counters.Executions);
                actualTime = counters.ElapsedMilliseconds / counters.Executions;
            }
            else
            {
                properties["Execution"] = "Never executed";
            }

            if (counters.LogicalReads is { } reads && QueryPlanTreeBuilder.BoundedInteger(reads) is { } bounded)
            {
                properties["Logical Reads"] = bounded.ToString(CultureInfo.InvariantCulture);
            }
        }

        return new QueryPlanNode
        {
            Operation = physical,
            Relation = source.Object?.GetValueOrDefault("Table") is { } table ? Unbracketed(table) : null,
            Schema = source.Object?.GetValueOrDefault("Schema") is { } schema ? Unbracketed(schema) : null,
            Alias = source.Object?.GetValueOrDefault("Alias") is { } alias ? Unbracketed(alias) : null,
            EstimatedTotalCost = Number(attributes, "EstimatedTotalSubtreeCost"),
            EstimatedRows = Number(attributes, "EstimateRows") is { } rows ? QueryPlanTreeBuilder.BoundedInteger(rows) : null,
            EstimatedWidth = Number(attributes, "AvgRowSize") is { } width ? QueryPlanTreeBuilder.BoundedInteger(width) : null,
            ActualTotalTime = actualTime,
            ActualRows = actualRows,
            ActualLoops = actualLoops,
            ReportedTotalActualRows = source.Counters is { } c ? QueryPlanTreeBuilder.BoundedInteger(c.Rows) : null,
            Properties = properties,
            Children = source.Children,
            Warnings = source.Warnings,
        };
    }

    /// <summary>Equality columns lead the key, then inequality ones, the order the server builds its own suggestion in.</summary>
    private static QueryPlanMissingIndex? MakeMissingIndex(PendingMissingIndex pending)
    {
        var keys = pending.Columns.GetValueOrDefault("EQUALITY", []).Concat(pending.Columns.GetValueOrDefault("INEQUALITY", [])).ToList();
        if (keys.Count == 0 || !pending.Table.TryGetValue("Table", out var table))
        {
            return null;
        }

        var qualified = string.Join('.', new[] { pending.Table.GetValueOrDefault("Database"), pending.Table.GetValueOrDefault("Schema"), table }.Where(p => p is not null));
        var name = new StringBuilder("IX_");
        foreach (var c in string.Join('_', keys.Select(Unbracketed).Prepend(Unbracketed(table))))
        {
            name.Append(char.IsLetterOrDigit(c) ? c : '_');
        }

        var statement = new StringBuilder("CREATE NONCLUSTERED INDEX [")
            .Append(name.ToString(0, Math.Min(name.Length, 128)))
            .Append("] ON ").Append(qualified)
            .Append(" (").AppendJoin(", ", keys).Append(')');
        if (pending.Columns.GetValueOrDefault("INCLUDE") is { Count: > 0 } included)
        {
            statement.Append(" INCLUDE (").AppendJoin(", ", included).Append(')');
        }

        return new QueryPlanMissingIndex(pending.Impact, statement.Append(';').ToString());
    }

    private static double? Number(Dictionary<string, string> attributes, string name) =>
        attributes.TryGetValue(name, out var text) && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;

    private static string Unbracketed(string name) =>
        name.Length >= 2 && name[0] == '[' && name[^1] == ']' ? name[1..^1].Replace("]]", "]", StringComparison.Ordinal) : name;
}
