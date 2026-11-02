using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The generated types stay internal, so the app's API is this library's and an upgrade of the generator
// cannot change it. Counts cross as unsigned and fit a long.
internal static class Mapping
{
    public static CoreError Error(Native.ErrorInfo info) => new(
        info.Code,
        info.Codes,
        info.Message,
        info.Server is { } server
            ? new ServerMessage(
                server.Message,
                server.Code,
                server.Sqlstate,
                server.Detail,
                server.Hint,
                server.Position is { } position ? checked((int)position) : null)
            : null,
        info.Path);

    public static DatabaseEngine Engine(Native.DriverInfo driver) => new(
        driver.Id,
        driver.DisplayName,
        driver.DataModel switch
        {
            Native.DataModelTag.KeyValue => DataModel.KeyValue,
            Native.DataModelTag.Document => DataModel.Document,
            _ => DataModel.Relational,
        },
        driver.Endpoint is Native.EndpointInfo.Network network ? network.DefaultPort : null,
        driver.Endpoint is Native.EndpointInfo.File file ? file.Suffixes : []);

    public static SchemaEntry Schema(Native.SchemaEntry schema) =>
        new(schema.Name, schema.IsDefault, schema.IsSystem);

    public static ObjectEntry Object(Native.ObjectEntry entry) =>
        new(entry.Schema, entry.Name, ObjectKind(entry.Kind), entry.ParentTable);

    public static Native.ObjectScopeArg Scope(ObjectScope scope) => scope switch
    {
        ObjectScope.NamedSchema named => new Native.ObjectScopeArg.Schema(named.Name),
        ObjectScope.AllSchemasScope => new Native.ObjectScopeArg.AllSchemas(),
        _ => new Native.ObjectScopeArg.DefaultSchema(),
    };

    public static Native.TableName Table(TableName table) => new(table.Schema, table.Name);

    public static ColumnEntry Column(Native.ColumnEntry column) => new(
        column.Name,
        column.TypeName,
        Kind(column.ValueKind),
        column.Nullable,
        column.PrimaryKey,
        column.AutoIncrement,
        column.Generated,
        column.Comment);

    public static ResultColumn ResultColumn(Native.ResultColumnInfo column) =>
        new(column.Name, column.TypeName, Kind(column.ValueKind));

    public static Native.RunSettings Settings(QueryOptions options) => new(
        options.RowLimit is { } limit ? checked((ulong)limit) : null,
        options.Timeout is { } timeout ? checked((ulong)timeout.TotalMilliseconds) : null);

    public static QueryEvent Event(Native.RunEvent nativeEvent) => nativeEvent switch
    {
        Native.RunEvent.ResultSetStarted started =>
            new QueryEvent.ResultSetStarted(Index(started.SetIndex), Columns(started.Columns)),
        Native.RunEvent.ColumnsResolved resolved =>
            new QueryEvent.ColumnsResolved(Index(resolved.SetIndex), Columns(resolved.Columns)),
        Native.RunEvent.RowsAppended rows => new QueryEvent.RowsAppended(Index(rows.SetIndex), Count(rows.RowCount)),
        Native.RunEvent.RowLimitReached limit =>
            new QueryEvent.RowLimitReached(Index(limit.SetIndex), Count(limit.Retained)),
        Native.RunEvent.ResultSetFinished finished => new QueryEvent.ResultSetFinished(
            Index(finished.SetIndex),
            Count(finished.RowCount),
            finished.TotalRows is { } total ? Count(total) : null,
            finished.Truncation switch
            {
                Native.TruncationTag.ServerStopped => Truncation.ServerStopped,
                Native.TruncationTag.ReadPastLimit => Truncation.ReadPastLimit,
                _ => Truncation.Complete,
            }),
        Native.RunEvent.CommandCompleted command =>
            new QueryEvent.CommandCompleted(command.RowsAffected is { } affected ? Count(affected) : null),
        Native.RunEvent.Notice notice => new QueryEvent.Notice(notice.Severity, notice.Message, notice.Code),
        Native.RunEvent.Finished finished => new QueryEvent.Finished(Outcome(finished.Outcome)),
        _ => throw new InvalidOperationException($"The core sent an event this build does not know: {nativeEvent}"),
    };

    public static QueryOutcome Outcome(Native.RunOutcome outcome) => outcome switch
    {
        Native.RunOutcome.Completed completed =>
            new QueryOutcome.Completed(TimeSpan.FromMilliseconds(completed.ElapsedMs)),
        Native.RunOutcome.Failed failed => new QueryOutcome.Failed(Error(failed.Info)),
        Native.RunOutcome.TimedOut timedOut => new QueryOutcome.TimedOut(timedOut.ServerCancelled),
        _ => new QueryOutcome.Cancelled(),
    };

    public static SecretKind Kind(Native.SecretKindTag kind) => kind switch
    {
        Native.SecretKindTag.SshPassword => SecretKind.SshPassword,
        Native.SecretKindTag.SshPassphrase => SecretKind.SshPassphrase,
        _ => SecretKind.DatabasePassword,
    };

    public static SecretItem Item(Native.SecretItemTag item) => item switch
    {
        Native.SecretItemTag.AnthropicKey => SecretItem.AnthropicKey,
        Native.SecretItemTag.OpenAiKey => SecretItem.OpenAIKey,
        Native.SecretItemTag.OpenAiCompatibleKey => SecretItem.OpenAICompatibleKey,
        _ => SecretItem.McpToken,
    };

    // The generated enum carries the core's own byte values.
    public static ValueKind Kind(Native.ValueKind kind) => (ValueKind)(byte)kind;

    public static long Count(ulong count) => checked((long)count);

    private static int Index(uint index) => checked((int)index);

    private static List<ResultColumn> Columns(Native.ResultColumnInfo[] columns) =>
        [.. columns.Select(ResultColumn)];

    private static ObjectKind ObjectKind(Native.ObjectKindTag kind) => kind switch
    {
        Native.ObjectKindTag.Table => Interop.ObjectKind.Table,
        Native.ObjectKindTag.PartitionedTable => Interop.ObjectKind.PartitionedTable,
        Native.ObjectKindTag.View => Interop.ObjectKind.View,
        Native.ObjectKindTag.MaterializedView => Interop.ObjectKind.MaterializedView,
        Native.ObjectKindTag.ForeignTable => Interop.ObjectKind.ForeignTable,
        Native.ObjectKindTag.Sequence => Interop.ObjectKind.Sequence,
        Native.ObjectKindTag.Function => Interop.ObjectKind.Function,
        Native.ObjectKindTag.Procedure => Interop.ObjectKind.Procedure,
        Native.ObjectKindTag.Trigger => Interop.ObjectKind.Trigger,
        Native.ObjectKindTag.Dictionary => Interop.ObjectKind.Dictionary,
        Native.ObjectKindTag.Key => Interop.ObjectKind.Key,
        _ => Interop.ObjectKind.Other,
    };
}
