using System.Collections.Frozen;

namespace TablePro.Core.Sql.Analysis;

/// <summary>
/// Reads one statement's significant tokens into a <see cref="SqlStatementModel"/>. It is not a grammar: it finds the
/// table positions (after FROM, JOIN, UPDATE, INTO, USING and APPLY), the aliases after them, WITH definitions and
/// dotted names, and tracks parentheses so a subquery is its own query level and a function's arguments are not
/// mistaken for a FROM clause (<c>EXTRACT(YEAR FROM d)</c>).
/// </summary>
internal sealed class SqlStatementParser
{
    private static readonly FrozenSet<string> Verbs = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase,
        ["SELECT", "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "VALUES", "TABLE"]);

    private static readonly FrozenSet<string> DataLeaders = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase,
        ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "VALUES", "TABLE", "EXPLAIN"]);

    /// <summary>
    /// Words SqlKeywords does not list that still follow a table rather than name it, from the engines' own clauses:
    /// reading one as an alias would invent a table name for the next qualifier to match.
    /// </summary>
    private static readonly FrozenSet<string> NeverAliases = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase,
        [
            "ANTI", "APPLY", "ARRAY", "ASOF", "CONNECT", "FINAL", "FORCE", "GLOBAL", "INDEXED", "MATCH_RECOGNIZE", "MINUS",
            "OUTPUT", "PIVOT", "POSITIONAL", "PREWHERE", "QUALIFY", "SAMPLE", "SEMI", "START", "STRAIGHT_JOIN",
            "TABLESAMPLE", "UNPIVOT",
        ]);

    private static readonly FrozenSet<string>.AlternateLookup<ReadOnlySpan<char>> VerbLookup = Verbs.GetAlternateLookup<ReadOnlySpan<char>>();
    private static readonly FrozenSet<string>.AlternateLookup<ReadOnlySpan<char>> DataLeaderLookup = DataLeaders.GetAlternateLookup<ReadOnlySpan<char>>();
    private static readonly FrozenSet<string>.AlternateLookup<ReadOnlySpan<char>> NeverAliasLookup = NeverAliases.GetAlternateLookup<ReadOnlySpan<char>>();

    private readonly string _text;
    private readonly SqlToken[] _tokens;
    private readonly int _from;
    private readonly int _count;
    private readonly SqlTextRange _range;
    private readonly List<SqlScope> _scopes = [];
    private readonly List<SqlTableReference> _tables = [];
    private readonly List<SqlCommonTableExpression> _ctes = [];
    private readonly List<SqlQualifiedReference> _qualified = [];
    private readonly List<SqlNameOccurrence> _names = [];
    private readonly List<string> _created = [];
    private readonly List<Frame> _frames = [];
    private Clause _clause;
    private int _verbIndex = -1;
    private string? _verb;
    private int _cteBodyAt = -1;
    private SqlTableReference? _pendingFunction;

    private SqlStatementParser(string text, SqlToken[] tokens, int from, int to, SqlTextRange range)
    {
        _text = text;
        _tokens = tokens;
        _from = from;
        _count = to - from;
        _range = range;
    }

    private enum ClauseState : byte
    {
        None,
        ExpectTable,
        AfterTable,
    }

    private enum Introducer : byte
    {
        None,
        From,
        Join,
        Using,
        Update,
        Into,
    }

    private enum FrameKind : byte
    {
        Root,
        Subquery,
        Call,
        Group,

        /// <summary>A parenthesized join in FROM, <c>FROM (a JOIN b ON ...)</c>, whose contents are still table positions.</summary>
        JoinGroup,
    }

    /// <summary>Parses the significant tokens <c>[from, to)</c> of <paramref name="tokens"/>, which lie in <paramref name="range"/>.</summary>
    public static SqlStatementModel Parse(string text, SqlToken[] tokens, int from, int to, SqlTextRange range) =>
        new SqlStatementParser(text, tokens, from, to, range).Run();

    private SqlStatementModel Run()
    {
        _scopes.Add(new SqlScope(-1, _range.Start, _range.End));
        _frames.Add(new Frame(FrameKind.Root, 0, null, IsCommonTableExpressionBody: false, default));
        FindVerb();
        var leader = _count > 0 && _tokens[_from].Kind == SqlTokenKind.Word ? Span(0) : default;
        ReadCreatedName(leader);

        for (var i = 0; i < _count; i++)
        {
            var token = Token(i);
            switch (token.Kind)
            {
                case SqlTokenKind.OpenParen:
                    OpenFrame(i);
                    continue;
                case SqlTokenKind.CloseParen:
                    i = CloseFrame(i);
                    continue;
                case SqlTokenKind.Comma:
                    _clause.State = _clause.State == ClauseState.AfterTable && _clause.Introducer is Introducer.From or Introducer.Update
                        ? ClauseState.ExpectTable
                        : ClauseState.None;
                    continue;
                case SqlTokenKind.Word or SqlTokenKind.QuotedIdentifier:
                    break;
                default:
                    _clause.State = ClauseState.None;
                    continue;
            }

            if (_clause.State == ClauseState.AfterTable)
            {
                _clause.State = ClauseState.None;
            }

            var isKeyword = token.Kind == SqlTokenKind.Word && SqlKeywords.IsKeyword(Span(i));
            if (_clause.State == ClauseState.ExpectTable)
            {
                if (IsWord(i, "ONLY") || IsWord(i, "LATERAL"))
                {
                    continue;
                }

                if (!isKeyword)
                {
                    i = _clause.IntoCreates ? ReadCreatedTarget(i) : ReadTableReference(i);
                    continue;
                }

                _clause.State = ClauseState.None;
            }

            if (token.Kind == SqlTokenKind.Word && TryReadClauseWord(ref i))
            {
                continue;
            }

            if (!isKeyword)
            {
                i = ReadName(i);
            }
        }

        var leaderIsData = !leader.IsEmpty && DataLeaderLookup.Contains(leader);
        return new SqlStatementModel(
            _range,
            _verb,
            isDataStatement: leaderIsData && _verb is not null,
            changesSchemaContext: ChangesSchemaContext(leader),
            [.. _scopes],
            [.. _tables],
            [.. _ctes],
            [.. _qualified],
            [.. _names],
            [.. _created]);
    }

    /// <summary>Handles a word that opens a table position or a WITH list. Returns false for any other word.</summary>
    private bool TryReadClauseWord(ref int i)
    {
        var allowsTables = _frames[^1].Kind is FrameKind.Root or FrameKind.Subquery or FrameKind.JoinGroup;
        if (allowsTables && ((IsWord(i, "FROM") && !IsDistinctFrom(i)) || IsWord(i, "APPLY")))
        {
            Expect(Introducer.From);
            return true;
        }

        // ClickHouse's ARRAY JOIN unnests a column of the table before it; what follows is not a table.
        if (allowsTables && ((IsWord(i, "JOIN") && !IsWord(i - 1, "ARRAY")) || IsWord(i, "STRAIGHT_JOIN")))
        {
            Expect(Introducer.Join);
            return true;
        }

        if (allowsTables && IsWord(i, "USING"))
        {
            Expect(Introducer.Using);
            return true;
        }

        // UPDATE names a table only as the statement's verb: ON UPDATE, FOR UPDATE and DO UPDATE are clauses.
        if (IsWord(i, "UPDATE") && i == _verbIndex)
        {
            Expect(Introducer.Update);
            return true;
        }

        if (allowsTables && IsWord(i, "INTO"))
        {
            Expect(Introducer.Into);

            // SELECT ... INTO makes a new table (or fills variables); only INSERT, REPLACE and MERGE write into one.
            _clause.IntoCreates = _verb is not ("INSERT" or "REPLACE" or "MERGE");
            return true;
        }

        if (i == 0 && IsWord(i, "TABLE"))
        {
            Expect(Introducer.From);
            return true;
        }

        if (IsWord(i, "WITH"))
        {
            if (TryReadCommonTableExpression(i + 1, _frames[^1].Scope, out var bodyAt))
            {
                i = bodyAt - 1;
            }

            return true;
        }

        return false;
    }

    private void Expect(Introducer introducer) => _clause = new Clause(ClauseState.ExpectTable, introducer, IntoCreates: false);

    private void OpenFrame(int i)
    {
        var outer = _frames[^1];
        var isCteBody = _cteBodyAt == i;
        var expectsTable = _clause.State == ClauseState.ExpectTable;
        SqlTableReference? pending = null;
        FrameKind kind;
        var scope = outer.Scope;
        if (isCteBody || IsWord(i + 1, "SELECT") || IsWord(i + 1, "WITH") || IsWord(i + 1, "VALUES"))
        {
            kind = FrameKind.Subquery;
            scope = _scopes.Count;
            _scopes.Add(new SqlScope(outer.Scope, Token(i).Start, _range.End));
            if (expectsTable && _clause.Introducer is Introducer.From or Introducer.Join or Introducer.Using)
            {
                pending = new SqlTableReference(SqlTableReferenceKind.Subquery, new SqlTextRange(Token(i).Start, 1), null, string.Empty, outer.Scope);
                _tables.Add(pending);
            }
        }
        else if (expectsTable && _clause.Introducer is Introducer.From or Introducer.Join)
        {
            kind = FrameKind.JoinGroup;
        }
        else if (i > 0 && IsName(i - 1) && (Token(i - 1).Kind == SqlTokenKind.QuotedIdentifier || !SqlKeywords.IsKeyword(Span(i - 1)) || SqlKeywords.IsFunction(Span(i - 1))))
        {
            kind = FrameKind.Call;
            pending = _pendingFunction;
        }
        else
        {
            kind = FrameKind.Group;
        }

        _pendingFunction = null;
        if (isCteBody)
        {
            _cteBodyAt = -1;
        }

        _frames.Add(new Frame(kind, scope, pending, isCteBody, _clause));
        _clause = kind == FrameKind.JoinGroup ? _clause : default;
    }

    private int CloseFrame(int i)
    {
        if (_frames.Count == 1)
        {
            _clause = default;
            return i;
        }

        var frame = _frames[^1];
        _frames.RemoveAt(_frames.Count - 1);
        if (frame.Kind == FrameKind.Subquery)
        {
            var scope = _scopes[frame.Scope];
            _scopes[frame.Scope] = scope with { End = Token(i).End };
        }

        _clause = frame.Saved;
        if (frame.Pending is { } pending)
        {
            i = ReadAlias(i + 1, pending);
            _clause.State = ClauseState.AfterTable;
        }
        else
        {
            _clause.State = frame.Kind == FrameKind.JoinGroup ? ClauseState.AfterTable : ClauseState.None;
        }

        if (frame.IsCommonTableExpressionBody && Is(i + 1, SqlTokenKind.Comma)
            && TryReadCommonTableExpression(i + 2, _frames[^1].Scope, out var bodyAt))
        {
            i = bodyAt - 1;
        }

        return i;
    }

    /// <summary>Reads <c>[schema.]name [AS] [alias]</c> at a table position and returns the index of its last token.</summary>
    private int ReadTableReference(int i)
    {
        var count = ChainLength(i);
        var last = i + (2 * (count - 1));
        var name = NameOf(last);
        var schema = count >= 2 ? NameOf(last - 2) : null;
        var scope = _frames[^1].Scope;

        // A name followed by arguments is a table function after FROM; after INTO or UPDATE the parenthesis is a column list.
        if (Is(last + 1, SqlTokenKind.OpenParen) && _clause.Introducer is Introducer.From or Introducer.Join or Introducer.Using)
        {
            var function = new SqlTableReference(SqlTableReferenceKind.Function, Range(last), schema, name, scope);
            _tables.Add(function);
            _pendingFunction = function;
            _clause.State = ClauseState.AfterTable;
            return last;
        }

        var cte = schema is null ? FindCommonTableExpression(name, scope) : null;
        var reference = new SqlTableReference(
            cte is null ? SqlTableReferenceKind.Table : SqlTableReferenceKind.CommonTableExpression,
            Range(last),
            schema,
            name,
            scope)
        {
            CommonTableExpression = cte,
        };
        _tables.Add(reference);
        _clause.State = ClauseState.AfterTable;
        return ReadAlias(last + 1, reference);
    }

    /// <summary>Reads an optional alias at <paramref name="j"/> and returns the index of the last token it used.</summary>
    private int ReadAlias(int j, SqlTableReference reference)
    {
        var at = -1;
        if (IsWord(j, "AS") && IsName(j + 1))
        {
            at = j + 1;
        }
        else if (Is(j, SqlTokenKind.QuotedIdentifier)
            || (Is(j, SqlTokenKind.Word) && !SqlKeywords.IsKeyword(Span(j)) && !NeverAliasLookup.Contains(Span(j))))
        {
            at = j;
        }

        if (at < 0)
        {
            return j - 1;
        }

        reference.Alias = NameOf(at);
        reference.AliasRange = Range(at);
        return at;
    }

    private int ReadCreatedTarget(int i)
    {
        var count = ChainLength(i);
        var last = i + (2 * (count - 1));
        _created.Add(NameOf(last));
        _clause = default;
        return last;
    }

    /// <summary>Reads a dotted name outside a table position, or a plain name, and returns the index of its last token.</summary>
    private int ReadName(int i)
    {
        // After :: or AS a name is a type or an output alias, never a column of a table.
        var count = ChainLength(i);
        var last = i + (2 * (count - 1));
        if (i > 0 && (IsWord(i - 1, "AS") || (Is(i - 1, SqlTokenKind.Operator) && Span(i - 1).EndsWith("::"))))
        {
            return last;
        }

        if (Is(last + 1, SqlTokenKind.OpenParen))
        {
            return last;
        }

        var scope = _frames[^1].Scope;
        if (Is(last + 1, SqlTokenKind.Dot) && Is(last + 2, SqlTokenKind.Operator) && Span(last + 2).StartsWith('*'))
        {
            var schema = count >= 2 ? NameOf(last - 2) : null;
            _qualified.Add(new SqlQualifiedReference(Range(last), NameOf(last), schema, null, null, scope));
            return last + 2;
        }

        if (count == 1)
        {
            _names.Add(new SqlNameOccurrence(Range(i), NameOf(i), scope));
            return i;
        }

        _qualified.Add(new SqlQualifiedReference(
            Range(last - 2),
            NameOf(last - 2),
            count >= 3 ? NameOf(last - 4) : null,
            Range(last),
            NameOf(last),
            scope));
        return last;
    }

    /// <summary>
    /// Matches <c>name [(columns)] AS [NOT] [MATERIALIZED] (</c> at <paramref name="j"/>, after WITH or a comma between
    /// definitions, and records the name. The body's parenthesis is then read as a subquery.
    /// </summary>
    private bool TryReadCommonTableExpression(int j, int scope, out int bodyAt)
    {
        bodyAt = -1;
        if (IsWord(j, "RECURSIVE"))
        {
            j++;
        }

        if (!IsName(j))
        {
            return false;
        }

        var k = j + 1;
        if (Is(k, SqlTokenKind.OpenParen))
        {
            k = MatchingClose(k);
            if (k < 0)
            {
                return false;
            }

            k++;
        }

        if (!IsWord(k, "AS"))
        {
            return false;
        }

        k++;
        if (IsWord(k, "NOT"))
        {
            k++;
        }

        if (IsWord(k, "MATERIALIZED"))
        {
            k++;
        }

        if (!Is(k, SqlTokenKind.OpenParen))
        {
            return false;
        }

        _ctes.Add(new SqlCommonTableExpression(Range(j), NameOf(j), scope));
        _cteBodyAt = k;
        bodyAt = k;
        return true;
    }

    private SqlCommonTableExpression? FindCommonTableExpression(string name, int scope)
    {
        foreach (var cte in _ctes)
        {
            if (!string.Equals(cte.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            for (var s = scope; s >= 0; s = _scopes[s].Parent)
            {
                if (s == cte.Scope)
                {
                    return cte;
                }
            }
        }

        return null;
    }

    /// <summary>The main verb: the first SELECT, INSERT, UPDATE, DELETE, MERGE or the like outside parentheses.</summary>
    private void FindVerb()
    {
        var depth = 0;
        var lookup = VerbLookup;
        for (var i = 0; i < _count; i++)
        {
            switch (Token(i).Kind)
            {
                case SqlTokenKind.OpenParen:
                    depth++;
                    break;
                case SqlTokenKind.CloseParen:
                    depth = Math.Max(0, depth - 1);
                    break;
                case SqlTokenKind.Word when depth == 0 && lookup.TryGetValue(Span(i), out var verb):
                    _verb = verb;
                    _verbIndex = i;
                    return;
            }
        }
    }

    /// <summary>Records the table or view a CREATE statement makes, so the script's later statements may name it.</summary>
    private void ReadCreatedName(ReadOnlySpan<char> leader)
    {
        if (!leader.Equals("CREATE", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        for (var i = 1; i < Math.Min(_count, 8); i++)
        {
            if (!IsWord(i, "TABLE") && !IsWord(i, "VIEW"))
            {
                continue;
            }

            var at = i + 1;
            if (IsWord(at, "IF"))
            {
                at += IsWord(at + 1, "NOT") ? 3 : 2;
            }

            if (IsName(at))
            {
                _created.Add(NameOf(at + (2 * (ChainLength(at) - 1))));
            }

            return;
        }
    }

    private bool ChangesSchemaContext(ReadOnlySpan<char> leader) =>
        leader.Equals("USE", StringComparison.OrdinalIgnoreCase)
        || (leader.Equals("SET", StringComparison.OrdinalIgnoreCase) && (IsWord(1, "SEARCH_PATH") || IsWord(1, "SCHEMA")))
        || (leader.Equals("ALTER", StringComparison.OrdinalIgnoreCase) && IsWord(1, "SESSION"));

    /// <summary><c>IS [NOT] DISTINCT FROM</c> compares two values; the FROM there opens no table list.</summary>
    private bool IsDistinctFrom(int i) => IsWord(i - 1, "DISTINCT") && (IsWord(i - 2, "IS") || IsWord(i - 2, "NOT"));

    /// <summary>How many dot-separated name parts start at <paramref name="i"/>.</summary>
    private int ChainLength(int i)
    {
        var count = 1;
        while (Is(i + (2 * count) - 1, SqlTokenKind.Dot) && IsName(i + (2 * count)))
        {
            count++;
        }

        return count;
    }

    private int MatchingClose(int open)
    {
        var depth = 0;
        for (var i = open; i < _count; i++)
        {
            var kind = Token(i).Kind;
            if (kind == SqlTokenKind.OpenParen)
            {
                depth++;
            }
            else if (kind == SqlTokenKind.CloseParen && --depth == 0)
            {
                return i;
            }
        }

        return -1;
    }

    private SqlToken Token(int i) => _tokens[_from + i];

    private ReadOnlySpan<char> Span(int i) => Token(i).Slice(_text);

    private SqlTextRange Range(int i)
    {
        var token = Token(i);
        return new SqlTextRange(token.Start, token.Length);
    }

    private bool Is(int i, SqlTokenKind kind) => (uint)i < (uint)_count && Token(i).Kind == kind;

    private bool IsName(int i) => Is(i, SqlTokenKind.Word) || Is(i, SqlTokenKind.QuotedIdentifier);

    private bool IsWord(int i, string word) => Is(i, SqlTokenKind.Word) && Span(i).Equals(word, StringComparison.OrdinalIgnoreCase);

    /// <summary>A name without its quotes, with a doubled closing quote read as one.</summary>
    private string NameOf(int i)
    {
        var token = Token(i);
        var span = token.Slice(_text);
        if (token.Kind != SqlTokenKind.QuotedIdentifier || span.Length == 0)
        {
            return span.ToString();
        }

        var close = span[0] == '[' ? ']' : span[0];
        var inner = token.IsUnterminated || span.Length < 2 ? span[1..] : span[1..^1];
        if (inner.IndexOf(close) < 0)
        {
            return inner.ToString();
        }

        return inner.ToString().Replace(new string(close, 2), close.ToString(), StringComparison.Ordinal);
    }

    private record struct Clause(ClauseState State, Introducer Introducer, bool IntoCreates);

    private readonly record struct Frame(FrameKind Kind, int Scope, SqlTableReference? Pending, bool IsCommonTableExpressionBody, Clause Saved);
}
