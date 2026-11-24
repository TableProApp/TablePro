namespace TablePro.Interop;

// Why a key the row holds cannot be followed with a filter; Subject names the key, table or column it is about.
public enum ReferenceRefusal
{
    UnevenKey,
    UnknownSchema,
    NoFilterText,
    ComparedOtherwise,
}

// A key a row leads somewhere by, named for a menu; Key and Referencing are what TableKeys.Follow takes back.
// Columns are the key's columns in the table that holds it.
public sealed record RowReferenceChoice(
    int Key,
    bool Referencing,
    string KeyName,
    TableName Table,
    IReadOnlyList<string> Columns);

// Referenced: the row's keys that hold a column. Referencing: other tables' keys that point at the row.
public sealed record RowReferences(
    IReadOnlyList<RowReferenceChoice> Referenced,
    IReadOnlyList<RowReferenceChoice> Referencing)
{
    public static RowReferences None { get; } = new([], []);

    public bool IsEmpty => Referenced.Count == 0 && Referencing.Count == 0;
}

// The rows a chosen key leads to, or why a filter cannot reach them.
public abstract record FollowedReference
{
    private FollowedReference()
    {
    }

    public sealed record Rows(TableName Table, TableFilter Filter) : FollowedReference;

    public sealed record Refused(ReferenceRefusal Refusal, string Subject) : FollowedReference;
}
