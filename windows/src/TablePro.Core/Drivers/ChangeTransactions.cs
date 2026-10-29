using TablePro.Core.Editing;
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
public interface IChangeTransaction : IAsyncDisposable
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

public static class ChangeTransactions
{
    /// <summary>The session's cross-table transactions, or null when it can only save one table per transaction.</summary>
    public static IChangeTransactionProvider? For(IDatabaseSession session)
    {
        ArgumentNullException.ThrowIfNull(session);
        return session is IChangeTransactionProvider { SupportsChangeTransactions: true } provider ? provider : null;
    }
}
