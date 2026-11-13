using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// Generated types stay internal so a generator upgrade cannot change the API. Counts cross unsigned and fit a long.
internal static partial class Mapping
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
        info.Path,
        info.Secret is { } secret ? Kind(secret) : null,
        info.HostKey is { } key
            ? new HostKeyFailure(key.Host, key.Algorithm, key.Fingerprint, key.KnownHosts, key.Line, key.TrustAllowed)
            : null)
    {
        TlsFailure = info.TlsFailure is { } failure ? TlsFailureKind(failure) : null,
    };

    private static TlsFailure TlsFailureKind(Native.TlsFailureTag failure) => failure switch
    {
        Native.TlsFailureTag.UnknownIssuer => TlsFailure.UnknownIssuer,
        Native.TlsFailureTag.NameMismatch => TlsFailure.NameMismatch,
        Native.TlsFailureTag.Expired => TlsFailure.Expired,
        Native.TlsFailureTag.NotYetValid => TlsFailure.NotYetValid,
        Native.TlsFailureTag.Revoked => TlsFailure.Revoked,
        Native.TlsFailureTag.ServerRefusedTls => TlsFailure.ServerRefusedTls,
        Native.TlsFailureTag.ServerRequiresTls => TlsFailure.ServerRequiresTls,
        Native.TlsFailureTag.ServerRefusedStrict => TlsFailure.ServerRefusedStrict,
        Native.TlsFailureTag.ServerRequiresStrict => TlsFailure.ServerRequiresStrict,
        Native.TlsFailureTag.HandshakeRejected => TlsFailure.HandshakeRejected,
        Native.TlsFailureTag.CaFileInvalid => TlsFailure.CaFileInvalid,
        Native.TlsFailureTag.ClientIdentityInvalid => TlsFailure.ClientIdentityInvalid,
        _ => TlsFailure.Other,
    };

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
        driver.Endpoint is Native.EndpointInfo.File file ? file.Suffixes : [],
        driver.Category switch
        {
            Native.EngineCategoryTag.Document => EngineCategory.Document,
            Native.EngineCategoryTag.KeyValue => EngineCategory.KeyValue,
            Native.EngineCategoryTag.Analytical => EngineCategory.Analytical,
            Native.EngineCategoryTag.WideColumn => EngineCategory.WideColumn,
            _ => EngineCategory.Relational,
        })
    {
        SupportedTlsModes = driver.SupportedTlsModes.Select(Tls).ToArray(),
        DefaultTlsMode = Tls(driver.DefaultTlsMode),
        TlsPorts = driver.TlsPorts.Select(port => (int)port).ToArray(),
        ServerNameOverride = driver.ServerNameOverride switch
        {
            Native.ServerNameOverrideTag.AnyRoute => ServerNameOverride.AnyRoute,
            Native.ServerNameOverrideTag.SshForwardOnly => ServerNameOverride.SshForwardOnly,
            _ => ServerNameOverride.Unsupported,
        },
        SupportsIntegratedAuth = driver.SupportsIntegratedAuth,
        SupportsClientIdentity = driver.SupportsClientIdentity,
    };

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

    public static Native.ColumnSort? Sort(ColumnSort? sort) =>
        sort is null ? null : new Native.ColumnSort(checked((uint)sort.Column), sort.Ascending);

    public static Native.TableFilterArg Filter(TableFilter filter) => new(
        filter.Combinator switch
        {
            FilterCombinator.Or => Native.CombinatorTag.Or,
            _ => Native.CombinatorTag.And,
        },
        [.. filter.Rules.Select(rule =>
            new Native.FilterRuleArg(rule.Column, Operator(rule.Operator), Value(rule.Value)))],
        filter.RawSql);

    private static Native.FilterValueArg? Value(FilterValue? value) => value switch
    {
        FilterValue.One single => new Native.FilterValueArg.Single(single.Value),
        FilterValue.Pair pair => new Native.FilterValueArg.Pair(pair.Low, pair.High),
        FilterValue.List list => new Native.FilterValueArg.List([.. list.Values]),
        _ => null,
    };

    private static Native.FilterOpTag Operator(FilterOperator op) => op switch
    {
        FilterOperator.Equal => Native.FilterOpTag.Eq,
        FilterOperator.NotEqual => Native.FilterOpTag.NotEq,
        FilterOperator.Less => Native.FilterOpTag.Lt,
        FilterOperator.LessOrEqual => Native.FilterOpTag.LtEq,
        FilterOperator.Greater => Native.FilterOpTag.Gt,
        FilterOperator.GreaterOrEqual => Native.FilterOpTag.GtEq,
        FilterOperator.Contains => Native.FilterOpTag.Contains,
        FilterOperator.StartsWith => Native.FilterOpTag.StartsWith,
        FilterOperator.EndsWith => Native.FilterOpTag.EndsWith,
        FilterOperator.Like => Native.FilterOpTag.Like,
        FilterOperator.NotLike => Native.FilterOpTag.NotLike,
        FilterOperator.ILike => Native.FilterOpTag.Ilike,
        FilterOperator.IsNull => Native.FilterOpTag.IsNull,
        FilterOperator.IsNotNull => Native.FilterOpTag.IsNotNull,
        FilterOperator.In => Native.FilterOpTag.In,
        FilterOperator.NotIn => Native.FilterOpTag.NotIn,
        FilterOperator.Between => Native.FilterOpTag.Between,
        _ => throw new ArgumentOutOfRangeException(nameof(op), op, "A filter operator the core does not know."),
    };

    private static FilterOperator Operator(Native.FilterOpTag op) => op switch
    {
        Native.FilterOpTag.Eq => FilterOperator.Equal,
        Native.FilterOpTag.NotEq => FilterOperator.NotEqual,
        Native.FilterOpTag.Lt => FilterOperator.Less,
        Native.FilterOpTag.LtEq => FilterOperator.LessOrEqual,
        Native.FilterOpTag.Gt => FilterOperator.Greater,
        Native.FilterOpTag.GtEq => FilterOperator.GreaterOrEqual,
        Native.FilterOpTag.Contains => FilterOperator.Contains,
        Native.FilterOpTag.StartsWith => FilterOperator.StartsWith,
        Native.FilterOpTag.EndsWith => FilterOperator.EndsWith,
        Native.FilterOpTag.Like => FilterOperator.Like,
        Native.FilterOpTag.NotLike => FilterOperator.NotLike,
        Native.FilterOpTag.Ilike => FilterOperator.ILike,
        Native.FilterOpTag.IsNull => FilterOperator.IsNull,
        Native.FilterOpTag.IsNotNull => FilterOperator.IsNotNull,
        Native.FilterOpTag.In => FilterOperator.In,
        Native.FilterOpTag.NotIn => FilterOperator.NotIn,
        Native.FilterOpTag.Between => FilterOperator.Between,
        _ => throw new InvalidOperationException($"The core sent a filter operator this build does not know: {op}"),
    };

    public static FilterChoices Choices(Native.FilterChoices choices) => new(
        [.. choices.Columns.Select(column =>
            new FilterColumn(column.Name, [.. column.Operators.Select(op => Operator(op))]))],
        [.. choices.Combinators.Select(combinator => combinator switch
        {
            Native.CombinatorTag.Or => FilterCombinator.Or,
            _ => FilterCombinator.And,
        })],
        choices.AcceptsRawSql);

    public static TableStructure Structure(Native.TableStructure structure) => new(
        [.. structure.Columns.Select(column => new StructureColumn(
            column.Name,
            column.TypeName,
            column.Nullable,
            column.DefaultValue,
            column.PrimaryKey,
            column.AutoIncrement,
            column.Generated,
            column.Comment))],
        [.. structure.Indexes.Select(index =>
            new StructureIndex(index.Name, index.Keys, index.Unique, index.Primary, index.Predicate))],
        [.. structure.ForeignKeys.Select(key => new StructureForeignKey(
            key.Name,
            key.Columns,
            key.RefSchema,
            key.RefTable,
            key.RefColumns,
            key.OnDelete,
            key.OnUpdate))],
        structure.Ddl);

    // Null where the engine keeps no statistics for the table, as SQLite before ANALYZE.
    public static RowEstimate? Estimate(Native.RowEstimate estimate) => estimate switch
    {
        Native.RowEstimate.Exact exact => new RowEstimate(Count(exact.Rows), IsExact: true),
        Native.RowEstimate.Approximate approximate => new RowEstimate(Count(approximate.Rows), IsExact: false),
        _ => null,
    };

    public static ObjectSource Source(Native.ObjectSource source) =>
        new(source.Sql, source.Database, source.OpensInEditor);

    public static Native.ObjectEntry Entry(ObjectEntry entry) =>
        new(entry.Schema, entry.Name, Tag(entry.Kind), entry.ParentTable);

    public static Native.ObjectKindTag Tag(ObjectKind kind) => kind switch
    {
        Interop.ObjectKind.Table => Native.ObjectKindTag.Table,
        Interop.ObjectKind.PartitionedTable => Native.ObjectKindTag.PartitionedTable,
        Interop.ObjectKind.View => Native.ObjectKindTag.View,
        Interop.ObjectKind.MaterializedView => Native.ObjectKindTag.MaterializedView,
        Interop.ObjectKind.ForeignTable => Native.ObjectKindTag.ForeignTable,
        Interop.ObjectKind.Sequence => Native.ObjectKindTag.Sequence,
        Interop.ObjectKind.Function => Native.ObjectKindTag.Function,
        Interop.ObjectKind.Procedure => Native.ObjectKindTag.Procedure,
        Interop.ObjectKind.Trigger => Native.ObjectKindTag.Trigger,
        Interop.ObjectKind.Dictionary => Native.ObjectKindTag.Dictionary,
        Interop.ObjectKind.Key => Native.ObjectKindTag.Key,
        _ => Native.ObjectKindTag.Other,
    };

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
        options.Timeout is { } timeout ? checked((ulong)timeout.TotalMilliseconds) : null,
        options.ByteLimit is { } bytes ? checked((ulong)bytes) : null);

    public static QueryEvent Event(Native.RunEvent nativeEvent) => nativeEvent switch
    {
        Native.RunEvent.ResultSetStarted started =>
            new QueryEvent.ResultSetStarted(Index(started.SetIndex), Columns(started.Columns)),
        Native.RunEvent.ColumnsResolved resolved =>
            new QueryEvent.ColumnsResolved(Index(resolved.SetIndex), Columns(resolved.Columns)),
        Native.RunEvent.RowsAppended rows => new QueryEvent.RowsAppended(Index(rows.SetIndex), Count(rows.RowCount)),
        Native.RunEvent.RowLimitReached limit =>
            new QueryEvent.RowLimitReached(Index(limit.SetIndex), Count(limit.Retained)),
        Native.RunEvent.ByteLimitReached bytes => new QueryEvent.ByteLimitReached(
            Index(bytes.SetIndex),
            Count(bytes.Retained),
            Count(bytes.LimitBytes)),
        Native.RunEvent.ResultSetFinished finished => new QueryEvent.ResultSetFinished(
            Index(finished.SetIndex),
            Count(finished.RowCount),
            finished.TotalRows is { } total ? Count(total) : null,
            finished.Truncation switch
            {
                Native.TruncationTag.Complete => Truncation.Complete,
                Native.TruncationTag.ServerStopped => Truncation.ServerStopped,
                Native.TruncationTag.ReadPastLimit => Truncation.ReadPastLimit,
                Native.TruncationTag.ByteLimit => Truncation.ByteLimit,
                _ => throw new InvalidOperationException(
                    $"The core sent a truncation this build does not know: {finished.Truncation}"),
            }),
        Native.RunEvent.CommandCompleted command =>
            new QueryEvent.CommandCompleted(command.RowsAffected is { } affected ? Count(affected) : null),
        Native.RunEvent.Notice notice => new QueryEvent.Notice(notice.Severity, notice.Message, notice.Code),
        Native.RunEvent.NoticeLimitReached limit => new QueryEvent.NoticeLimitReached(Count(limit.Retained)),
        Native.RunEvent.Finished finished =>
            new QueryEvent.Finished(Outcome(finished.Outcome), Transaction(finished.Transaction)),
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

    public static TransactionState Transaction(Native.TransactionStateTag state) => state switch
    {
        Native.TransactionStateTag.Idle => TransactionState.Idle,
        Native.TransactionStateTag.InTransaction => TransactionState.InTransaction,
        Native.TransactionStateTag.Failed => TransactionState.Failed,
        _ => TransactionState.Unknown,
    };

    public static SessionHealth Health(Native.SessionHealthTag health) => health switch
    {
        Native.SessionHealthTag.Reconnecting reconnecting =>
            new SessionHealth.Reconnecting(checked((int)reconnecting.Attempt)),
        Native.SessionHealthTag.Offline => new SessionHealth.Offline(),
        Native.SessionHealthTag.Failed failed => new SessionHealth.Failed(
            failed.Cause switch
            {
                Native.FailureCauseTag.Tls => FailureCause.Tls,
                Native.FailureCauseTag.Configuration => FailureCause.Configuration,
                Native.FailureCauseTag.HostKey => FailureCause.HostKey,
                _ => FailureCause.Authentication,
            },
            failed.Reason is { } reason ? Error(reason) : null),
        _ => new SessionHealth.Online(),
    };

    public static Native.SessionHealthTag Health(SessionHealth health) => health switch
    {
        SessionHealth.Reconnecting reconnecting =>
            new Native.SessionHealthTag.Reconnecting(checked((uint)reconnecting.Attempt)),
        SessionHealth.Offline => new Native.SessionHealthTag.Offline(),
        SessionHealth.Failed failed => new Native.SessionHealthTag.Failed(
            failed.Cause switch
            {
                FailureCause.Tls => Native.FailureCauseTag.Tls,
                FailureCause.Configuration => Native.FailureCauseTag.Configuration,
                FailureCause.HostKey => Native.FailureCauseTag.HostKey,
                _ => Native.FailureCauseTag.Authentication,
            },
            failed.Reason is { } reason ? Error(reason) : null),
        _ => new Native.SessionHealthTag.Online(),
    };

    public static SecretKind Kind(Native.SecretKindTag kind) => kind switch
    {
        Native.SecretKindTag.SshPassword => SecretKind.SshPassword,
        Native.SecretKindTag.SshPassphrase => SecretKind.SshPassphrase,
        _ => SecretKind.DatabasePassword,
    };

    public static Native.SecretKindTag Kind(SecretKind kind) => kind switch
    {
        SecretKind.SshPassword => Native.SecretKindTag.SshPassword,
        SecretKind.SshPassphrase => Native.SecretKindTag.SshPassphrase,
        _ => Native.SecretKindTag.DatabasePassword,
    };

    // A health the app hands back to wait on compares by its fields, and the reason never differs.
    private static Native.ErrorInfo Error(CoreError error) => new(
        error.Code,
        [.. error.Codes],
        error.Message,
        error.Server is { } server
            ? new Native.ServerMessage(
                server.Message,
                server.Code,
                server.SqlState,
                server.Detail,
                server.Hint,
                server.Position is { } position ? checked((uint)position) : null)
            : null,
        error.Path,
        error.Secret is { } secret ? Kind(secret) : null,
        error.HostKey is { } key
            ? new Native.HostKeyFailure(key.Host, key.Algorithm, key.Fingerprint, key.KnownHosts, key.Line, key.TrustAllowed)
            : null,
        error.TlsFailure is { } failure ? TlsFailureKind(failure) : null);

    private static Native.TlsFailureTag TlsFailureKind(TlsFailure failure) => failure switch
    {
        TlsFailure.UnknownIssuer => Native.TlsFailureTag.UnknownIssuer,
        TlsFailure.NameMismatch => Native.TlsFailureTag.NameMismatch,
        TlsFailure.Expired => Native.TlsFailureTag.Expired,
        TlsFailure.NotYetValid => Native.TlsFailureTag.NotYetValid,
        TlsFailure.Revoked => Native.TlsFailureTag.Revoked,
        TlsFailure.ServerRefusedTls => Native.TlsFailureTag.ServerRefusedTls,
        TlsFailure.ServerRequiresTls => Native.TlsFailureTag.ServerRequiresTls,
        TlsFailure.ServerRefusedStrict => Native.TlsFailureTag.ServerRefusedStrict,
        TlsFailure.ServerRequiresStrict => Native.TlsFailureTag.ServerRequiresStrict,
        TlsFailure.HandshakeRejected => Native.TlsFailureTag.HandshakeRejected,
        TlsFailure.CaFileInvalid => Native.TlsFailureTag.CaFileInvalid,
        TlsFailure.ClientIdentityInvalid => Native.TlsFailureTag.ClientIdentityInvalid,
        _ => Native.TlsFailureTag.Other,
    };

    // Every tag named: a tag this build does not know must not land in another item's slot.
    public static SecretItem Item(Native.SecretItemTag item) => item switch
    {
        Native.SecretItemTag.McpToken => SecretItem.McpToken,
        Native.SecretItemTag.AnthropicKey => SecretItem.AnthropicKey,
        Native.SecretItemTag.OpenAiKey => SecretItem.OpenAIKey,
        Native.SecretItemTag.OpenAiCompatibleKey => SecretItem.OpenAICompatibleKey,
        Native.SecretItemTag.AccountRefreshToken => SecretItem.AccountRefreshToken,
        _ => throw new ArgumentOutOfRangeException(nameof(item), item, "A secret item the core added after this build."),
    };

    public static Native.HostConfig Host(HostConfiguration configuration) =>
        new(configuration.ClientVersion, configuration.StorageDirectory);

    public static Native.ConnectionSecrets Secrets(ConnectionSecrets secrets) =>
        new(secrets.DatabasePassword, secrets.SshPassword, secrets.SshPassphrase);

    public static Native.SafeModeTag Level(SafeMode level) => level switch
    {
        SafeMode.ConfirmWrites => Native.SafeModeTag.ConfirmWrites,
        SafeMode.ReadOnly => Native.SafeModeTag.ReadOnly,
        _ => Native.SafeModeTag.Off,
    };

    public static Native.ConnectionRecord Record(SavedConnection connection) => new(
        connection.Id?.ToString() ?? string.Empty,
        connection.Name,
        connection.EngineId,
        connection.Host,
        checked((ushort)connection.Port),
        connection.Database,
        connection.UserName,
        connection.IntegratedAuth,
        new Native.TlsSettings(
            Tls(connection.Tls.Mode),
            connection.Tls.CaFile,
            connection.Tls.ClientCertificate,
            connection.Tls.ClientKey,
            connection.Tls.ServerName),
        connection.Ssh is { } ssh
            ? new Native.SshSettings(
                ssh.Host,
                ssh.Port is { } port ? checked((ushort)port) : null,
                ssh.UserName,
                [.. ssh.JumpHosts],
                ssh.Auth switch
                {
                    SshAuthMethod.PrivateKey => new Native.SshAuthTag.PrivateKey(ssh.KeyPath, ssh.KeyHasPassphrase),
                    SshAuthMethod.Password => new Native.SshAuthTag.Password(),
                    SshAuthMethod.KeyboardInteractive => new Native.SshAuthTag.KeyboardInteractive(),
                    _ => new Native.SshAuthTag.Agent(),
                })
            : null,
        Level(connection.SafeMode),
        connection.QueryTimeoutSeconds is { } timeout ? checked((uint)timeout) : null,
        [],
        connection.Color,
        connection.GroupId?.ToString(),
        connection.LastOpened?.ToUnixTimeMilliseconds(),
        [.. connection.Tags.Select(tag => tag.ToString())]);

    public static SavedConnection Connection(Native.ConnectionRecord record) => new(
        Guid.Parse(record.Id),
        record.Name,
        record.DriverId,
        record.Host,
        record.Port,
        record.Database,
        record.Username,
        new TlsSettings(
            Tls(record.Tls.Mode),
            record.Tls.CaFile,
            record.Tls.ClientCertificate,
            record.Tls.ClientKey,
            record.Tls.ServerName),
        record.SafeMode switch
        {
            Native.SafeModeTag.ConfirmWrites => SafeMode.ConfirmWrites,
            Native.SafeModeTag.ReadOnly => SafeMode.ReadOnly,
            _ => SafeMode.Off,
        },
        record.IntegratedAuth,
        record.Ssh is { } ssh
            ? new SshSettings(
                ssh.Host,
                ssh.Port,
                ssh.Username,
                [.. ssh.JumpHosts],
                ssh.Auth switch
                {
                    Native.SshAuthTag.PrivateKey => SshAuthMethod.PrivateKey,
                    Native.SshAuthTag.Password => SshAuthMethod.Password,
                    Native.SshAuthTag.KeyboardInteractive => SshAuthMethod.KeyboardInteractive,
                    _ => SshAuthMethod.Agent,
                },
                ssh.Auth is Native.SshAuthTag.PrivateKey key ? key.Path : null,
                ssh.Auth is Native.SshAuthTag.PrivateKey { HasPassphrase: true })
            : null,
        record.QueryTimeoutSecs is { } seconds ? checked((int)seconds) : null,
        record.Color,
        record.GroupId is { } group ? Guid.Parse(group) : null,
        record.LastOpenedMs is { } opened ? DateTimeOffset.FromUnixTimeMilliseconds(opened) : null)
    {
        Tags = [.. record.Tags.Select(Guid.Parse)],
    };

    public static ConnectionGroup Group(Native.GroupRecord group) => new(
        Guid.Parse(group.Id),
        group.Name,
        group.ParentId is { } parent ? Guid.Parse(parent) : null,
        checked((int)group.Order),
        group.Color);

    public static LibrarySnapshot Snapshot(Native.LibrarySnapshot snapshot) => new(
        [.. snapshot.Connections.Select(Connection)],
        [.. snapshot.Groups.Select(Group)],
        [.. snapshot.Favorites.Select(Guid.Parse)],
        [.. snapshot.Recent.Select(Guid.Parse)])
    {
        Tags = [.. snapshot.Tags.Select(tag => new ConnectionTag(Guid.Parse(tag.Id), tag.Name, tag.Color))],
    };

    public static ParsedConnectionUrl Url(Native.ParsedConnectionUrl url) => new(
        url.DriverId,
        url.Host,
        url.Port,
        url.Username,
        url.Password,
        url.Database,
        url.TlsMode is { } mode ? Tls(mode) : null,
        url.CaFile,
        url.ClientCertificate,
        url.ClientKey,
        url.ServerName);

    private static Native.TlsModeTag Tls(TlsMode mode) => mode switch
    {
        TlsMode.Disable => Native.TlsModeTag.Disable,
        TlsMode.Prefer => Native.TlsModeTag.Prefer,
        TlsMode.Require => Native.TlsModeTag.Require,
        TlsMode.Strict => Native.TlsModeTag.Strict,
        _ => Native.TlsModeTag.VerifyFull,
    };

    private static TlsMode Tls(Native.TlsModeTag mode) => mode switch
    {
        Native.TlsModeTag.Disable => TlsMode.Disable,
        Native.TlsModeTag.Prefer => TlsMode.Prefer,
        Native.TlsModeTag.Require => TlsMode.Require,
        Native.TlsModeTag.Strict => TlsMode.Strict,
        _ => TlsMode.VerifyFull,
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

    public static Native.CellEdit Edit(CellEdit edit) => edit switch
    {
        CellEdit.Text text => new Native.CellEdit.Text(text.Value),
        CellEdit.Null => new Native.CellEdit.Null(),
        _ => new Native.CellEdit.Default(),
    };

    public static CellEdit Edit(Native.CellEdit edit) => edit switch
    {
        Native.CellEdit.Text text => new CellEdit.Text(text.TextValue),
        Native.CellEdit.Null => CellEdit.Null.Instance,
        _ => CellEdit.ServerDefault.Instance,
    };

    public static Native.RowEdit Edit(RowEdit edit) => edit switch
    {
        RowEdit.Update update => new Native.RowEdit.Update(
            checked((ulong)update.Row),
            [.. update.Cells.Select(cell => new Native.CellChange(checked((uint)cell.Column), Edit(cell.Edit)))]),
        RowEdit.Insert insert => new Native.RowEdit.Insert([.. insert.Cells.Select(Edit)]),
        RowEdit.Delete delete => new Native.RowEdit.Delete(checked((ulong)delete.Row)),
        _ => throw new ArgumentException("A row edit of a kind the core does not know.", nameof(edit)),
    };

    public static EditLock Lock(Native.EditLock locked) => locked switch
    {
        Native.EditLock.ReadOnlyConnection => EditLock.ReadOnlyConnection,
        Native.EditLock.NoPrimaryKey => EditLock.NoPrimaryKey,
        Native.EditLock.KeyUnreadable => EditLock.KeyUnreadable,
        _ => EditLock.ColumnsChanged,
    };

    public static SaveGate Gate(Native.SaveGate gate) => gate switch
    {
        Native.SaveGate.Run => SaveGate.Run,
        Native.SaveGate.Confirm => SaveGate.Confirm,
        _ => SaveGate.Refuse,
    };
}
