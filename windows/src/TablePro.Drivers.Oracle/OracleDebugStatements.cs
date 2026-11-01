using System.Globalization;
using System.Text;
using TablePro.Drivers.Oracle.Localization;

namespace TablePro.Drivers.Oracle;

internal enum OracleDebugReadiness
{
    Ready,
    NeedsDebugCompile,
    NotVisible,
}

internal abstract record OracleMissingPrivilege(string User)
{
    public sealed record DebugConnectSession(string User) : OracleMissingPrivilege(User);

    public sealed record DebugOnObject(string User) : OracleMissingPrivilege(User);
}

internal enum OracleDebugAmbiguityKind
{
    // Leaving these parameters at their defaults leaves nothing to tell this overload from another.
    NeedsValue,

    // The call matches another overload whatever values are given (PLS-00307).
    Unresolvable,
}

internal sealed record OracleDebugAmbiguity(OracleDebugAmbiguityKind Kind, IReadOnlyList<string> Parameters);

/// <summary>The block that runs the entry point, and its binds in the order <c>:b1</c>, <c>:b2</c> and so on name them.</summary>
internal sealed record OracleDebugInvocation(string Block, IReadOnlyList<string?> Binds);

internal sealed record OracleDebugInvocationReport(bool Succeeded, string? Error, IReadOnlyList<(string Name, string? Value)> Outputs, IReadOnlyList<string> Lines);

/// <summary>Text cannot become a value of this parameter's type, or no local of the type can even be declared.</summary>
internal sealed class OracleDebugArgumentException : Exception
{
    public OracleDebugArgumentException()
    {
    }

    public OracleDebugArgumentException(string message)
        : base(message)
    {
    }

    public OracleDebugArgumentException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public OracleDebugArgumentException(string name, string typeName, bool declarable)
        : base(declarable ? OracleStrings.Format("Oracle/TextToType", typeName, name) : OracleStrings.Format("Oracle/CannotPassType", typeName, name))
    {
        Name = name;
        TypeName = typeName;
        Declarable = declarable;
    }

    public string Name { get; } = string.Empty;

    public string TypeName { get; } = string.Empty;

    public bool Declarable { get; }
}

/// <summary>The catalog reads and the invocation block of the Oracle debugger.</summary>
internal static class OracleDebugStatements
{
    public static string Targets(string owner) => $"""
        SELECT OBJECT_NAME, OBJECT_TYPE
        FROM SYS.ALL_OBJECTS
        WHERE OWNER = {OracleDebugUnit.Literal(owner)}
          AND OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION', 'PACKAGE BODY')
        ORDER BY OBJECT_TYPE, OBJECT_NAME
        """;

    /// <summary>
    /// Debug information exists when the unit was compiled with PLSQL_DEBUG or at PLSQL_OPTIMIZE_LEVEL 1 or lower. At level
    /// 2 SET_BREAKPOINT still answers success and never fires.
    /// </summary>
    public static string Readiness(OracleDebugUnit unit) => $"""
        SELECT TO_CHAR(PLSQL_OPTIMIZE_LEVEL), PLSQL_DEBUG
        FROM SYS.ALL_PLSQL_OBJECT_SETTINGS
        WHERE OWNER = {OracleDebugUnit.Literal(unit.Owner)}
          AND NAME = {OracleDebugUnit.Literal(unit.Name)}
          AND TYPE = {OracleDebugUnit.Literal(unit.CodeUnit.Kind.TypeName())}
        """;

    public static OracleDebugReadiness ReadinessOf(IReadOnlyList<string?>? row)
    {
        if (row is null)
        {
            return OracleDebugReadiness.NotVisible;
        }

        var debug = string.Equals(row.Count > 1 ? row[1] : null, "TRUE", StringComparison.OrdinalIgnoreCase);
        if (debug)
        {
            return OracleDebugReadiness.Ready;
        }

        return row.Count > 0 && int.TryParse(row[0]?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var level) && level <= 1
            ? OracleDebugReadiness.Ready
            : OracleDebugReadiness.NeedsDebugCompile;
    }

    public static string Privileges(OracleDebugUnit unit) => $"""
        SELECT SYS_CONTEXT('USERENV', 'SESSION_USER'),
          TO_CHAR((SELECT COUNT(*) FROM SYS.SESSION_PRIVS WHERE PRIVILEGE = 'DEBUG CONNECT SESSION')),
          TO_CHAR((SELECT COUNT(*) FROM SYS.SESSION_PRIVS WHERE PRIVILEGE = 'DEBUG ANY PROCEDURE')),
          TO_CHAR((SELECT COUNT(*) FROM SYS.ALL_TAB_PRIVS
            WHERE TABLE_SCHEMA = {OracleDebugUnit.Literal(unit.Owner)}
              AND TABLE_NAME = {OracleDebugUnit.Literal(unit.Name)}
              AND PRIVILEGE = 'DEBUG'))
        FROM SYS.DUAL
        """;

    public static OracleMissingPrivilege? MissingPrivilege(IReadOnlyList<string?> row, OracleDebugUnit unit)
    {
        int Count(int index) =>
            index < row.Count && int.TryParse(row[index]?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var count) ? count : 0;

        var user = row.Count > 0 ? row[0] ?? string.Empty : string.Empty;
        if (Count(1) == 0)
        {
            return new OracleMissingPrivilege.DebugConnectSession(user);
        }

        return unit.Owner != user && Count(2) == 0 && Count(3) == 0 ? new OracleMissingPrivilege.DebugOnObject(user) : null;
    }

    /// <summary>One row per public subprogram and argument; a subprogram without arguments comes back once with NULLs.</summary>
    public static string EntryPoints(OracleDebugUnit unit)
    {
        var subprograms = unit.Kind.HasSubprograms()
            ? "p.OBJECT_TYPE = 'PACKAGE' AND p.PROCEDURE_NAME IS NOT NULL"
            : "p.OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION') AND p.PROCEDURE_NAME IS NULL";
        return $"""
            SELECT NVL(p.PROCEDURE_NAME, p.OBJECT_NAME), TO_CHAR(p.SUBPROGRAM_ID), p.OVERLOAD,
                   TO_CHAR(a.POSITION), a.ARGUMENT_NAME, a.DATA_TYPE, a.IN_OUT, a.DEFAULTED,
                   a.TYPE_OWNER, a.TYPE_NAME, a.TYPE_SUBNAME, a.PLS_TYPE
            FROM SYS.ALL_PROCEDURES p
            LEFT JOIN SYS.ALL_ARGUMENTS a
              ON a.OBJECT_ID = p.OBJECT_ID AND a.SUBPROGRAM_ID = p.SUBPROGRAM_ID AND a.DATA_LEVEL = 0
            WHERE p.OWNER = {OracleDebugUnit.Literal(unit.Owner)} AND p.OBJECT_NAME = {OracleDebugUnit.Literal(unit.Name)} AND {subprograms}
            ORDER BY p.SUBPROGRAM_ID, a.SEQUENCE
            """;
    }

    public static IReadOnlyList<OracleDebugEntryPoint> ParseEntryPoints(IReadOnlyList<IReadOnlyList<string?>> rows, OracleDebugUnit unit)
    {
        var order = new List<int>();
        var byId = new Dictionary<int, (string Name, string? Overload, List<OracleDebugParameter> Parameters, OracleDebugParameter? Result)>();
        foreach (var row in rows)
        {
            string? Cell(int index) => index < row.Count ? row[index] : null;
            if (Cell(0) is not { } name || !int.TryParse(Cell(1)?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var id))
            {
                continue;
            }

            if (!byId.TryGetValue(id, out var existing))
            {
                order.Add(id);
                existing = (name, Cell(2), [], null);
                byId[id] = existing;
            }

            if (Cell(5) is not { Length: > 0 } dataType)
            {
                continue;
            }

            var parameter = new OracleDebugParameter(
                Cell(4) ?? string.Empty,
                int.TryParse(Cell(3)?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var position) ? position : 0,
                dataType,
                OracleDebugParameter.ModeOf(Cell(6)),
                string.Equals(Cell(7), "Y", StringComparison.OrdinalIgnoreCase),
                Cell(8),
                Cell(9),
                Cell(10),
                Cell(11));
            if (parameter.Position == 0 && Cell(4) is null)
            {
                byId[id] = existing with { Result = parameter };
            }
            else
            {
                existing.Parameters.Add(parameter);
            }
        }

        return
        [
            .. order.Select(id =>
            {
                var entry = byId[id];
                return new OracleDebugEntryPoint(new OracleDebugEntry(unit.CodeUnit, entry.Name, id), entry.Overload, entry.Parameters, entry.Result);
            }),
        ];
    }

    public static string Source(OracleDebugUnit unit) => $"""
        SELECT TO_CHAR(LINE), TEXT
        FROM SYS.ALL_SOURCE
        WHERE OWNER = {OracleDebugUnit.Literal(unit.Owner)}
          AND NAME = {OracleDebugUnit.Literal(unit.Name)}
          AND TYPE = {OracleDebugUnit.Literal(unit.Kind.TypeName())}
        ORDER BY LINE
        """;

    /// <summary>Lines stay where ALL_SOURCE numbers them, because the debugger reports those numbers.</summary>
    public static string AssembleSource(IEnumerable<(int Line, string? Text)> rows)
    {
        var lines = new List<string>();
        foreach (var (line, raw) in rows.Where(r => r.Line >= 1).OrderBy(r => r.Line))
        {
            while (lines.Count < line - 1)
            {
                lines.Add(string.Empty);
            }

            var text = raw ?? string.Empty;
            if (text.EndsWith("\r\n", StringComparison.Ordinal))
            {
                text = text[..^2];
            }
            else if (text.EndsWith('\n') || text.EndsWith('\r'))
            {
                text = text[..^1];
            }

            if (lines.Count == line - 1)
            {
                lines.Add(text);
            }
            else
            {
                lines[line - 1] += text;
            }
        }

        return string.Join('\n', lines);
    }

    /// <summary>Every ORA- code in a server message, in order; the first is the error, the rest its stack.</summary>
    public static IReadOnlyList<int> ErrorCodes(string message)
    {
        var codes = new List<int>();
        var index = 0;
        while ((index = message.IndexOf("ORA-", index, StringComparison.Ordinal)) >= 0)
        {
            index += 4;
            var end = index;
            while (end < message.Length && char.IsAsciiDigit(message[end]))
            {
                end++;
            }

            if (end > index && int.TryParse(message.AsSpan(index, end - index), NumberStyles.None, CultureInfo.InvariantCulture, out var code))
            {
                codes.Add(code);
            }
        }

        return codes;
    }

    /// <summary>
    /// Runs the entry point and reports through the payload: S or F, the error text, the number of outputs, each output's
    /// name and value, then every DBMS_OUTPUT line. A failure is caught so the routine's output survives it; the caller
    /// rolls back.
    /// </summary>
    public static OracleDebugInvocation Invocation(OracleDebugEntryPoint entryPoint, IReadOnlyDictionary<string, OracleDebugArgument> arguments, int maxOutputLines = 10_000)
    {
        var declarations = new List<string>();
        var prologue = new List<string>();
        var callArguments = new List<string>();
        var outputs = new List<(string Name, string Expression)>();
        var binds = new List<string?>();

        string Bind(string value)
        {
            binds.Add(value);
            return string.Create(CultureInfo.InvariantCulture, $":b{binds.Count}");
        }

        for (var index = 0; index < entryPoint.Parameters.Count; index++)
        {
            var parameter = entryPoint.Parameters[index];
            var value = arguments.GetValueOrDefault(parameter.Name) ?? (parameter.HasDefault ? OracleDebugArgument.Default : OracleDebugArgument.Null);
            if (parameter.Mode == OracleDebugParameterMode.Input && value.IsDefault && parameter.HasDefault)
            {
                continue;
            }

            // Every argument is a local of the parameter's own type, NULL included: Oracle picks an overload by the types
            // it is given, and a bare NULL or a text bind matches more than one.
            var declaration = parameter.Declaration ?? throw new OracleDebugArgumentException(parameter.Name, parameter.DisplayType, declarable: false);
            var local = string.Create(CultureInfo.InvariantCulture, $"l_arg{index + 1}");
            declarations.Add($"  {local} {declaration};");
            if (parameter.Mode != OracleDebugParameterMode.Output && value.Text is { } text)
            {
                var expression = parameter.InputExpression(Bind(text)) ?? throw new OracleDebugArgumentException(parameter.Name, parameter.DisplayType, declarable: true);
                prologue.Add($"  {local} := {expression};");
            }

            callArguments.Add($"{OracleDebugUnit.Quote(parameter.Name)} => {local}");
            if (parameter.Mode != OracleDebugParameterMode.Input && parameter.TextExpression(local) is { } output)
            {
                outputs.Add((parameter.Name, output));
            }
        }

        var target = OracleDebugUnit.Quote(entryPoint.Entry.Unit.Owner);
        if (entryPoint.Entry.IsPackaged)
        {
            target += "." + OracleDebugUnit.Quote(entryPoint.Entry.Unit.Name);
        }

        target += "." + OracleDebugUnit.Quote(entryPoint.Entry.Subprogram);
        var call = callArguments.Count == 0 ? target : $"{target}({string.Join(", ", callArguments)})";
        var statement = call + ";";
        if (entryPoint.Result is { } result)
        {
            var declaration = result.Declaration ?? throw new OracleDebugArgumentException(entryPoint.Entry.Subprogram, result.DisplayType, declarable: false);
            declarations.Add($"  l_result {declaration};");
            statement = $"l_result := {call};";
            if (result.TextExpression("l_result") is { } text)
            {
                outputs.Insert(0, (entryPoint.Entry.Subprogram, text));
            }
        }

        var outputLines = string.Join('\n', outputs.Select(o => $"      put({OracleDebugUnit.Literal(o.Name)});\n      put({o.Expression});"));
        var block = string.Create(CultureInfo.InvariantCulture, $"""
            DECLARE
              l_failed BOOLEAN := FALSE;
              l_error VARCHAR2(32767);
              l_line VARCHAR2(32767);
              l_status INTEGER;
              l_lines PLS_INTEGER := 0;
            {string.Join('\n', declarations)}
            {OracleDebugPayload.Declarations}
            BEGIN
            {string.Join('\n', prologue)}
              BEGIN
                {statement}
              EXCEPTION
                WHEN OTHERS THEN
                  l_failed := TRUE;
                  l_error := SQLERRM;
              END;
              IF l_failed THEN
                put('F');
                put(l_error);
                put('0');
              ELSE
                put('S');
                put(NULL);
                put('{outputs.Count}');
            {outputLines}
              END IF;
              LOOP
                EXIT WHEN l_lines >= {maxOutputLines};
                EXECUTE IMMEDIATE 'CALL SYS.DBMS_OUTPUT.GET_LINE(:1, :2)' USING OUT l_line, OUT l_status;
                EXIT WHEN l_status <> 0;
                put(l_line);
                l_lines := l_lines + 1;
              END LOOP;
            {OracleDebugPayload.OpenCursor}
            END;
            """);
        return new OracleDebugInvocation(block, binds);
    }

    /// <summary>
    /// Oracle picks an overload by the named arguments it is given, so leaving out defaulted ones can leave two overloads
    /// that both fit, and the call fails with PLS-00307. ALL_ARGUMENTS cannot give the default's value to pass instead,
    /// so the user has to give one.
    /// </summary>
    public static OracleDebugAmbiguity? Ambiguity(OracleDebugEntryPoint entryPoint, IReadOnlyDictionary<string, OracleDebugArgument> arguments, IReadOnlyList<OracleDebugEntryPoint> overloads)
    {
        OracleDebugArgument ValueOf(OracleDebugParameter parameter) =>
            arguments.GetValueOrDefault(parameter.Name) ?? (parameter.HasDefault ? OracleDebugArgument.Default : OracleDebugArgument.Null);

        var omitted = entryPoint.Parameters.Where(p => p.Mode == OracleDebugParameterMode.Input && p.HasDefault && ValueOf(p).IsDefault).ToArray();
        var passed = entryPoint.Parameters.Where(p => !omitted.Any(o => o.Name == p.Name)).ToArray();
        foreach (var other in overloads)
        {
            if (other.Entry.Unit != entryPoint.Entry.Unit || other.Entry.Subprogram != entryPoint.Entry.Subprogram
                || other.Entry.SubprogramId == entryPoint.Entry.SubprogramId || (other.Result is null) != (entryPoint.Result is null))
            {
                continue;
            }

            var takesEveryPassed = passed.All(p => other.Parameters.Any(o => o.Name == p.Name && o.Declaration == p.Declaration));
            var needsNothingElse = other.Parameters.All(o => passed.Any(p => p.Name == o.Name) || (o.Mode == OracleDebugParameterMode.Input && o.HasDefault));
            if (!takesEveryPassed || !needsNothingElse)
            {
                continue;
            }

            var distinguishing = omitted.Where(p => !other.Parameters.Any(o => o.Name == p.Name && o.Declaration == p.Declaration)).Select(p => p.Name).ToArray();
            return distinguishing.Length == 0
                ? new OracleDebugAmbiguity(OracleDebugAmbiguityKind.Unresolvable, [])
                : new OracleDebugAmbiguity(OracleDebugAmbiguityKind.NeedsValue, distinguishing);
        }

        return null;
    }

    public static OracleDebugInvocationReport InvocationReport(IReadOnlyList<string?> fields)
    {
        var reader = new OracleDebugPayloadReader(fields);
        var status = reader.Next();
        var error = reader.Next();
        var count = reader.Int() ?? 0;
        var outputs = new List<(string, string?)>();
        for (var i = 0; i < Math.Max(count, 0); i++)
        {
            var name = reader.Next() ?? string.Empty;
            outputs.Add((name, reader.Next()));
        }

        var lines = new List<string>();
        while (!reader.IsAtEnd)
        {
            lines.Add(reader.Next() ?? string.Empty);
        }

        return new OracleDebugInvocationReport(status == "S", error, outputs, lines);
    }
}

/// <summary>A parameter's value for the invocation: typed text, NULL, or left to its default.</summary>
internal sealed record OracleDebugArgument(string? Text, bool IsDefault)
{
    public static readonly OracleDebugArgument Null = new(null, false);

    public static readonly OracleDebugArgument Default = new(null, true);

    public static OracleDebugArgument Of(string text) => new(text, false);
}

internal sealed record OracleDebugEntryPoint(OracleDebugEntry Entry, string? Overload, IReadOnlyList<OracleDebugParameter> Parameters, OracleDebugParameter? Result)
{
    public string DisplayName
    {
        get
        {
            var text = new StringBuilder(Entry.Subprogram);
            if (Parameters.Count > 0)
            {
                text.Append('(').AppendJoin(", ", Parameters.Select(p => $"{p.Name} {p.DisplayType}")).Append(')');
            }

            if (Result is not null)
            {
                text.Append(" RETURN ").Append(Result.DisplayType);
            }

            return text.ToString();
        }
    }
}

internal enum OracleDebugParameterMode
{
    Input,
    Output,
    InputOutput,
}

internal sealed record OracleDebugParameter(
    string Name,
    int Position,
    string DataType,
    OracleDebugParameterMode Mode,
    bool HasDefault,
    string? TypeOwner = null,
    string? TypeName = null,
    string? TypeSubname = null,
    string? PlsType = null)
{
    private enum Scalar
    {
        Text,
        NationalText,
        Number,
        Date,
        Timestamp,
        TimestampWithTimeZone,
        TimestampWithLocalTimeZone,
        IntervalYearToMonth,
        IntervalDayToSecond,
        Raw,
        CharacterLob,
        BinaryLob,
        RowId,
        Bfile,
        Boolean,
    }

    public string DisplayType =>
        !string.IsNullOrEmpty(PlsType) ? PlsType : QualifiedTypeName ?? DataType;

    /// <summary>What a local of this parameter's type is declared as, or null when no local can be declared.</summary>
    public string? Declaration
    {
        get
        {
            if (ScalarKind is { } scalar)
            {
                return scalar switch
                {
                    Scalar.Text => "VARCHAR2(32767)",
                    Scalar.NationalText => "NVARCHAR2(16383)",
                    Scalar.Number => NumberDeclaration,
                    Scalar.Date => "DATE",
                    Scalar.Timestamp => "TIMESTAMP(9)",
                    Scalar.TimestampWithTimeZone => "TIMESTAMP(9) WITH TIME ZONE",
                    Scalar.TimestampWithLocalTimeZone => "TIMESTAMP(9) WITH LOCAL TIME ZONE",
                    Scalar.IntervalYearToMonth => "INTERVAL YEAR(9) TO MONTH",
                    Scalar.IntervalDayToSecond => "INTERVAL DAY(9) TO SECOND(9)",
                    Scalar.Raw => "RAW(32767)",
                    Scalar.CharacterLob => DataType.Equals("NCLOB", StringComparison.OrdinalIgnoreCase) ? "NCLOB" : "CLOB",
                    Scalar.BinaryLob => "BLOB",
                    Scalar.RowId => "UROWID",
                    Scalar.Bfile => "BFILE",
                    _ => "BOOLEAN",
                };
            }

            if (DataType.Equals("REF CURSOR", StringComparison.OrdinalIgnoreCase))
            {
                return "SYS_REFCURSOR";
            }

            if (string.IsNullOrEmpty(TypeName))
            {
                return null;
            }

            return string.Join('.', new[] { TypeOwner, TypeName, TypeSubname }.Where(p => !string.IsNullOrEmpty(p)).Select(p => OracleDebugUnit.Quote(p!)));
        }
    }

    private string? QualifiedTypeName =>
        string.IsNullOrEmpty(TypeName) ? null : string.Join('.', new[] { TypeOwner, TypeName, TypeSubname }.Where(p => !string.IsNullOrEmpty(p)));

    private Scalar? ScalarKind => DataType.ToUpperInvariant() switch
    {
        "VARCHAR2" or "VARCHAR" or "CHAR" or "LONG" or "STRING" => Scalar.Text,
        "NVARCHAR2" or "NCHAR" => Scalar.NationalText,
        "NUMBER" or "FLOAT" or "INTEGER" or "BINARY_INTEGER" or "PLS_INTEGER" or "BINARY_FLOAT" or "BINARY_DOUBLE"
            or "PL/SQL PLS INTEGER" or "PL/SQL BINARY INTEGER" or "NATURAL" or "NATURALN" or "POSITIVE" or "POSITIVEN" or "SIMPLE_INTEGER" => Scalar.Number,
        "DATE" => Scalar.Date,
        "TIMESTAMP" => Scalar.Timestamp,
        "TIMESTAMP WITH TIME ZONE" => Scalar.TimestampWithTimeZone,
        "TIMESTAMP WITH LOCAL TIME ZONE" => Scalar.TimestampWithLocalTimeZone,
        "INTERVAL YEAR TO MONTH" => Scalar.IntervalYearToMonth,
        "INTERVAL DAY TO SECOND" => Scalar.IntervalDayToSecond,
        "RAW" or "LONG RAW" => Scalar.Raw,
        "CLOB" or "NCLOB" => Scalar.CharacterLob,
        "BLOB" => Scalar.BinaryLob,
        "ROWID" or "UROWID" => Scalar.RowId,
        "BFILE" => Scalar.Bfile,
        "PL/SQL BOOLEAN" or "BOOLEAN" => Scalar.Boolean,
        _ => null,
    };

    // An integer subtype with NOT NULL or a range cannot be declared bare; PLS_INTEGER holds every one of them.
    private string NumberDeclaration => (PlsType ?? DataType).ToUpperInvariant() switch
    {
        "BINARY_FLOAT" => "BINARY_FLOAT",
        "BINARY_DOUBLE" => "BINARY_DOUBLE",
        "PLS_INTEGER" or "BINARY_INTEGER" or "PL/SQL PLS INTEGER" or "PL/SQL BINARY INTEGER" or "NATURAL" or "NATURALN"
            or "POSITIVE" or "POSITIVEN" or "SIMPLE_INTEGER" or "SIGNTYPE" => "PLS_INTEGER",
        _ => "NUMBER",
    };

    public static OracleDebugParameterMode ModeOf(string? inOut) => inOut?.ToUpperInvariant() switch
    {
        "OUT" => OracleDebugParameterMode.Output,
        "IN/OUT" or "IN OUT" => OracleDebugParameterMode.InputOutput,
        _ => OracleDebugParameterMode.Input,
    };

    /// <summary>The typed text converted explicitly to the parameter's type, in the session's NLS formats; null when text cannot become one.</summary>
    public string? InputExpression(string bind) => ScalarKind switch
    {
        Scalar.Text => bind,
        Scalar.NationalText => $"TO_NCHAR({bind})",
        Scalar.Number => NumberDeclaration switch
        {
            "BINARY_FLOAT" => $"TO_BINARY_FLOAT({bind})",
            "BINARY_DOUBLE" => $"TO_BINARY_DOUBLE({bind})",
            _ => $"TO_NUMBER({bind})",
        },
        Scalar.Date => $"TO_DATE({bind})",
        Scalar.Timestamp or Scalar.TimestampWithLocalTimeZone => $"TO_TIMESTAMP({bind})",
        Scalar.TimestampWithTimeZone => $"TO_TIMESTAMP_TZ({bind})",
        Scalar.IntervalYearToMonth => $"TO_YMINTERVAL({bind})",
        Scalar.IntervalDayToSecond => $"TO_DSINTERVAL({bind})",
        Scalar.Raw => $"HEXTORAW({bind})",
        Scalar.CharacterLob => DataType.Equals("NCLOB", StringComparison.OrdinalIgnoreCase) ? $"TO_NCLOB({bind})" : $"TO_CLOB({bind})",
        Scalar.RowId => $"CHARTOROWID({bind})",
        Scalar.Boolean => $"CASE UPPER(TRIM({bind})) WHEN 'TRUE' THEN TRUE WHEN 'FALSE' THEN FALSE WHEN '1' THEN TRUE WHEN '0' THEN FALSE END",
        _ => null,
    };

    public string? TextExpression(string variable) => ScalarKind switch
    {
        Scalar.Raw => $"RAWTOHEX({variable})",
        Scalar.CharacterLob => string.Create(CultureInfo.InvariantCulture, $"TO_CHAR(SUBSTR({variable}, 1, {OracleDebugPayload.FieldLimit}))"),
        Scalar.RowId => $"ROWIDTOCHAR({variable})",
        Scalar.Boolean => $"CASE WHEN {variable} THEN 'TRUE' WHEN NOT {variable} THEN 'FALSE' END",
        Scalar.BinaryLob or Scalar.Bfile or null => null,
        _ => $"TO_CHAR({variable})",
    };
}
