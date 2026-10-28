using System.Globalization;

namespace TablePro.Drivers.Oracle;

internal enum OracleDebugUnitKind
{
    Procedure,
    Function,
    Package,
    PackageBody,
    Trigger,
    Type,
    TypeBody,
}

internal static class OracleDebugUnitKinds
{
    public static string TypeName(this OracleDebugUnitKind kind) => kind switch
    {
        OracleDebugUnitKind.Procedure => "PROCEDURE",
        OracleDebugUnitKind.Function => "FUNCTION",
        OracleDebugUnitKind.Package => "PACKAGE",
        OracleDebugUnitKind.PackageBody => "PACKAGE BODY",
        OracleDebugUnitKind.Trigger => "TRIGGER",
        OracleDebugUnitKind.Type => "TYPE",
        _ => "TYPE BODY",
    };

    public static OracleDebugUnitKind? FromTypeName(string? name) => name switch
    {
        "PROCEDURE" => OracleDebugUnitKind.Procedure,
        "FUNCTION" => OracleDebugUnitKind.Function,
        "PACKAGE" => OracleDebugUnitKind.Package,
        "PACKAGE BODY" => OracleDebugUnitKind.PackageBody,
        "TRIGGER" => OracleDebugUnitKind.Trigger,
        "TYPE" => OracleDebugUnitKind.Type,
        "TYPE BODY" => OracleDebugUnitKind.TypeBody,
        _ => null,
    };

    /// <summary>DBMS_DEBUG's namespaces: 1 holds specifications and top-level units, 2 bodies, 3 triggers.</summary>
    public static int Namespace(this OracleDebugUnitKind kind) => kind switch
    {
        OracleDebugUnitKind.PackageBody or OracleDebugUnitKind.TypeBody => 2,
        OracleDebugUnitKind.Trigger => 3,
        _ => 1,
    };

    /// <summary>A backtrace frame's kind from DBMS_DEBUG's namespace and LibunitType (the KGLT constants).</summary>
    public static OracleDebugUnitKind? FromNamespace(int @namespace, int libunitType) => (@namespace, libunitType) switch
    {
        (1, 7) => OracleDebugUnitKind.Procedure,
        (1, 8) => OracleDebugUnitKind.Function,
        (1, 9) => OracleDebugUnitKind.Package,
        (1, 13) => OracleDebugUnitKind.Type,
        (2, 11) => OracleDebugUnitKind.PackageBody,
        (2, 14) => OracleDebugUnitKind.TypeBody,
        (3, _) => OracleDebugUnitKind.Trigger,
        _ => null,
    };

    public static bool HasSubprograms(this OracleDebugUnitKind kind) =>
        kind is OracleDebugUnitKind.Package or OracleDebugUnitKind.PackageBody or OracleDebugUnitKind.Type or OracleDebugUnitKind.TypeBody;

    public static string DisplayName(this OracleDebugUnitKind kind) => kind switch
    {
        OracleDebugUnitKind.Procedure => "Procedure",
        OracleDebugUnitKind.Function => "Function",
        OracleDebugUnitKind.Package or OracleDebugUnitKind.PackageBody => "Package",
        OracleDebugUnitKind.Trigger => "Trigger",
        _ => "Type",
    };

    /// <summary>
    /// Compiles the unit again with debug information, keeping its other settings. A package compiles only its body, so
    /// nothing that depends on the specification is invalidated.
    /// </summary>
    public static string CompileForDebugStatement(this OracleDebugUnitKind kind, string owner, string name)
    {
        var qualified = $"{OracleDebugUnit.Quote(owner)}.{OracleDebugUnit.Quote(name)}";
        const string Tail = "COMPILE PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS";
        return kind switch
        {
            OracleDebugUnitKind.Procedure => $"ALTER PROCEDURE {qualified} {Tail}",
            OracleDebugUnitKind.Function => $"ALTER FUNCTION {qualified} {Tail}",
            OracleDebugUnitKind.Package or OracleDebugUnitKind.PackageBody => $"ALTER PACKAGE {qualified} COMPILE BODY PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS",
            OracleDebugUnitKind.Trigger => $"ALTER TRIGGER {qualified} {Tail}",
            _ => $"ALTER TYPE {qualified} COMPILE BODY PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS",
        };
    }
}

/// <summary>A unit of PL/SQL source: a standalone routine, a package or type specification or body, or a trigger.</summary>
internal sealed record OracleDebugUnit(string Owner, string Name, OracleDebugUnitKind Kind)
{
    /// <summary><c>TYPE/OWNER/NAME</c>, each part with <c>%</c> and <c>/</c> escaped, since a quoted Oracle name may hold either.</summary>
    public string Identity => string.Join('/', Kind.TypeName(), Escape(Owner), Escape(Name));

    /// <summary>The body holds the code a package or type runs.</summary>
    public OracleDebugUnit CodeUnit => Kind switch
    {
        OracleDebugUnitKind.Package => this with { Kind = OracleDebugUnitKind.PackageBody },
        OracleDebugUnitKind.Type => this with { Kind = OracleDebugUnitKind.TypeBody },
        _ => this,
    };

    public string DisplayName => Kind is OracleDebugUnitKind.Package or OracleDebugUnitKind.Type ? $"{Owner}.{Name} (specification)" : $"{Owner}.{Name}";

    public static OracleDebugUnit? FromIdentity(string identity)
    {
        var parts = Split(identity);
        return parts.Length == 3 && OracleDebugUnitKinds.FromTypeName(parts[0]) is { } kind ? new OracleDebugUnit(parts[1], parts[2], kind) : null;
    }

    public static string Quote(string identifier) => "\"" + identifier.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";

    public static string Literal(string text) => "'" + text.Replace("'", "''", StringComparison.Ordinal) + "'";

    internal static string Escape(string part) =>
        part.Replace("%", "%25", StringComparison.Ordinal).Replace("/", "%2F", StringComparison.Ordinal);

    internal static string Unescape(string part) =>
        part.Replace("%2F", "/", StringComparison.Ordinal).Replace("%25", "%", StringComparison.Ordinal);

    internal static string[] Split(string identity) => [.. identity.Split('/').Select(Unescape)];
}

/// <summary>One public subprogram overload of a unit, or the standalone routine itself.</summary>
internal sealed record OracleDebugEntry(OracleDebugUnit Unit, string Subprogram, int SubprogramId)
{
    public string Identity => string.Create(CultureInfo.InvariantCulture, $"{Unit.Identity}/{OracleDebugUnit.Escape(Subprogram)}/{SubprogramId}");

    public bool IsPackaged => Unit.Kind.HasSubprograms();

    public static OracleDebugEntry? FromIdentity(string identity)
    {
        var parts = OracleDebugUnit.Split(identity);
        return parts.Length == 5
            && OracleDebugUnitKinds.FromTypeName(parts[0]) is { } kind
            && int.TryParse(parts[4], NumberStyles.Integer, CultureInfo.InvariantCulture, out var id)
                ? new OracleDebugEntry(new OracleDebugUnit(parts[1], parts[2], kind), parts[3], id)
                : null;
    }
}
