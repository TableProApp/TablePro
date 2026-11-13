namespace TablePro.Interop;

// Why no row of a table, or of a page, can be changed.
public enum EditLock
{
    ReadOnlyConnection,
    NoPrimaryKey,
    KeyUnreadable,
    ColumnsChanged,
}

// An empty text means what the core's parse says for the column: the empty string, the server's default, or NULL.
public abstract record CellEdit
{
    private CellEdit()
    {
    }

    public sealed record Text(string Value) : CellEdit;

    public sealed record Null : CellEdit
    {
        public static Null Instance { get; } = new();
    }

    // The server's value: an insert leaves the column out, an update sets it to DEFAULT.
    public sealed record ServerDefault : CellEdit
    {
        public static ServerDefault Instance { get; } = new();
    }
}

public sealed record CellChange(int Column, CellEdit Edit);

// A row of the page, by its place in the result set the page was read into.
public abstract record RowEdit
{
    private RowEdit()
    {
    }

    public sealed record Update(long Row, IReadOnlyList<CellChange> Cells) : RowEdit;

    // One cell per column, in the table's order.
    public sealed record Insert(IReadOnlyList<CellEdit> Cells) : RowEdit;

    public sealed record Delete(long Row) : RowEdit;
}

// A saved row's key and a column the server fills are locked; TakesDefault offers DEFAULT in a saved row.
public sealed record EditColumn(
    string Name,
    bool Editable,
    bool EditableInNewRow,
    CellEdit NewRow,
    bool Nullable,
    bool PrimaryKey,
    bool TakesEmpty,
    bool TakesDefault);

public abstract record EditStart
{
    private EditStart()
    {
    }

    // The whole value, which the grid shows cut; empty for NULL.
    public sealed record Editable(string Text, bool IsNull) : EditStart;

    public sealed record Locked : EditStart
    {
        public static Locked Instance { get; } = new();
    }
}

// One statement of a save, with the values it binds as they would be written.
public sealed record PlannedStatement(string Sql, IReadOnlyList<string> Values);

// Row changes are writes: Off saves, Confirm writes shows the statements first, Read only refuses.
public enum SaveGate
{
    Run,
    Confirm,
    Refuse,
}

public abstract record RowSaveOutcome
{
    private RowSaveOutcome()
    {
    }

    public sealed record Saved(long? Rows) : RowSaveOutcome;

    // Nothing was written. Edit is the place in the edits of the change the save stopped at, when the engine said.
    public sealed record RolledBack(CoreError Error, int? Edit) : RowSaveOutcome;

    // The save may have landed in part or in full, so saving again could write it twice.
    public sealed record Unknown(CoreError Error, int? Edit) : RowSaveOutcome;
}
