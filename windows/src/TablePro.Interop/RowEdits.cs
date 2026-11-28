namespace TablePro.Interop;

// Why no row of a table, a page or a query result can be changed.
public enum EditLock
{
    ReadOnlyConnection,
    NoPrimaryKey,
    KeyUnreadable,
    ColumnsChanged,
    // A query result's statement is not one SELECT.
    NotOneSelect,
    // A join, a subquery or a CTE.
    MoreThanOneTable,
    // DISTINCT, GROUP BY or a function in the select list.
    Collapsed,
    // No column traced to the statement's table: a view, a temporary table, or an engine that says nothing.
    Untraced,
    // The result leaves out part of the table's primary key.
    KeyNotShown,
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

// A saved row's key and a server-filled column lock; Labels: an enum's or a SET's; NeedsOffset: typed times need one.
public sealed record EditColumn(
    string Name,
    bool Editable,
    bool EditableInNewRow,
    CellEdit NewRow,
    bool Nullable,
    bool PrimaryKey,
    bool TakesEmpty,
    bool TakesDefault,
    ValueKind Kind = ValueKind.Other,
    IReadOnlyList<string>? Labels = null,
    bool Multiple = false,
    bool NeedsOffset = false)
{
    public IReadOnlyList<string> Labels { get; init; } = Labels ?? [];
}

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

// What tints a pending cell, with its text for a value.
public enum PendingKind
{
    Value,
    Null,
    Default,
}

public sealed record PendingCell(PendingKind Kind, string Text);

// One pending cell of a data row, by its place in the result set shown.
public sealed record OverlayCell(long Row, int Column, PendingCell Cell);

// The pending edits laid over one result set, by place, so the grid draws them with no key of its own.
public sealed record PendingOverlay(
    IReadOnlyList<OverlayCell> Cells,
    IReadOnlyList<long> ModifiedRows,
    IReadOnlyList<long> DeletedRows,
    // New rows after the data rows, oldest first, one cell per table column.
    IReadOnlyList<IReadOnlyList<PendingCell>> Drafts);

// Where the tracker stands after an edit, so the app updates its buttons without a second call.
public sealed record EditSummary(
    long PendingCount,
    long AddedRows,
    bool HasChanges,
    bool CanUndo,
    bool CanRedo,
    // A save may have landed; saving again is refused until the tab is reloaded or the changes discarded.
    bool OutcomeUnknown,
    bool Saving);

// The plan a save would run now, for the confirm sheet and the delete question.
public sealed record SavePreview(IReadOnlyList<PlannedStatement> Statements, SaveGate Gate, long Deletes, bool IsEmpty);

public abstract record RowSaveOutcome
{
    private RowSaveOutcome()
    {
    }

    public sealed record Saved(long? Rows) : RowSaveOutcome;

    // Nothing was written. Row is the place of the row the save stopped at, when the engine said.
    public sealed record RolledBack(CoreError Error, long? Row) : RowSaveOutcome;

    // The save may have landed in part or in full, so saving again could write it twice.
    public sealed record Unknown(CoreError Error, long? Row) : RowSaveOutcome;
}
