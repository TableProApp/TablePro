using TablePro.Core.Browse;
using TablePro.Core.Import;

namespace TablePro.App.Localization;

/// <summary>Translated names for the Core values the table tab shows, which Core cannot translate itself.</summary>
internal static class TableNames
{
    /// <summary>The operator as the filter strip lists it. Comparison symbols read the same in every language.</summary>
    public static string Operator(FilterOperator op) => op switch
    {
        FilterOperator.Equals => "=",
        FilterOperator.NotEquals => "≠",
        FilterOperator.GreaterThan => ">",
        FilterOperator.GreaterOrEqual => "≥",
        FilterOperator.LessThan => "<",
        FilterOperator.LessOrEqual => "≤",
        FilterOperator.Contains => Strings.Get("Table/OperatorContains"),
        FilterOperator.NotContains => Strings.Get("Table/OperatorNotContains"),
        FilterOperator.StartsWith => Strings.Get("Table/OperatorStartsWith"),
        FilterOperator.EndsWith => Strings.Get("Table/OperatorEndsWith"),
        FilterOperator.IsNull => Strings.Get("Table/OperatorIsNull"),
        FilterOperator.IsNotNull => Strings.Get("Table/OperatorIsNotNull"),
        FilterOperator.IsEmpty => Strings.Get("Table/OperatorIsEmpty"),
        FilterOperator.IsNotEmpty => Strings.Get("Table/OperatorIsNotEmpty"),
        FilterOperator.In => Strings.Get("Table/OperatorIn"),
        FilterOperator.NotIn => Strings.Get("Table/OperatorNotIn"),
        FilterOperator.Between => Strings.Get("Table/OperatorBetween"),
        _ => op.ToString(),
    };

    /// <summary>The kind of values an import field holds, as the import preview's column headers describe it.</summary>
    public static string FieldType(ImportFieldType type) => type switch
    {
        ImportFieldType.Text => Strings.Get("Import/FieldTypeText"),
        ImportFieldType.Integer => Strings.Get("Import/FieldTypeInteger"),
        ImportFieldType.Real => Strings.Get("Import/FieldTypeReal"),
        ImportFieldType.Boolean => Strings.Get("Import/FieldTypeBoolean"),
        ImportFieldType.Json => Strings.Get("Import/FieldTypeJson"),
        _ => type.ToString(),
    };
}
