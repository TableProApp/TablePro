using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;
using System.Text;

namespace TablePro.Core.Sql.Analysis;

/// <summary>Analyzes SQL for the editor's language features: diagnostics, hover, go to definition and references.</summary>
public static class SqlAnalyzer
{
    /// <summary>
    /// Past this length no diagnostics are computed, as the macOS app stops at its own limit: a script that long is
    /// usually a dump, and a full pass on every pause would cost more than it is worth. Hover and go to definition still
    /// work, since they read only the statement under the pointer.
    /// </summary>
    public const int MaximumDiagnosedLength = 200_000;

    /// <param name="text">The editor's text, with whatever line ends it holds; offsets are in its UTF-16 code units.</param>
    /// <param name="dialect">How the engine lexes and splits SQL.</param>
    /// <param name="catalog">The connection's tables and loaded columns.</param>
    /// <param name="caret">
    /// Where the user is typing. A string or bracket the caret is inside of is still being typed and is not reported;
    /// null means the end of the text.
    /// </param>
    /// <param name="cancellationToken">Stops a pass a newer edit has made pointless.</param>
    public static SqlAnalysis Analyze(string text, SqlDialect dialect, CompletionCatalog catalog, int? caret = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(dialect);
        ArgumentNullException.ThrowIfNull(catalog);
        var analysis = new SqlAnalysis(text, dialect, catalog, caret ?? text.Length);
        analysis.Diagnose(cancellationToken);
        return analysis;
    }
}

/// <summary>
/// One analyzed version of the editor's text. Diagnostics are computed up front; each statement's model is built the
/// first time a query needs it, so a hover on a long script reads one statement. Queries are safe from any thread.
/// </summary>
public sealed class SqlAnalysis
{
    private const int ColumnsShown = 20;

    private static readonly FrozenSet<string> PseudoTables = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase, ["NEW", "OLD", "EXCLUDED", "INSERTED", "DELETED"]);

    /// <summary>Columns every row has without the structure listing them: PostgreSQL's system columns, SQLite's rowid, Oracle's pseudocolumns.</summary>
    private static readonly FrozenSet<string> PseudoColumns = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase,
        ["ctid", "xmin", "xmax", "cmin", "cmax", "tableoid", "oid", "rowid", "_rowid_", "rownum", "ora_rowscn", "nextval", "currval"]);

    private readonly SqlToken[] _tokens;
    private readonly SqlToken[] _significant;
    private readonly ImmutableArray<SqlStatement> _statements;
    private readonly (int From, int To)[] _statementTokens;
    private readonly SqlStatementModel?[] _models;
    private readonly SqlCatalogIndex _index;
    private ImmutableArray<SqlTextRange> _caretWindows = [];

    internal SqlAnalysis(string text, SqlDialect dialect, CompletionCatalog catalog, int caret)
    {
        Text = text;
        Dialect = dialect;
        Caret = Math.Clamp(caret, 0, text.Length);
        _index = SqlCatalogIndex.For(catalog);

        var tokens = new List<SqlToken>(Math.Min(text.Length / 3, 1 << 16));
        var lexer = new SqlLexer(text, dialect.LexerFeatures);
        var significantCount = 0;
        while (lexer.TryRead(out var token))
        {
            tokens.Add(token);
            significantCount += token.IsTrivia ? 0 : 1;
        }

        _tokens = [.. tokens];
        _significant = new SqlToken[significantCount];
        var next = 0;
        foreach (var token in _tokens)
        {
            if (!token.IsTrivia)
            {
                _significant[next++] = token;
            }
        }

        _statements = text.Length == 0 ? [] : dialect.Split(text);
        _statementTokens = new (int, int)[_statements.Length];
        var at = 0;
        for (var s = 0; s < _statements.Length; s++)
        {
            while (at < _significant.Length && _significant[at].Start < _statements[s].Start)
            {
                at++;
            }

            var from = at;
            while (at < _significant.Length && _significant[at].Start < _statements[s].End)
            {
                at++;
            }

            _statementTokens[s] = (from, at);
        }

        _models = new SqlStatementModel?[_statements.Length];
    }

    public static SqlAnalysis Empty { get; } = new(string.Empty, PostgreSqlDialect.Instance, CompletionCatalog.Empty, 0);

    /// <summary>The text this analysis describes; its offsets are only valid against it.</summary>
    public string Text { get; }

    public SqlDialect Dialect { get; }

    /// <summary>The caret the analysis assumed, which decides what counts as still being typed.</summary>
    public int Caret { get; }

    /// <summary>Every diagnostic, ordered by position.</summary>
    public ImmutableArray<SqlDiagnostic> Diagnostics { get; private set; } = [];

    public int StatementCount => _statements.Length;

    /// <summary>The model of the statement holding the offset, or null outside every statement or for a command language.</summary>
    public SqlStatementModel? StatementAt(int offset)
    {
        var index = StatementIndexAt(offset);
        return index < 0 ? null : ModelAt(index);
    }

    /// <summary>
    /// What the name at the offset means. With <paramref name="atCaret"/> an offset just after a name counts, where the
    /// caret sits after typing it; a pointer is on a character, so it passes false.
    /// </summary>
    public SqlSymbol? SymbolAt(int offset, bool atCaret = true) => Bind(offset, atCaret) is { } binding ? ToSymbol(binding) : null;

    /// <summary>
    /// Every place in the text naming what the name at the offset names: an alias or common table expression within its
    /// statement, a table or column across the script.
    /// </summary>
    public IReadOnlyList<SqlTextRange> ReferencesAt(int offset)
    {
        if (Bind(offset, allowEnd: true) is not { } binding)
        {
            return [];
        }

        var result = new List<SqlTextRange>();
        var model = binding.Model;
        switch (binding.Kind)
        {
            case BindingKind.Alias:
                result.Add(binding.Reference!.AliasRange!.Value);
                foreach (var q in model.QualifiedReferences)
                {
                    if (ReferenceEquals(model.ResolveQualifier(q.Qualifier, q.Scope), binding.Reference))
                    {
                        result.Add(q.QualifierRange);
                    }
                }

                break;
            case BindingKind.CommonTableExpression:
                var cte = binding.CommonTableExpression!;
                result.Add(cte.NameRange);
                foreach (var table in model.Tables)
                {
                    if (ReferenceEquals(table.CommonTableExpression, cte))
                    {
                        result.Add(table.NameRange);
                    }
                }

                foreach (var q in model.QualifiedReferences)
                {
                    if (model.ResolveQualifier(q.Qualifier, q.Scope) is { Alias: null } target && ReferenceEquals(target.CommonTableExpression, cte))
                    {
                        result.Add(q.QualifierRange);
                    }
                }

                break;
            case BindingKind.Table:
                AddTableReferences(binding.Reference!, result);
                break;
            case BindingKind.Column when binding.Reference!.Kind == SqlTableReferenceKind.Table:
                AddColumnReferences(binding.Reference!, binding.Name, result);
                break;
            default:
                result.Add(binding.Range);
                break;
        }

        result.Sort(static (a, b) => a.Start.CompareTo(b.Start));
        for (var i = result.Count - 1; i > 0; i--)
        {
            if (result[i] == result[i - 1])
            {
                result.RemoveAt(i);
            }
        }

        return result;
    }

    /// <summary>
    /// The diagnostics on the offset and what the name there means, or null when there is neither. With
    /// <paramref name="atCaret"/> an offset just after a range counts too, for quick info asked from the keyboard.
    /// </summary>
    public SqlHover? HoverAt(int offset, bool atCaret = false)
    {
        List<SqlDiagnostic>? hits = null;
        foreach (var diagnostic in Diagnostics)
        {
            if (offset >= diagnostic.Start && (offset < diagnostic.End || (atCaret && offset == diagnostic.End)))
            {
                (hits ??= []).Add(diagnostic);
            }
        }

        var symbol = Bind(offset, atCaret) is { } binding ? ToSymbol(binding) : null;
        if (hits is null && symbol is null)
        {
            return null;
        }

        var (title, detail) = symbol is null ? (null, null) : Describe(symbol);
        return new SqlHover(symbol?.Range ?? hits![0].Range, (IReadOnlyList<SqlDiagnostic>?)hits ?? [], symbol, title, detail);
    }

    /// <summary>
    /// The diagnostics moved onto an edited text: those the edit left alone shift with it, those it touched are dropped
    /// until the next analysis. The editor shows these while a fresh pass runs.
    /// </summary>
    public ImmutableArray<SqlDiagnostic> DiagnosticsMappedTo(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (Diagnostics.IsEmpty || string.Equals(text, Text, StringComparison.Ordinal))
        {
            return Diagnostics;
        }

        var change = SqlTextChange.Between(Text, text);
        var builder = ImmutableArray.CreateBuilder<SqlDiagnostic>(Diagnostics.Length);
        foreach (var diagnostic in Diagnostics)
        {
            if (change.TryMap(diagnostic.Start, diagnostic.Length, out var start))
            {
                builder.Add(diagnostic with { Start = start });
            }
        }

        return builder.ToImmutable();
    }

    /// <summary>
    /// Whether moving the caret there would change the diagnostics: it left, or entered, a string or a bracket that
    /// is quiet only while the caret is inside it.
    /// </summary>
    public bool CaretChangesResult(int caret)
    {
        foreach (var window in _caretWindows)
        {
            if (InWindow(window, Caret) != InWindow(window, caret))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>The next diagnostic after the offset, or the previous one before it, wrapping around the text.</summary>
    public static SqlDiagnostic? Next(ImmutableArray<SqlDiagnostic> diagnostics, int offset, bool forward)
    {
        if (diagnostics.IsDefaultOrEmpty)
        {
            return null;
        }

        if (forward)
        {
            foreach (var diagnostic in diagnostics)
            {
                if (diagnostic.Start > offset)
                {
                    return diagnostic;
                }
            }

            return diagnostics[0];
        }

        for (var i = diagnostics.Length - 1; i >= 0; i--)
        {
            if (diagnostics[i].Start < offset)
            {
                return diagnostics[i];
            }
        }

        return diagnostics[^1];
    }

    internal void Diagnose(CancellationToken cancellationToken)
    {
        if (!Dialect.IsSql || Text.Length == 0 || Text.Length > SqlAnalyzer.MaximumDiagnosedLength)
        {
            return;
        }

        var output = new List<SqlDiagnostic>();
        var windows = new List<SqlTextRange>();
        ScanStructure(output, windows);
        cancellationToken.ThrowIfCancellationRequested();
        if (_index.HasTables)
        {
            CheckNames(output, windows, cancellationToken);
        }

        output.Sort(static (a, b) => a.Start != b.Start ? a.Start.CompareTo(b.Start) : a.Severity.CompareTo(b.Severity));
        Diagnostics = [.. output];
        _caretWindows = [.. windows];
    }

    /// <summary>
    /// The lexer-level checks: brackets per statement, block comments, strings and quoted names left open, and
    /// confusable characters outside literals. One pass over the tokens.
    /// </summary>
    private void ScanStructure(List<SqlDiagnostic> output, List<SqlTextRange> windows)
    {
        var text = Text.AsSpan();
        var stack = new List<(char Opener, int Position)>();
        var statement = 0;
        var regionStart = -1;
        var regionEnd = -1;
        for (var t = 0; t < _tokens.Length; t++)
        {
            var token = _tokens[t];
            while (statement < _statements.Length && token.Start >= _statements[statement].End)
            {
                CloseStatement(statement++, t, stack, output, windows);
            }

            var inStatement = statement < _statements.Length && token.Start >= _statements[statement].Start;
            switch (token.Kind)
            {
                case SqlTokenKind.BlockComment when token.IsUnterminated:
                    output.Add(Error(token.Start, 2, SqlDiagnosticCode.UnterminatedComment, "Unterminated comment"));
                    break;
                case SqlTokenKind.String or SqlTokenKind.QuotedIdentifier when token.IsUnterminated:
                    var window = new SqlTextRange(token.Start, Text.Length - token.Start);
                    windows.Add(window);
                    if (!InWindow(window, Caret))
                    {
                        output.Add(token.Kind == SqlTokenKind.String
                            ? Error(token.Start, OpeningLength(token), SqlDiagnosticCode.UnterminatedString, "Unterminated string")
                            : Error(token.Start, 1, SqlDiagnosticCode.UnterminatedQuotedName, "Unterminated quoted name"));
                    }

                    break;
                case SqlTokenKind.OpenParen when inStatement:
                    stack.Add(('(', token.Start));
                    break;
                case SqlTokenKind.CloseParen when inStatement:
                    CloseBracket('(', token.Start, stack, output);
                    break;
                case SqlTokenKind.Operator when inStatement:
                    // Brackets and braces are not tokens of their own: the lexer folds them into operators.
                    var operatorText = token.Slice(text);
                    for (var k = 0; k < operatorText.Length; k++)
                    {
                        switch (operatorText[k])
                        {
                            case '[' or '{':
                                stack.Add((operatorText[k], token.Start + k));
                                break;
                            case ']':
                                CloseBracket('[', token.Start + k, stack, output);
                                break;
                            case '}':
                                CloseBracket('{', token.Start + k, stack, output);
                                break;
                        }
                    }

                    break;
            }

            if (token.Kind is SqlTokenKind.String or SqlTokenKind.QuotedIdentifier or SqlTokenKind.LineComment or SqlTokenKind.BlockComment)
            {
                if (regionStart >= 0)
                {
                    ConfusableCharacters.Scan(text, regionStart, regionEnd, output);
                    regionStart = -1;
                }
            }
            else
            {
                regionStart = regionStart < 0 ? token.Start : regionStart;
                regionEnd = token.End;
            }
        }

        if (regionStart >= 0)
        {
            ConfusableCharacters.Scan(text, regionStart, regionEnd, output);
        }

        while (statement < _statements.Length)
        {
            CloseStatement(statement++, _tokens.Length, stack, output, windows);
        }
    }

    private static void CloseBracket(char opener, int position, List<(char Opener, int Position)> stack, List<SqlDiagnostic> output)
    {
        if (stack.Count > 0 && stack[^1].Opener == opener)
        {
            stack.RemoveAt(stack.Count - 1);
            return;
        }

        output.Add(Error(position, 1, SqlDiagnosticCode.UnmatchedClosingBracket, "No matching opening bracket"));
    }

    /// <summary>
    /// Reports the openers a statement left open, unless the caret is inside the statement after one: there the user
    /// is still typing and the closer may come next. The statement reaches up to its separator, so the caret just
    /// before the <c>;</c> still counts as inside.
    /// </summary>
    private void CloseStatement(int statement, int nextToken, List<(char Opener, int Position)> stack, List<SqlDiagnostic> output, List<SqlTextRange> windows)
    {
        if (stack.Count == 0)
        {
            return;
        }

        var reach = statement + 1 < _statements.Length ? _statements[statement + 1].Start : Text.Length;
        for (var t = nextToken; t < _tokens.Length && _tokens[t].Start < reach; t++)
        {
            if (_tokens[t].Kind == SqlTokenKind.Semicolon)
            {
                reach = _tokens[t].Start;
                break;
            }
        }

        foreach (var (opener, position) in stack)
        {
            var window = new SqlTextRange(position, reach - position);
            windows.Add(window);
            if (!InWindow(window, Caret))
            {
                output.Add(Error(position, 1, SqlDiagnosticCode.UnclosedBracket, opener switch
                {
                    '(' => "No matching closing parenthesis",
                    '[' => "No matching closing bracket",
                    _ => "No matching closing brace",
                }));
            }
        }

        stack.Clear();
    }

    /// <summary>The catalog checks, on data statements only, and only up to a statement that changes database or schema.</summary>
    private void CheckNames(List<SqlDiagnostic> output, List<SqlTextRange> windows, CancellationToken cancellationToken)
    {
        var sink = new NameSink(output, windows, Caret);
        var created = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var s = 0; s < _statements.Length; s++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            created.UnionWith(ModelAt(s).CreatedNames);
        }

        for (var s = 0; s < _statements.Length; s++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var model = ModelAt(s);
            if (model.ChangesSchemaContext)
            {
                return;
            }

            if (model.IsDataStatement)
            {
                CheckTables(model, created, sink);
                CheckQualifiedNames(model, created, sink);
            }
        }
    }

    private void CheckTables(SqlStatementModel model, HashSet<string> created, NameSink output)
    {
        foreach (var table in model.Tables)
        {
            // A schema-qualified name may live in a schema the sidebar has not loaded, so only bare names are checked.
            if (table.Kind != SqlTableReferenceKind.Table || table.Schema is not null || _index.TryGetTable(table.Name, out _)
                || created.Contains(table.Name) || model.DefinesCommonTableExpression(table.Name) || IsSystemTable(table.Name))
            {
                continue;
            }

            output.Add(table.NameRange, SqlDiagnosticCode.UnknownTable, $"Unknown table '{table.Name}'.");
        }
    }

    private void CheckQualifiedNames(SqlStatementModel model, HashSet<string> created, NameSink output)
    {
        foreach (var q in model.QualifiedReferences)
        {
            if (q.Column is not null && PseudoColumns.Contains(q.Column))
            {
                continue;
            }

            if (model.ResolveQualifier(q.Qualifier, q.Scope) is { } target)
            {
                if (target.Kind == SqlTableReferenceKind.Table && q.Column is not null && q.ColumnRange is { } columnRange
                    && _index.Columns(target.Schema, target.Name) is { } columns && SqlCatalogIndex.FindColumn(columns, q.Column) is null)
                {
                    output.Add(columnRange, SqlDiagnosticCode.UnknownColumn, $"Table '{target.Name}' has no column '{q.Column}'.");
                }

                continue;
            }

            if (q.Schema is null && !PseudoTables.Contains(q.Qualifier) && !_index.IsSchema(q.Qualifier) && !created.Contains(q.Qualifier)
                && !model.DefinesCommonTableExpression(q.Qualifier) && EveryTableIsKnownWithout(model, q.Qualifier))
            {
                output.Add(q.QualifierRange, SqlDiagnosticCode.UnknownQualifier, $"Unknown table or alias '{q.Qualifier}'.");
            }
        }
    }

    /// <summary>
    /// Collects the catalog warnings, leaving out a name the caret is on or just after: it is still being typed, and
    /// <c>FROM ord</c> must not be flagged on the way to <c>FROM orders</c>. The caret leaving it asks for a fresh look.
    /// </summary>
    private readonly struct NameSink(List<SqlDiagnostic> output, List<SqlTextRange> windows, int caret)
    {
        public void Add(SqlTextRange range, SqlDiagnosticCode code, string message)
        {
            var window = new SqlTextRange(range.Start - 1, range.Length + 1);
            windows.Add(window);
            if (!InWindow(window, caret))
            {
                output.Add(Warning(range, code, message));
            }
        }
    }

    /// <summary>
    /// Whether the statement's every table has loaded columns and none is called <paramref name="name"/>. Only then is an
    /// unknown qualifier surely a mistake: otherwise it may be a column of composite or struct type, read with a dot.
    /// </summary>
    private bool EveryTableIsKnownWithout(SqlStatementModel model, string name)
    {
        if (model.Tables.Count == 0)
        {
            return false;
        }

        foreach (var table in model.Tables)
        {
            if (table.Kind != SqlTableReferenceKind.Table || _index.Columns(table.Schema, table.Name) is not { } columns
                || SqlCatalogIndex.FindColumn(columns, name) is not null)
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>Catalog views and tables every engine has but no sidebar lists, which a query may name without a schema.</summary>
    private bool IsSystemTable(string name) =>
        name.StartsWith("pg_", StringComparison.OrdinalIgnoreCase)
        || name.StartsWith("sqlite_", StringComparison.OrdinalIgnoreCase)
        || name.StartsWith("duckdb_", StringComparison.OrdinalIgnoreCase)
        || name.Equals("dual", StringComparison.OrdinalIgnoreCase)
        || (Dialect is OracleDialect && (name.StartsWith("all_", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith("user_", StringComparison.OrdinalIgnoreCase) || name.StartsWith("dba_", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith("v$", StringComparison.OrdinalIgnoreCase) || name.StartsWith("gv$", StringComparison.OrdinalIgnoreCase)))
        || (Dialect is SqlServerDialect && name.StartsWith("sys", StringComparison.OrdinalIgnoreCase));

    private int OpeningLength(SqlToken token)
    {
        var first = Text[token.Start];
        if (char.IsLetter(first))
        {
            return Math.Min(2, token.Length);
        }

        if (first == '$')
        {
            var close = Text.IndexOf('$', token.Start + 1);
            return close < 0 || close >= token.End ? 1 : close - token.Start + 1;
        }

        return 1;
    }

    private int StatementIndexAt(int offset)
    {
        for (var s = 0; s < _statements.Length; s++)
        {
            if (offset >= _statements[s].Start && offset <= _statements[s].End)
            {
                return s;
            }

            if (_statements[s].Start > offset)
            {
                break;
            }
        }

        return -1;
    }

    private SqlStatementModel ModelAt(int index)
    {
        var model = Volatile.Read(ref _models[index]);
        if (model is not null)
        {
            return model;
        }

        var (from, to) = _statementTokens[index];
        var statement = _statements[index];
        model = SqlStatementParser.Parse(Text, _significant, from, to, new SqlTextRange(statement.Start, statement.Length));
        return Interlocked.CompareExchange(ref _models[index], model, null) ?? model;
    }

    private Binding? Bind(int offset, bool allowEnd)
    {
        var index = Dialect.IsSql ? StatementIndexAt(offset) : -1;
        if (index < 0)
        {
            return null;
        }

        var model = ModelAt(index);
        return BindAt(model, offset) ?? (allowEnd && offset > 0 ? BindAt(model, offset - 1) : null);
    }

    private Binding? BindAt(SqlStatementModel model, int at)
    {
        foreach (var table in model.Tables)
        {
            if (table.Kind != SqlTableReferenceKind.Subquery && table.NameRange.Contains(at))
            {
                return BindingFor(model, table, table.NameRange);
            }

            if (table.AliasRange is { } alias && alias.Contains(at))
            {
                return new Binding(BindingKind.Alias, alias, model, table, table.CommonTableExpression, table.Alias!);
            }
        }

        foreach (var cte in model.CommonTableExpressions)
        {
            if (cte.NameRange.Contains(at))
            {
                return new Binding(BindingKind.CommonTableExpression, cte.NameRange, model, null, cte, cte.Name);
            }
        }

        foreach (var q in model.QualifiedReferences)
        {
            if (q.QualifierRange.Contains(at))
            {
                return model.ResolveQualifier(q.Qualifier, q.Scope) is { } target ? BindingFor(model, target, q.QualifierRange) : null;
            }

            if (q.ColumnRange is { } column && column.Contains(at))
            {
                return model.ResolveQualifier(q.Qualifier, q.Scope) is { } target
                    ? new Binding(BindingKind.Column, column, model, target, target.CommonTableExpression, q.Column!)
                    : null;
            }
        }

        foreach (var name in model.Names)
        {
            if (name.Range.Contains(at))
            {
                return ColumnOwner(model, name) is { } owner ? new Binding(BindingKind.Column, name.Range, model, owner, null, name.Name) : null;
            }
        }

        return null;
    }

    /// <summary>What a table's name, or a qualifier meaning that table, binds to: its alias when it has one.</summary>
    private static Binding BindingFor(SqlStatementModel model, SqlTableReference table, SqlTextRange range)
    {
        if (range != table.NameRange && table.Alias is not null)
        {
            return new Binding(BindingKind.Alias, range, model, table, table.CommonTableExpression, table.Alias);
        }

        return table.Kind switch
        {
            SqlTableReferenceKind.CommonTableExpression => new Binding(BindingKind.CommonTableExpression, range, model, table, table.CommonTableExpression, table.Name),
            SqlTableReferenceKind.Function => new Binding(BindingKind.Function, range, model, table, null, table.Name),
            _ => new Binding(BindingKind.Table, range, model, table, null, table.Name),
        };
    }

    /// <summary>The table of the name's query level, or an outer one, whose loaded columns include the name.</summary>
    private SqlTableReference? ColumnOwner(SqlStatementModel model, SqlNameOccurrence name)
    {
        for (var scope = name.Scope; scope >= 0; scope = model.ParentOf(scope))
        {
            foreach (var table in model.Tables)
            {
                if (table.Scope == scope && table.Kind == SqlTableReferenceKind.Table
                    && _index.Columns(table.Schema, table.Name) is { } columns && SqlCatalogIndex.FindColumn(columns, name.Name) is not null)
                {
                    return table;
                }
            }
        }

        return null;
    }

    private SqlSymbol ToSymbol(Binding binding)
    {
        var reference = binding.Reference;
        switch (binding.Kind)
        {
            case BindingKind.Table:
                return TableSymbol(reference!, binding.Range);
            case BindingKind.CommonTableExpression:
                var cte = binding.CommonTableExpression!;
                return new SqlSymbol(SqlSymbolKind.CommonTableExpression, binding.Range, cte.Name, new SqlTextDefinition(cte.NameRange.Start, cte.NameRange.Length));
            case BindingKind.Function:
                return new SqlSymbol(SqlSymbolKind.TableFunction, binding.Range, binding.Name, null, Schema: reference!.Schema);
            case BindingKind.Alias:
                return AliasSymbol(reference!, binding.Range);
            default:
                return ColumnSymbol(reference!, binding.Name, binding.Range);
        }
    }

    private SqlSymbol TableSymbol(SqlTableReference table, SqlTextRange range)
    {
        var known = _index.TryGetTable(table.Name, out var isView);
        return new SqlSymbol(
            isView ? SqlSymbolKind.View : SqlSymbolKind.Table,
            range,
            table.Name,
            known || table.Schema is not null ? new SqlCatalogDefinition(table.Schema, table.Name, isView) : null,
            table.Name,
            table.Schema,
            Columns: _index.Columns(table.Schema, table.Name));
    }

    /// <summary>
    /// On its declaration an alias leads to what it names, as F12 on a table name does; on a qualifier it leads back
    /// to the declaration, so a second F12 continues to the table.
    /// </summary>
    private SqlSymbol AliasSymbol(SqlTableReference table, SqlTextRange range)
    {
        var aliasRange = table.AliasRange!.Value;
        var onDeclaration = range == aliasRange;
        var target = table.Kind switch
        {
            SqlTableReferenceKind.Table => TableSymbol(table, range),
            SqlTableReferenceKind.CommonTableExpression => new SqlSymbol(
                SqlSymbolKind.CommonTableExpression,
                range,
                table.Name,
                new SqlTextDefinition(table.CommonTableExpression!.NameRange.Start, table.CommonTableExpression.NameRange.Length)),
            SqlTableReferenceKind.Subquery => new SqlSymbol(SqlSymbolKind.Subquery, range, table.Alias!, new SqlTextDefinition(table.NameRange.Start, 1)),
            _ => new SqlSymbol(SqlSymbolKind.TableFunction, range, table.Name, null),
        };

        return new SqlSymbol(
            SqlSymbolKind.Alias,
            range,
            table.Alias!,
            onDeclaration ? target.Definition : new SqlTextDefinition(aliasRange.Start, aliasRange.Length),
            table.Kind == SqlTableReferenceKind.Subquery ? null : table.Name,
            table.Schema,
            Columns: target.Columns,
            TargetKind: target.Kind);
    }

    private SqlSymbol ColumnSymbol(SqlTableReference table, string name, SqlTextRange range)
    {
        switch (table.Kind)
        {
            case SqlTableReferenceKind.Table:
                var column = _index.Columns(table.Schema, table.Name) is { } columns ? SqlCatalogIndex.FindColumn(columns, name) : null;
                var known = _index.TryGetTable(table.Name, out var isView);
                var columnName = column?.Name ?? name;
                return new SqlSymbol(
                    SqlSymbolKind.Column,
                    range,
                    columnName,
                    known || table.Schema is not null ? new SqlCatalogDefinition(table.Schema, table.Name, isView, columnName) : null,
                    table.Name,
                    table.Schema,
                    column?.Type);
            case SqlTableReferenceKind.CommonTableExpression:
                var cte = table.CommonTableExpression!;
                return new SqlSymbol(SqlSymbolKind.Column, range, name, new SqlTextDefinition(cte.NameRange.Start, cte.NameRange.Length), table.ExposedName);
            default:
                return new SqlSymbol(SqlSymbolKind.Column, range, name, null, table.ExposedName);
        }
    }

    private void AddTableReferences(SqlTableReference table, List<SqlTextRange> result)
    {
        for (var s = 0; s < _statements.Length; s++)
        {
            var model = ModelAt(s);
            foreach (var other in model.Tables)
            {
                if (other.Kind == SqlTableReferenceKind.Table && SameTable(other, table))
                {
                    result.Add(other.NameRange);
                }
            }

            foreach (var q in model.QualifiedReferences)
            {
                if (model.ResolveQualifier(q.Qualifier, q.Scope) is { Alias: null, Kind: SqlTableReferenceKind.Table } target && SameTable(target, table))
                {
                    result.Add(q.QualifierRange);
                }
            }
        }
    }

    private void AddColumnReferences(SqlTableReference table, string column, List<SqlTextRange> result)
    {
        for (var s = 0; s < _statements.Length; s++)
        {
            var model = ModelAt(s);
            foreach (var q in model.QualifiedReferences)
            {
                if (q.ColumnRange is { } range && string.Equals(q.Column, column, StringComparison.OrdinalIgnoreCase)
                    && model.ResolveQualifier(q.Qualifier, q.Scope) is { Kind: SqlTableReferenceKind.Table } target && SameTable(target, table))
                {
                    result.Add(range);
                }
            }

            foreach (var name in model.Names)
            {
                if (string.Equals(name.Name, column, StringComparison.OrdinalIgnoreCase) && ColumnOwner(model, name) is { } owner && SameTable(owner, table))
                {
                    result.Add(name.Range);
                }
            }
        }
    }

    private static bool SameTable(SqlTableReference a, SqlTableReference b) =>
        string.Equals(a.Name, b.Name, StringComparison.OrdinalIgnoreCase)
        && (a.Schema is null || b.Schema is null || string.Equals(a.Schema, b.Schema, StringComparison.OrdinalIgnoreCase));

    private static (string? Title, string? Detail) Describe(SqlSymbol symbol) => symbol.Kind switch
    {
        SqlSymbolKind.Table => ($"Table {Qualified(symbol.Schema, symbol.Name)}", ColumnList(symbol.Columns)),
        SqlSymbolKind.View => ($"View {Qualified(symbol.Schema, symbol.Name)}", ColumnList(symbol.Columns)),
        SqlSymbolKind.CommonTableExpression => ($"Common table expression {symbol.Name}", null),
        SqlSymbolKind.TableFunction => ($"Table function {Qualified(symbol.Schema, symbol.Name)}", null),
        SqlSymbolKind.Subquery => ($"Subquery {symbol.Name}", null),
        SqlSymbolKind.Alias => ($"{symbol.Name}: alias of {AliasTarget(symbol)}", ColumnList(symbol.Columns)),
        _ => ($"Column {(symbol.Table is null ? symbol.Name : $"{symbol.Table}.{symbol.Name}")}", symbol.DataType),
    };

    private static string AliasTarget(SqlSymbol alias) => alias.TargetKind switch
    {
        SqlSymbolKind.Table => $"table {Qualified(alias.Schema, alias.Table!)}",
        SqlSymbolKind.View => $"view {Qualified(alias.Schema, alias.Table!)}",
        SqlSymbolKind.CommonTableExpression => $"common table expression {alias.Table}",
        SqlSymbolKind.Subquery => "a subquery",
        _ => $"table function {alias.Table}",
    };

    private static string Qualified(string? schema, string name) => schema is null ? name : $"{schema}.{name}";

    /// <summary>The columns as aligned lines for a monospaced tooltip, the first twenty and a count of the rest.</summary>
    private static string? ColumnList(IReadOnlyList<(string Name, string Type)>? columns)
    {
        if (columns is null || columns.Count == 0)
        {
            return null;
        }

        var shown = Math.Min(columns.Count, ColumnsShown);
        var width = 0;
        for (var i = 0; i < shown; i++)
        {
            width = Math.Max(width, columns[i].Name.Length);
        }

        width = Math.Min(width, 28);
        var builder = new StringBuilder(shown * 24);
        for (var i = 0; i < shown; i++)
        {
            var (name, type) = columns[i];
            if (i > 0)
            {
                builder.Append('\n');
            }

            builder.Append(name).Append(' ', Math.Max(1, width - name.Length + 2)).Append(type);
        }

        if (columns.Count > shown)
        {
            builder.Append('\n').Append(CultureInfo.InvariantCulture, $"and {columns.Count - shown} more");
        }

        return builder.ToString();
    }

    private static bool InWindow(SqlTextRange window, int caret) => caret > window.Start && caret <= window.End;

    private static SqlDiagnostic Error(int start, int length, SqlDiagnosticCode code, string message) =>
        new(start, length, SqlDiagnosticSeverity.Error, code, message);

    private static SqlDiagnostic Warning(SqlTextRange range, SqlDiagnosticCode code, string message) =>
        new(range.Start, range.Length, SqlDiagnosticSeverity.Warning, code, message);

    private enum BindingKind : byte
    {
        Table,
        Alias,
        CommonTableExpression,
        Function,
        Column,
    }

    private readonly record struct Binding(
        BindingKind Kind,
        SqlTextRange Range,
        SqlStatementModel Model,
        SqlTableReference? Reference,
        SqlCommonTableExpression? CommonTableExpression,
        string Name);
}
