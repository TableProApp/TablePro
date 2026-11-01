using TablePro.Drivers.Beancount.Localization;

namespace TablePro.Drivers.Beancount;

/// <summary>
/// Builds a projection within the connection's timeout. The ledger is resolved before and after the backend runs,
/// and a build that saw the files change underneath it is thrown away and tried once more, so a projection never
/// mixes two versions of a ledger.
/// </summary>
internal sealed class BeancountProjector(
    string ledgerPath,
    TimeSpan timeout,
    Func<CancellationToken, Task<IBeancountProjectionSource>> sourceFactory)
{
    private const int Attempts = 2;

    public string LedgerPath => ledgerPath;

    public async Task<BeancountProjection> BuildAsync(CancellationToken cancellationToken)
    {
        // Resolving includes and writing SQLite are blocking file work.
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        try
        {
            return await BuildCoreAsync(deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw BeancountException.ConnectionFailed(BeancountStrings.Format("Beancount/ConnectTimedOut", timeout.TotalSeconds));
        }
    }

    private async Task<BeancountProjection> BuildCoreAsync(CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < Attempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var initialGraph = BeancountIncludeResolver.Resolve(ledgerPath);
            var initialSignatures = SourceSignatures.Read(initialGraph.ReloadDependencies);
            var source = await sourceFactory(cancellationToken);
            var result = await source.ReadAsync(ledgerPath, initialGraph, cancellationToken);

            cancellationToken.ThrowIfCancellationRequested();
            var finalGraph = BeancountIncludeResolver.Resolve(ledgerPath);
            if (!SamePaths(initialGraph.SourceFiles, finalGraph.SourceFiles) || !SamePaths(initialGraph.ReloadDependencies, finalGraph.ReloadDependencies))
            {
                continue;
            }

            var finalSignatures = SourceSignatures.Read(finalGraph.ReloadDependencies);
            if (!SourceSignatures.Equal(initialSignatures, finalSignatures))
            {
                continue;
            }

            var projection = BeancountProjection.Create(result.Rows, finalGraph.SourceFiles, finalGraph.ReloadDependencies, finalSignatures, result.BackendVersion);
            if (cancellationToken.IsCancellationRequested)
            {
                projection.Dispose();
                cancellationToken.ThrowIfCancellationRequested();
            }

            if (projection.IsStale())
            {
                projection.Dispose();
                continue;
            }

            return projection;
        }

        throw BeancountException.ConnectionFailed(BeancountStrings.Get("Beancount/LedgerChanged"));
    }

    private static bool SamePaths(IReadOnlyList<string> left, IReadOnlyList<string> right)
    {
        if (left.Count != right.Count)
        {
            return false;
        }

        for (var i = 0; i < left.Count; i++)
        {
            if (!string.Equals(left[i], right[i], StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
        }

        return true;
    }
}
