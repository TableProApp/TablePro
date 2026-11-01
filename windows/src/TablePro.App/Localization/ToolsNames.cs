using TablePro.Core.Generation;
using TablePro.Core.JoinBuilder;
using TablePro.Core.Rewind;
using TablePro.Core.Schema;

namespace TablePro.App.Localization;

/// <summary>
/// Display text for the Core enums the join builder, Generate Rows, Copy Objects and Data Rewind show. Core keeps its
/// English names for logs and tests; the app shows these instead.
/// </summary>
internal static class ToolsNames
{
    public static string JoinKindName(JoinKind kind) => kind switch
    {
        JoinKind.Left => Strings.Get("Tools/JoinKindLeft"),
        JoinKind.Right => Strings.Get("Tools/JoinKindRight"),
        JoinKind.Full => Strings.Get("Tools/JoinKindFull"),
        _ => Strings.Get("Tools/JoinKindInner"),
    };

    public static string GeneratorKindName(RowGeneratorKind kind) => kind switch
    {
        RowGeneratorKind.ServerDefault => Strings.Get("Tools/GeneratorServerDefault"),
        RowGeneratorKind.Reference => Strings.Get("Tools/GeneratorReference"),
        RowGeneratorKind.Sequence => Strings.Get("Tools/GeneratorSequence"),
        RowGeneratorKind.IntegerRange => Strings.Get("Tools/GeneratorIntegerRange"),
        RowGeneratorKind.DecimalRange => Strings.Get("Tools/GeneratorDecimalRange"),
        RowGeneratorKind.Text => Strings.Get("Tools/GeneratorText"),
        RowGeneratorKind.FirstName => Strings.Get("Tools/GeneratorFirstName"),
        RowGeneratorKind.LastName => Strings.Get("Tools/GeneratorLastName"),
        RowGeneratorKind.FullName => Strings.Get("Tools/GeneratorFullName"),
        RowGeneratorKind.Email => Strings.Get("Tools/GeneratorEmail"),
        RowGeneratorKind.Phone => Strings.Get("Tools/GeneratorPhone"),
        RowGeneratorKind.StreetAddress => Strings.Get("Tools/GeneratorStreetAddress"),
        RowGeneratorKind.City => Strings.Get("Tools/GeneratorCity"),
        RowGeneratorKind.Country => Strings.Get("Tools/GeneratorCountry"),
        RowGeneratorKind.Date => Strings.Get("Tools/GeneratorDate"),
        RowGeneratorKind.DateTime => Strings.Get("Tools/GeneratorDateTime"),
        RowGeneratorKind.Time => Strings.Get("Tools/GeneratorTime"),
        RowGeneratorKind.Uuid => Strings.Get("Tools/GeneratorUuid"),
        RowGeneratorKind.Boolean => Strings.Get("Tools/GeneratorBoolean"),
        RowGeneratorKind.List => Strings.Get("Tools/GeneratorList"),
        RowGeneratorKind.Pattern => Strings.Get("Tools/GeneratorPattern"),
        RowGeneratorKind.Json => Strings.Get("Tools/GeneratorJson"),
        _ => kind.Title(),
    };

    /// <summary>The lowercase kind word Copy Objects puts after each object's name.</summary>
    public static string CopyObjectKindName(ObjectKind kind) => kind switch
    {
        ObjectKind.Table => Strings.Get("Tools/CopyKindTable"),
        ObjectKind.View => Strings.Get("Tools/CopyKindView"),
        ObjectKind.MaterializedView => Strings.Get("Tools/CopyKindMaterializedView"),
        ObjectKind.Function => Strings.Get("Tools/CopyKindFunction"),
        ObjectKind.Procedure => Strings.Get("Tools/CopyKindProcedure"),
        ObjectKind.Sequence => Strings.Get("Tools/CopyKindSequence"),
        _ => kind.ToString().ToLowerInvariant(),
    };

    public static string RewindRefusalText(RewindRefusal refusal) => refusal switch
    {
        RewindRefusal.NoPrimaryKey => Strings.Get("Rewind/RefusalNoPrimaryKey"),
        RewindRefusal.ServerAssignedKey => Strings.Get("Rewind/RefusalServerAssignedKey"),
        RewindRefusal.ValueTooLarge => Strings.Get("Rewind/RefusalValueTooLarge"),
        _ => RewindOperation.Explain(refusal),
    };
}
