using TablePro.Core.Editing;
using TablePro.Core.Import;
using TablePro.Core.Schema;

namespace TablePro.Core.Drivers;

/// <summary>
/// A session that can write several tables, or empty a table and refill it, inside one transaction. A multi-table
/// sync and an import that deletes the existing rows first both need it to commit whole or not at all, as the macOS
/// app runs them; <see cref="IDatabaseSession.SaveChangesAsync"/> commits one table at a time. Found with a type test,
/// like the other optional capabilities, and read through <see cref="ChangeTransactions.For"/>.
/// </summary>
public interface IChangeTransactionProvider
{
    /// <summary>
    /// False when this connection's engine cannot roll a write back, such as Databend behind the MySQL driver, so a
    /// session class shared by several engines can still say no for one of them.
    /// </summary>
    bool SupportsChangeTransactions => true;

    /// <summary>Opens a connection of its own and begins a transaction on it.</summary>
    Task<IChangeTransaction> BeginChangesAsync(CancellationToken cancellationToken);
}

/// <summary>
/// One open write transaction. Each call yields to the thread pool before it touches the provider. Disposing it without
/// <see cref="CommitAsync"/> rolls back everything it ran, which is what a caller does after any failure. One caller
/// at a time: the calls share a single connection.
/// </summary>
/// <remarks>
/// It counts key matches itself because an import that updates or skips existing rows must see the rows it wrote
/// earlier in the same transaction; a probe on another connection would not, and could wait on this one's locks.
/// </remarks>
public interface IChangeTransaction : IImportRowMatcher, IAsyncDisposable
{
    /// <summary>
    /// Runs the changes in order, binding values as the session's own save does. A keyed change that hits other than
    /// one row throws <see cref="RowCountMismatchException"/>; the transaction is then only fit to be disposed.
    /// </summary>
    Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken);

    /// <summary>Deletes every row of <paramref name="table"/>; the count is the engine's, or -1 when it does not say.</summary>
    Task<long> DeleteAllRowsAsync(ObjectName table, CancellationToken cancellationToken);

    Task CommitAsync(CancellationToken cancellationToken);
}

/// <summary>
/// A session whose tables each choose a storage engine, as MySQL's and MariaDB's do. A MyISAM, MEMORY or ARCHIVE table
/// ignores ROLLBACK, so a transaction that fails keeps whatever it already wrote there; the sync review names such
/// tables before anything runs, as the macOS app reports them.
/// </summary>
public interface IStorageEngineProvider
{
    /// <summary>
    /// The storage engine of each of <paramref name="tables"/> that exists and has one, keyed by the name as asked.
    /// Empty for an engine whose tables do not choose one.
    /// </summary>
    Task<IReadOnlyDictionary<ObjectName, string>> GetStorageEnginesAsync(IReadOnlyCollection<ObjectName> tables, CancellationToken cancellationToken);
}

public static class ChangeTransactions
{
    /// <summary>The session's cross-table transactions, or null when it can only save one table per transaction.</summary>
    public static IChangeTransactionProvider? For(IDatabaseSession session)
    {
        ArgumentNullException.ThrowIfNull(session);
        return session is IChangeTransactionProvider { SupportsChangeTransactions: true } provider ? provider : null;
    }
}
