using Microsoft.Data.Sqlite;

namespace TablePro.Drivers.Beancount;

/// <summary>
/// One build of a ledger: a private in-memory SQLite database and what the ledger looked like when it was read.
/// </summary>
/// <remarks>
/// The database is a named shared-cache memory database, which lives while any connection to it is open. This object
/// holds one open for its lifetime, so sessions open and close their own connections freely; a query still running
/// on a connection when a newer build replaces this one keeps the old database alive until it finishes. Pooling is
/// off so a disposed build's memory is not kept by idle pooled connections.
/// </remarks>
internal sealed class BeancountProjection : IDisposable
{
    private readonly SqliteConnection _keeper;
    private readonly Lock _leaseGate = new();
    private int _leases;
    private bool _retired;

    private BeancountProjection(
        string connectionString,
        SqliteConnection keeper,
        IReadOnlyList<string> watchedPaths,
        IReadOnlyDictionary<string, SourceSignature> signatures,
        string backendVersion)
    {
        ConnectionString = connectionString;
        _keeper = keeper;
        WatchedPaths = watchedPaths;
        Signatures = signatures;
        BackendVersion = backendVersion;
    }

    public string ConnectionString { get; }

    public IReadOnlyList<string> WatchedPaths { get; }

    public IReadOnlyDictionary<string, SourceSignature> Signatures { get; }

    public string BackendVersion { get; }

    public static BeancountProjection Create(
        BeancountProjectionRows rows,
        IReadOnlyList<string> sourceFiles,
        IReadOnlyList<string> watchedPaths,
        IReadOnlyDictionary<string, SourceSignature> signatures,
        string backendVersion)
    {
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = "tablepro-beancount-" + Guid.NewGuid().ToString("N"),
            Mode = SqliteOpenMode.Memory,
            Cache = SqliteCacheMode.Shared,
            Pooling = false,
        }.ConnectionString;

        var keeper = new SqliteConnection(connectionString);
        try
        {
            keeper.Open();
            BeancountProjectionWriter.Load(keeper, rows, sourceFiles);
            using var readOnly = keeper.CreateCommand();
            readOnly.CommandText = "PRAGMA query_only = ON";
            readOnly.ExecuteNonQuery();
            return new BeancountProjection(connectionString, keeper, watchedPaths, signatures, backendVersion);
        }
        catch
        {
            keeper.Dispose();
            throw;
        }
    }

    /// <summary>Whether any watched path differs from when this build read the ledger.</summary>
    public bool IsStale() => !SourceSignatures.Equal(SourceSignatures.Read(WatchedPaths), Signatures);

    /// <summary>
    /// Keeps the database alive while a caller opens a connection to it. Opening a named memory database that no
    /// longer exists silently creates an empty one, so a build replaced mid-call must outlive that call.
    /// </summary>
    public void AddLease()
    {
        lock (_leaseGate)
        {
            _leases++;
        }
    }

    public void ReleaseLease()
    {
        lock (_leaseGate)
        {
            _leases--;
            if (_retired && _leases == 0)
            {
                _keeper.Dispose();
            }
        }
    }

    /// <summary>A newer build replaced this one: the database goes once the last lease is released.</summary>
    public void Retire()
    {
        lock (_leaseGate)
        {
            _retired = true;
            if (_leases == 0)
            {
                _keeper.Dispose();
            }
        }
    }

    public void Dispose() => Retire();
}
