namespace TablePro.Interop;

// Why a key the row holds cannot be followed with a filter; Subject names the key, table or column it is about.
public enum ReferenceRefusal
{
    UnevenKey,
    UnknownSchema,
    NoFilterText,
    ComparedOtherwise,
}

// Columns are the key's columns in the table that holds it. Exactly one of Filter and Refusal is set.
public sealed record RowReferenceChoice(
    string KeyName,
    TableName Table,
    IReadOnlyList<string> Columns,
    TableFilter? Filter,
    ReferenceRefusal? Refusal,
    string? RefusalSubject);

// Referenced: the rows the row's keys point at. Referencing: other tables' keys that point at the row.
public sealed record RowReferences(
    IReadOnlyList<RowReferenceChoice> Referenced,
    IReadOnlyList<RowReferenceChoice> Referencing)
{
    public static RowReferences None { get; } = new([], []);

    public bool IsEmpty => Referenced.Count == 0 && Referencing.Count == 0;
}
