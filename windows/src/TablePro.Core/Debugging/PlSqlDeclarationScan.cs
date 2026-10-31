using System.Globalization;
using System.Text;

namespace TablePro.Core.Debugging;

/// <summary>
/// The names a PL/SQL unit declares, read from its source. DBMS_DEBUG has no call that lists a frame's variables, only
/// GET_VALUE by name, so the debugger asks for each name this scan finds in scope at the paused line.
/// </summary>
/// <remarks>
/// PL/Scope would give exact declarations, but only for units compiled with <c>PLSCOPE_SETTINGS='IDENTIFIERS:ALL'</c>,
/// which is not the default and which a compile for debug keeps. A name offered here that is not in scope comes back from
/// GET_VALUE as no such object and is dropped, so the server has the last word on scope.
/// </remarks>
public sealed class PlSqlDeclarationScan
{
    private readonly List<Block> _blocks;

    public PlSqlDeclarationScan(string source)
    {
        var parser = new Parser(Lexer.Tokens(source));
        parser.Run();
        Subprograms = parser.Subprograms;
        Declarations = [.. parser.Declarations.Where(d => d.Subprogram is not { } index || parser.Subprograms[index].IsDefinition)];
        _blocks = parser.Blocks;
    }

    public IReadOnlyList<PlSqlDeclaration> Declarations { get; }

    public IReadOnlyList<PlSqlSubprogram> Subprograms { get; }

    public IEnumerable<PlSqlDeclaration> PackageVariables => Declarations.Where(d => d.Subprogram is null);

    /// <summary>The header lines of every unit-level overload named <paramref name="name"/>; the debugger cannot tell which one it called.</summary>
    public IReadOnlyList<int> HeaderLines(string name) =>
        [.. Subprograms.Where(s => s.IsDefinition && s.Depth == 1 && s.Name == name).Select(s => s.HeaderLine)];

    public int? InnermostSubprogram(int line)
    {
        int? best = null;
        for (var i = 0; i < Subprograms.Count; i++)
        {
            var subprogram = Subprograms[i];
            if (!subprogram.IsDefinition || subprogram.HeaderLine > line || line > (subprogram.EndLine ?? int.MaxValue))
            {
                continue;
            }

            if (best is { } current && Subprograms[current].HeaderLine > subprogram.HeaderLine)
            {
                continue;
            }

            best = i;
        }

        return best;
    }

    /// <summary>Parameters and locals of the subprogram running at <paramref name="line"/>, then of each subprogram around it.</summary>
    public IReadOnlyList<PlSqlDeclaration> Candidates(int line)
    {
        if (InnermostSubprogram(line) is not { } innermost)
        {
            return [];
        }

        var chain = new List<int>();
        for (int? current = innermost; current is { } index; current = Subprograms[index].Parent)
        {
            chain.Add(index);
        }

        var visible = new List<PlSqlDeclaration>();

        // The lexer upper-cases unquoted names, so names compare as Oracle resolves them: y is "Y", x is not "x".
        var innermostBlock = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var index in chain)
        {
            foreach (var declaration in Declarations)
            {
                if (declaration.Subprogram != index || !Encloses(declaration.Block, line))
                {
                    continue;
                }

                visible.Add(declaration);

                // Blocks are numbered as they open, so of the blocks around one line the innermost has the highest number.
                if (declaration.Block is { } block && block > innermostBlock.GetValueOrDefault(declaration.Name, -1))
                {
                    innermostBlock[declaration.Name] = block;
                }
            }
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        return [.. visible.Where(d => d.Block == innermostBlock.GetValueOrDefault(d.Name, -2) && seen.Add(d.Name))];
    }

    private bool Encloses(int? block, int line) =>
        block is { } index && _blocks[index].StartLine <= line && line <= (_blocks[index].EndLine ?? int.MaxValue);

    private sealed class Block(int startLine)
    {
        public int StartLine { get; } = startLine;

        public int? EndLine { get; set; }
    }

    private enum TokenKind
    {
        Word,
        Quoted,
        Symbol,
        Other,
    }

    private readonly record struct Token(TokenKind Kind, string Text, int Line)
    {
        public bool IsName => Kind is TokenKind.Word or TokenKind.Quoted;

        public bool IsWord(params ReadOnlySpan<string> words)
        {
            if (Kind != TokenKind.Word)
            {
                return false;
            }

            foreach (var word in words)
            {
                if (Text == word)
                {
                    return true;
                }
            }

            return false;
        }

        public bool IsSymbol(string symbol) => Kind == TokenKind.Symbol && Text == symbol;
    }

    private static class Lexer
    {
        public static List<Token> Tokens(string source)
        {
            var tokens = new List<Token>();
            var index = 0;
            var line = 1;

            char? Peek(int offset = 0) => index + offset < source.Length ? source[index + offset] : null;

            static bool IsWordPart(char c) => char.IsLetterOrDigit(c) || c is '_' or '$' or '#';

            void SkipString(char closing, bool doubled)
            {
                while (Peek() is { } c)
                {
                    index++;
                    if (c == '\n')
                    {
                        line++;
                    }

                    if (c != closing)
                    {
                        continue;
                    }

                    if (doubled)
                    {
                        if (Peek() == closing)
                        {
                            index++;
                            continue;
                        }

                        return;
                    }

                    if (Peek() == '\'')
                    {
                        index++;
                        return;
                    }
                }
            }

            while (Peek() is { } c)
            {
                if (c == '\n')
                {
                    line++;
                    index++;
                }
                else if (char.IsWhiteSpace(c))
                {
                    index++;
                }
                else if (c == '-' && Peek(1) == '-')
                {
                    while (Peek() is { } next && next != '\n')
                    {
                        index++;
                    }
                }
                else if (c == '/' && Peek(1) == '*')
                {
                    index += 2;
                    while (Peek() is { } next && !(next == '*' && Peek(1) == '/'))
                    {
                        if (next == '\n')
                        {
                            line++;
                        }

                        index++;
                    }

                    index += 2;
                }
                else if (c == '\'')
                {
                    var startLine = line;
                    index++;
                    SkipString('\'', doubled: true);
                    tokens.Add(new Token(TokenKind.Other, "'", startLine));
                }
                else if (c is 'q' or 'Q' && Peek(1) == '\'' && Peek(2) is { } open)
                {
                    // Alternative quoting, q'[...]', closes with the opening delimiter's partner and a quote.
                    var startLine = line;
                    var closing = open switch
                    {
                        '[' => ']',
                        '{' => '}',
                        '(' => ')',
                        '<' => '>',
                        _ => open,
                    };
                    index += 3;
                    SkipString(closing, doubled: false);
                    tokens.Add(new Token(TokenKind.Other, "'", startLine));
                }
                else if (c == '"')
                {
                    var startLine = line;
                    index++;
                    var text = new StringBuilder();
                    while (Peek() is { } next && next != '"')
                    {
                        if (next == '\n')
                        {
                            line++;
                        }

                        text.Append(next);
                        index++;
                    }

                    index++;
                    tokens.Add(new Token(TokenKind.Quoted, text.ToString(), startLine));
                }
                else if (char.IsLetter(c))
                {
                    var start = index;
                    while (Peek() is { } next && IsWordPart(next))
                    {
                        index++;
                    }

                    tokens.Add(new Token(TokenKind.Word, source[start..index].ToUpperInvariant(), line));
                }
                else if (char.IsAsciiDigit(c))
                {
                    var start = index;
                    while (Peek() is { } next && (IsWordPart(next) || next == '.'))
                    {
                        index++;
                    }

                    tokens.Add(new Token(TokenKind.Other, source[start..index], line));
                }
                else if (c == ':' && Peek(1) == '=')
                {
                    tokens.Add(new Token(TokenKind.Symbol, ":=", line));
                    index += 2;
                }
                else if (c == '=' && Peek(1) == '>')
                {
                    tokens.Add(new Token(TokenKind.Symbol, "=>", line));
                    index += 2;
                }
                else
                {
                    tokens.Add(new Token(TokenKind.Symbol, c.ToString(CultureInfo.InvariantCulture), line));
                    index++;
                }
            }

            return tokens;
        }
    }

    private enum Phase
    {
        Declare,
        Body,
    }

    private enum FrameKind
    {
        Unit,
        Subprogram,
        Block,
        Case,
        Loop,
    }

    // Block is the block a subprogram, block or FOR loop opened; a FOR loop's holds its index until END LOOP.
    private readonly record struct Frame(FrameKind Kind, Phase Phase = Phase.Body, int Subprogram = -1, int? Block = null);

    private sealed class Parser(List<Token> tokens)
    {
        private readonly List<Frame> _stack = [];
        private int _position;
        private int? _pendingLoopBlock;

        public List<PlSqlDeclaration> Declarations { get; } = [];

        public List<PlSqlSubprogram> Subprograms { get; } = [];

        public List<Block> Blocks { get; } = [];

        private Token? Current => _position < tokens.Count ? tokens[_position] : null;

        private Token? PeekAt(int offset) => _position + offset < tokens.Count ? tokens[_position + offset] : null;

        private Frame? Top => _stack.Count > 0 ? _stack[^1] : null;

        private int? CurrentSubprogram
        {
            get
            {
                for (var i = _stack.Count - 1; i >= 0; i--)
                {
                    if (_stack[i].Kind == FrameKind.Subprogram)
                    {
                        return _stack[i].Subprogram;
                    }
                }

                return null;
            }
        }

        private int? CurrentBlock
        {
            get
            {
                for (var i = _stack.Count - 1; i >= 0; i--)
                {
                    if (_stack[i].Kind is FrameKind.Subprogram or FrameKind.Block)
                    {
                        return _stack[i].Block;
                    }
                }

                return null;
            }
        }

        private int SubprogramDepth => _stack.Count(f => f.Kind == FrameKind.Subprogram);

        public void Run()
        {
            ReadUnitHeader();
            while (Current is { } token)
            {
                if (Top is not { } frame)
                {
                    if (token.IsWord("PROCEDURE", "FUNCTION"))
                    {
                        ReadSubprogramHeader();
                    }
                    else if (token.IsWord("DECLARE"))
                    {
                        _stack.Add(new Frame(FrameKind.Block, Phase.Declare, Block: OpenBlock(token.Line)));
                        _position++;
                    }
                    else if (token.IsWord("BEGIN"))
                    {
                        _stack.Add(new Frame(FrameKind.Block, Phase.Body, Block: OpenBlock(token.Line)));
                        _position++;
                    }
                    else
                    {
                        _position++;
                    }

                    continue;
                }

                if (frame.Kind is FrameKind.Unit or FrameKind.Subprogram or FrameKind.Block && frame.Phase == Phase.Declare)
                {
                    ReadDeclaration();
                }
                else
                {
                    ReadBodyToken();
                }
            }
        }

        // PACKAGE [BODY] name IS, TYPE BODY name IS, or a trigger; a standalone PROCEDURE or FUNCTION is read as a subprogram.
        private void ReadUnitHeader()
        {
            if (Current is not { } first)
            {
                return;
            }

            if (first.IsWord("CREATE"))
            {
                while (Current is { } token && !token.IsWord("PACKAGE", "PROCEDURE", "FUNCTION", "TYPE", "TRIGGER"))
                {
                    _position++;
                }
            }

            if (Current is not { } head)
            {
                return;
            }

            if (head.IsWord("PACKAGE", "TYPE"))
            {
                while (Current is { } token && !token.IsWord("IS", "AS"))
                {
                    _position++;
                }

                _position++;
                _stack.Add(new Frame(FrameKind.Unit, Phase.Declare));
            }
            else if (head.IsWord("TRIGGER"))
            {
                while (Current is { } token && !token.IsWord("DECLARE", "BEGIN", "COMPOUND"))
                {
                    _position++;
                }
            }
        }

        private void ReadSubprogramHeader()
        {
            if (Current is not { } keyword)
            {
                return;
            }

            _position++;
            if (Current is not { IsName: true } nameToken)
            {
                return;
            }

            _position++;
            var index = Subprograms.Count;
            Subprograms.Add(new PlSqlSubprogram(nameToken.Text, keyword.Line, CurrentSubprogram, SubprogramDepth + 1));

            // From the header line: the first stop is there, with the parameters already bound.
            var block = OpenBlock(keyword.Line);
            if (Current is { } open && open.IsSymbol("("))
            {
                ReadParameters(index, block);
            }

            var depth = 0;
            while (Current is { } token)
            {
                if (token.IsSymbol("("))
                {
                    depth++;
                }

                if (token.IsSymbol(")"))
                {
                    depth--;
                }

                if (depth == 0 && token.IsSymbol(";"))
                {
                    _position++;
                    return;
                }

                if (depth == 0 && token.IsWord("IS", "AS"))
                {
                    _position++;

                    // IS LANGUAGE C and AS EXTERNAL bodies have no PL/SQL to step through.
                    if (Current is { } next && next.IsWord("LANGUAGE", "EXTERNAL"))
                    {
                        SkipStatement();
                        return;
                    }

                    Subprograms[index].IsDefinition = true;
                    _stack.Add(new Frame(FrameKind.Subprogram, Phase.Declare, index, block));
                    return;
                }

                _position++;
            }
        }

        private void ReadParameters(int subprogram, int block)
        {
            _position++;
            var parts = new List<Token>();
            var depth = 1;
            while (Current is { } token)
            {
                _position++;
                if (token.IsSymbol("("))
                {
                    depth++;
                }

                if (token.IsSymbol(")"))
                {
                    depth--;
                    if (depth == 0)
                    {
                        AddParameter(parts, subprogram, block);
                        return;
                    }
                }

                if (depth == 1 && token.IsSymbol(","))
                {
                    AddParameter(parts, subprogram, block);
                    parts = [];
                    continue;
                }

                parts.Add(token);
            }
        }

        private void AddParameter(List<Token> parts, int subprogram, int block)
        {
            if (parts.Count == 0 || !parts[0].IsName)
            {
                return;
            }

            var name = parts[0];
            var rest = 1;
            while (rest < parts.Count && parts[rest].IsWord("IN", "OUT", "NOCOPY"))
            {
                rest++;
            }

            var type = parts.Skip(rest).TakeWhile(t => !t.IsSymbol(":=") && !t.IsWord("DEFAULT"));
            Declarations.Add(new PlSqlDeclaration(name.Text, name.Kind == TokenKind.Quoted, TypeText(type), name.Line, PlSqlDeclarationKind.Parameter, subprogram, block));
        }

        private void ReadDeclaration()
        {
            if (Current is not { } token || Top is not { } frame)
            {
                return;
            }

            if (token.IsWord("BEGIN"))
            {
                _position++;
                if (frame.Kind is FrameKind.Unit or FrameKind.Subprogram or FrameKind.Block)
                {
                    _stack[^1] = frame with { Phase = Phase.Body };
                }

                return;
            }

            if (token.IsWord("END"))
            {
                CloseFrame(token.Line);
                SkipStatement();
                return;
            }

            if (token.IsWord("PROCEDURE", "FUNCTION"))
            {
                ReadSubprogramHeader();
                return;
            }

            // A type body's method prefixes.
            if (token.IsWord("MEMBER", "STATIC", "CONSTRUCTOR", "MAP", "ORDER", "OVERRIDING", "FINAL", "INSTANTIABLE"))
            {
                _position++;
                return;
            }

            if (token.IsWord("TYPE", "SUBTYPE", "CURSOR", "PRAGMA") || !token.IsName)
            {
                SkipStatement();
                return;
            }

            _position++;
            var isConstant = false;
            if (Current is { } constant && constant.IsWord("CONSTANT"))
            {
                isConstant = true;
                _position++;
            }

            if (Current is { } exception && exception.IsWord("EXCEPTION"))
            {
                SkipStatement();
                return;
            }

            var typeTokens = new List<Token>();
            var depth = 0;
            while (Current is { } next)
            {
                if (next.IsSymbol("("))
                {
                    depth++;
                }

                if (next.IsSymbol(")"))
                {
                    depth--;
                }

                if (depth == 0 && (next.IsSymbol(";") || next.IsSymbol(":=") || next.IsWord("DEFAULT", "NOT")))
                {
                    break;
                }

                typeTokens.Add(next);
                _position++;
            }

            Declarations.Add(new PlSqlDeclaration(
                token.Text,
                token.Kind == TokenKind.Quoted,
                TypeText(typeTokens),
                token.Line,
                isConstant ? PlSqlDeclarationKind.Constant : PlSqlDeclarationKind.Variable,
                CurrentSubprogram,
                CurrentBlock));
            SkipStatement();
        }

        private void ReadBodyToken()
        {
            if (Current is not { } token)
            {
                return;
            }

            _position++;
            if (token.IsWord("BEGIN"))
            {
                _stack.Add(new Frame(FrameKind.Block, Phase.Body, Block: OpenBlock(token.Line)));
            }
            else if (token.IsWord("DECLARE"))
            {
                _stack.Add(new Frame(FrameKind.Block, Phase.Declare, Block: OpenBlock(token.Line)));
            }
            else if (token.IsWord("CASE"))
            {
                _stack.Add(new Frame(FrameKind.Case));
            }
            else if (token.IsWord("LOOP"))
            {
                _stack.Add(new Frame(FrameKind.Loop, Block: _pendingLoopBlock));
                _pendingLoopBlock = null;
            }
            else if (token.IsWord("END"))
            {
                if (Current is { } loop && loop.IsWord("LOOP"))
                {
                    _position++;
                    if (Top is { Kind: FrameKind.Loop })
                    {
                        CloseFrame(token.Line);
                    }
                }
                else if (Current is { } endIf && endIf.IsWord("IF"))
                {
                    _position++;
                }
                else if (Current is { } endCase && endCase.IsWord("CASE"))
                {
                    _position++;
                    if (Top is { Kind: FrameKind.Case })
                    {
                        _stack.RemoveAt(_stack.Count - 1);
                    }
                }
                else if (Top is { Kind: FrameKind.Case })
                {
                    _stack.RemoveAt(_stack.Count - 1);
                }
                else
                {
                    CloseFrame(token.Line);
                    SkipStatement();
                }
            }
            else if (token.IsWord("FOR") && Current is { IsName: true } name && PeekAt(1) is { } keyword && keyword.IsWord("IN"))
            {
                var block = OpenBlock(name.Line);
                _pendingLoopBlock = block;
                Declarations.Add(new PlSqlDeclaration(name.Text, name.Kind == TokenKind.Quoted, null, name.Line, PlSqlDeclarationKind.Iterator, CurrentSubprogram, block));
            }
        }

        private void CloseFrame(int line)
        {
            if (Top is not { } frame)
            {
                return;
            }

            _stack.RemoveAt(_stack.Count - 1);
            switch (frame.Kind)
            {
                case FrameKind.Subprogram:
                    Subprograms[frame.Subprogram].EndLine = line;
                    Blocks[frame.Block!.Value].EndLine = line;
                    break;
                case FrameKind.Block or FrameKind.Loop when frame.Block is { } block:
                    Blocks[block].EndLine = line;
                    break;
            }
        }

        private int OpenBlock(int line)
        {
            Blocks.Add(new Block(line));
            return Blocks.Count - 1;
        }

        private void SkipStatement()
        {
            var depth = 0;
            while (Current is { } token)
            {
                _position++;
                if (token.IsSymbol("("))
                {
                    depth++;
                }

                if (token.IsSymbol(")"))
                {
                    depth--;
                }

                if (depth <= 0 && token.IsSymbol(";"))
                {
                    return;
                }
            }
        }

        private static string? TypeText(IEnumerable<Token> tokens)
        {
            var text = new StringBuilder();
            foreach (var token in tokens)
            {
                var piece = token.Kind == TokenKind.Quoted ? $"\"{token.Text}\"" : token.Text;
                var glued = text.Length == 0
                    || token.IsSymbol("(") || token.IsSymbol(")") || token.IsSymbol(",") || token.IsSymbol("%") || token.IsSymbol(".")
                    || text[^1] is '(' or '%' or '.';
                if (!glued)
                {
                    text.Append(' ');
                }

                text.Append(piece);
            }

            return text.Length == 0 ? null : text.ToString();
        }
    }
}

public enum PlSqlDeclarationKind
{
    Parameter,
    Variable,
    Constant,
    Iterator,
}

/// <summary>
/// A declared name. <c>Subprogram</c> indexes <see cref="PlSqlDeclarationScan.Subprograms"/> and is null for a
/// package-level variable; <c>Block</c> is the block whose lines the name is visible on.
/// </summary>
public sealed record PlSqlDeclaration(string Name, bool IsQuoted, string? TypeText, int Line, PlSqlDeclarationKind Kind, int? Subprogram, int? Block)
{
    /// <summary>
    /// GET_VALUE reads its name as an identifier path, so a quoted <c>"a.b"</c> unquoted would name member b of a, and a
    /// lower-case or spaced name would not be found at all.
    /// </summary>
    public string LookupName => IsQuoted ? $"\"{Name}\"" : Name;
}

public sealed class PlSqlSubprogram(string name, int headerLine, int? parent, int depth)
{
    public string Name { get; } = name;

    public int HeaderLine { get; } = headerLine;

    public int? EndLine { get; internal set; }

    public int? Parent { get; } = parent;

    /// <summary>1 for a unit-level subprogram, 2 for one declared inside it, and so on.</summary>
    public int Depth { get; } = depth;

    /// <summary>False for a forward declaration or an external body, which has nothing to step through.</summary>
    public bool IsDefinition { get; internal set; }
}
