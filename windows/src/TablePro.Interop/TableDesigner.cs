using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// A column as the designer edits it. TypeText and DefaultText are what the user typed; the core resolves them with the
// connection's dialect. OriginalName names the column this one started from, null for a new one.
public sealed record DraftColumn(
    string? OriginalName,
    string Name,
    string TypeText,
    bool Nullable,
    bool PrimaryKey,
    bool AutoIncrement,
    string DefaultText,
    string? Comment,
    string? CharacterSet,
    string? Collation);

public enum ReferentialAction
{
    NoAction,
    Restrict,
    Cascade,
    SetNull,
    SetDefault,
}

public abstract record DraftIndexKey
{
    private DraftIndexKey()
    {
    }

    public sealed record Column(string Name, bool Descending) : DraftIndexKey;

    public sealed record Expression(string Sql, bool Descending) : DraftIndexKey;
}

public sealed record DraftIndex(
    string Name,
    IReadOnlyList<DraftIndexKey> Keys,
    bool Unique,
    bool Primary,
    string? Predicate);

public sealed record DraftForeignKey(
    string Name,
    IReadOnlyList<string> Columns,
    string? RefSchema,
    string RefTable,
    IReadOnlyList<string> RefColumns,
    ReferentialAction? OnDelete,
    ReferentialAction? OnUpdate);

// ConvertsColumns rewrites every text column to the table's character set. NextAutoIncrement is the next numbered value.
public sealed record DraftTableOptions(
    string? CharacterSet,
    string? Collation,
    bool ConvertsColumns,
    long? NextAutoIncrement);

// The whole draft the designer plans. For an existing table the app starts from StartingDraft and edits it.
public sealed record TableDraft(
    string? Schema,
    string Name,
    IReadOnlyList<DraftColumn> Columns,
    IReadOnlyList<DraftIndex> Indexes,
    IReadOnlyList<DraftForeignKey> ForeignKeys,
    DraftTableOptions? Options);

// A part of the save that loses data or drops something it has to make again, named before it runs.
public abstract record DestructiveChange
{
    private DestructiveChange()
    {
    }

    // Recreated names the objects made again; RenumbersRowids says the rebuilt table renumbers unkeyed rows.
    public sealed record RebuildTable(IReadOnlyList<string> Recreated, bool RenumbersRowids) : DestructiveChange;

    public sealed record DropColumn(string Column) : DestructiveChange;

    public sealed record ChangeColumnType(string Column, string From, string To) : DestructiveChange;

    public sealed record SetNotNull(string Column) : DestructiveChange;

    public sealed record ConvertCharacterSet : DestructiveChange;

    public sealed record ChangeColumnCharacterSet(string Column) : DestructiveChange;

    public sealed record DropIndex(string Index) : DestructiveChange;

    public sealed record DropForeignKey(string Key) : DestructiveChange;
}

// Why a draft cannot be saved as it stands, for the app to word.
public abstract record SaveBlocker
{
    private SaveBlocker()
    {
    }

    // Code is the draft problem's stable code.
    public sealed record Draft(string Code) : SaveBlocker;

    public sealed record UnparsedDefault(string Column) : SaveBlocker;
}

// The statements a plan runs, what it loses and whether it can be saved now. Blocked is set when the draft cannot be
// saved; the plan is a preview only then.
public sealed record DesignerPlan(
    IReadOnlyList<string> Statements,
    long Operations,
    IReadOnlyList<DestructiveChange> Destructive,
    string? SavedTableName,
    SaveBlocker? Blocked,
    SaveGate Gate)
{
    // Names this plan to RunAsync, so a plan replaced since is never the one written.
    internal ulong PlanId { get; init; }
}

public abstract record TableSaveOutcome
{
    private TableSaveOutcome()
    {
    }

    public sealed record Done : TableSaveOutcome
    {
        public static Done Instance { get; } = new();
    }

    // Nothing changed.
    public sealed record Failed(CoreError Error) : TableSaveOutcome;

    // The change may have landed in part or in full.
    public sealed record Unknown(CoreError Error) : TableSaveOutcome;
}

// One table's designer: the table as it was read and the plan ready to run. RunAsync writes the plan planned last, once.
public sealed class TableDesigner : IDisposable
{
    private readonly Native.TableDesigner _designer;

    internal TableDesigner(Native.TableDesigner designer) => _designer = designer;

    // The draft the app starts from: the table's columns, indexes, keys and options as the server defines them. Empty
    // for a new table.
    public TableDraft StartingDraft() => Designer.Draft(CoreCall.Run(() => _designer.StartingDraft()));

    // Column types the engine offers, for the type field's completion.
    public IReadOnlyList<string> TypeSuggestions() => CoreCall.Run(() => _designer.TypeSuggestions());

    // The statements the draft would run, planned at the session's Safe Mode level now, with what the save loses.
    public DesignerPlan Plan(TableDraft draft)
    {
        ArgumentNullException.ThrowIfNull(draft);
        return Designer.Plan(CoreCall.Run(() => _designer.Plan(Designer.Draft(draft))));
    }

    // Runs the plan, once, planned again on the connection that writes it. Confirmed says the gate's question was
    // answered; a draft a typed value blocks, another level than the one planned at, or another plan refuses first.
    public async Task<TableSaveOutcome> RunAsync(DesignerPlan plan, bool confirmed, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var id = plan.PlanId;
        var outcome = await CoreCall.RunAsync(token => _designer.Run(id, confirmed, token), cancellationToken)
            .ConfigureAwait(false);
        return outcome switch
        {
            Native.TableSaveOutcome.Done => TableSaveOutcome.Done.Instance,
            Native.TableSaveOutcome.Failed failed => new TableSaveOutcome.Failed(Mapping.Error(failed.Error)),
            Native.TableSaveOutcome.Unknown unknown => new TableSaveOutcome.Unknown(Mapping.Error(unknown.Error)),
            _ => throw new InvalidOperationException("The core reported a save outcome this build does not know."),
        };
    }

    public void Dispose() => _designer.Dispose();
}

public sealed partial class DatabaseSession
{
    // Opens the designer for an existing table, read as the server defines it now; table null opens a new table in
    // schema (the connection's default schema when null).
    public async Task<TableDesigner> OpenTableDesignerAsync(
        TableName? table,
        string? schema = null,
        CancellationToken cancellationToken = default)
    {
        var native = table is null ? null : Mapping.Table(table);
        var designer = await CoreCall.RunAsync(token => Handle.OpenTableDesigner(native, schema, token), cancellationToken)
            .ConfigureAwait(false);
        return new TableDesigner(designer);
    }
}

internal static class Designer
{
    public static Native.TableDraftInput Draft(TableDraft draft) => new(
        draft.Schema,
        draft.Name,
        [.. draft.Columns.Select(Column)],
        [.. draft.Indexes.Select(Index)],
        [.. draft.ForeignKeys.Select(ForeignKey)],
        draft.Options is { } options
            ? new Native.TableOptionsInput(
                options.CharacterSet,
                options.Collation,
                options.ConvertsColumns,
                options.NextAutoIncrement is { } next ? checked((ulong)next) : null)
            : null);

    public static TableDraft Draft(Native.TableDraftInput draft) => new(
        draft.Schema,
        draft.Name,
        [.. draft.Columns.Select(Column)],
        [.. draft.Indexes.Select(Index)],
        [.. draft.ForeignKeys.Select(ForeignKey)],
        draft.Options is { } options
            ? new DraftTableOptions(
                options.CharacterSet,
                options.Collation,
                options.ConvertsColumns,
                options.NextAutoIncrement is { } next ? Mapping.Count(next) : null)
            : null);

    public static DesignerPlan Plan(Native.TableDesignerPlan plan) => new(
        [.. plan.Statements],
        Mapping.Count(plan.Operations),
        [.. plan.Destructive.Select(Destructive)],
        plan.SavedTableName,
        plan.Blocked is { } blocked ? Blocker(blocked) : null,
        Mapping.Gate(plan.Gate))
    {
        PlanId = plan.PlanId,
    };

    private static Native.DraftColumnInput Column(DraftColumn column) => new(
        column.OriginalName,
        column.Name,
        column.TypeText,
        column.Nullable,
        column.PrimaryKey,
        column.AutoIncrement,
        column.DefaultText,
        column.Comment,
        column.CharacterSet,
        column.Collation);

    private static DraftColumn Column(Native.DraftColumnInput column) => new(
        column.OriginalName,
        column.Name,
        column.TypeText,
        column.Nullable,
        column.PrimaryKey,
        column.AutoIncrement,
        column.DefaultText,
        column.Comment,
        column.CharacterSet,
        column.Collation);

    private static Native.IndexInput Index(DraftIndex index) => new(
        index.Name,
        [.. index.Keys.Select(Key)],
        index.Unique,
        index.Primary,
        index.Predicate);

    private static DraftIndex Index(Native.IndexInput index) => new(
        index.Name,
        [.. index.Keys.Select(Key)],
        index.Unique,
        index.Primary,
        index.Predicate);

    private static Native.IndexKeyInput Key(DraftIndexKey key) => key switch
    {
        DraftIndexKey.Column column => new Native.IndexKeyInput.Column(column.Name, column.Descending),
        DraftIndexKey.Expression expression => new Native.IndexKeyInput.Expression(expression.Sql, expression.Descending),
        _ => throw new ArgumentOutOfRangeException(nameof(key), key, "An index key the core does not know."),
    };

    private static DraftIndexKey Key(Native.IndexKeyInput key) => key switch
    {
        Native.IndexKeyInput.Column column => new DraftIndexKey.Column(column.Name, column.Descending),
        Native.IndexKeyInput.Expression expression => new DraftIndexKey.Expression(expression.Sql, expression.Descending),
        _ => throw new InvalidOperationException("The core sent an index key this build does not know."),
    };

    private static Native.ForeignKeyInput ForeignKey(DraftForeignKey key) => new(
        key.Name,
        [.. key.Columns],
        key.RefSchema,
        key.RefTable,
        [.. key.RefColumns],
        key.OnDelete is { } delete ? Action(delete) : null,
        key.OnUpdate is { } update ? Action(update) : null);

    private static DraftForeignKey ForeignKey(Native.ForeignKeyInput key) => new(
        key.Name,
        [.. key.Columns],
        key.RefSchema,
        key.RefTable,
        [.. key.RefColumns],
        key.OnDelete is { } delete ? Action(delete) : null,
        key.OnUpdate is { } update ? Action(update) : null);

    private static Native.ReferentialActionTag Action(ReferentialAction action) => action switch
    {
        ReferentialAction.Restrict => Native.ReferentialActionTag.Restrict,
        ReferentialAction.Cascade => Native.ReferentialActionTag.Cascade,
        ReferentialAction.SetNull => Native.ReferentialActionTag.SetNull,
        ReferentialAction.SetDefault => Native.ReferentialActionTag.SetDefault,
        _ => Native.ReferentialActionTag.NoAction,
    };

    private static ReferentialAction Action(Native.ReferentialActionTag action) => action switch
    {
        Native.ReferentialActionTag.Restrict => ReferentialAction.Restrict,
        Native.ReferentialActionTag.Cascade => ReferentialAction.Cascade,
        Native.ReferentialActionTag.SetNull => ReferentialAction.SetNull,
        Native.ReferentialActionTag.SetDefault => ReferentialAction.SetDefault,
        _ => ReferentialAction.NoAction,
    };

    private static DestructiveChange Destructive(Native.DestructiveChangeTag change) => change switch
    {
        Native.DestructiveChangeTag.RebuildTable rebuild =>
            new DestructiveChange.RebuildTable([.. rebuild.Recreated], rebuild.RenumbersRowids),
        Native.DestructiveChangeTag.DropColumn drop => new DestructiveChange.DropColumn(drop.Column),
        Native.DestructiveChangeTag.ChangeColumnType type =>
            new DestructiveChange.ChangeColumnType(type.Column, type.From, type.To),
        Native.DestructiveChangeTag.SetNotNull notNull => new DestructiveChange.SetNotNull(notNull.Column),
        Native.DestructiveChangeTag.ConvertCharacterSet => new DestructiveChange.ConvertCharacterSet(),
        Native.DestructiveChangeTag.ChangeColumnCharacterSet set =>
            new DestructiveChange.ChangeColumnCharacterSet(set.Column),
        Native.DestructiveChangeTag.DropIndex drop => new DestructiveChange.DropIndex(drop.Index),
        Native.DestructiveChangeTag.DropForeignKey drop => new DestructiveChange.DropForeignKey(drop.Key),
        _ => throw new InvalidOperationException("The core sent a destructive change this build does not know."),
    };

    private static SaveBlocker Blocker(Native.SaveBlockerTag blocker) => blocker switch
    {
        Native.SaveBlockerTag.Draft draft => new SaveBlocker.Draft(draft.Code),
        Native.SaveBlockerTag.UnparsedDefault unparsed => new SaveBlocker.UnparsedDefault(unparsed.Column),
        _ => throw new InvalidOperationException("The core sent a save blocker this build does not know."),
    };
}
