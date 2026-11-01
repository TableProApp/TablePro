namespace TablePro.Drivers.PostgreSql;

/// <summary>
/// Where the target's notice handler hands over the port it waits on, and where a stop learns the target's call is
/// over. <see cref="Abandon"/> releases the waiters when the target could not be ended in time.
/// </summary>
internal sealed class PostgreSqlDebugRendezvous
{
    private readonly Lock _lock = new();
    private readonly TaskCompletionSource<int?> _port = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _settled = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool _hasPort;
    private bool _abandoned;

    public bool HasPort
    {
        get
        {
            lock (_lock)
            {
                return _hasPort;
            }
        }
    }

    public bool HasSettled => _settled.Task.IsCompleted;

    /// <summary>True when the waiters were released without the target's call ending: it may still hold its locks.</summary>
    public bool IsAbandoned
    {
        get
        {
            lock (_lock)
            {
                return _abandoned;
            }
        }
    }

    public Task Settled => _settled.Task;

    public void Deliver(int port)
    {
        lock (_lock)
        {
            _hasPort = true;
        }

        _port.TrySetResult(port);
    }

    public void Settle() => Release(abandoning: false);

    public void Abandon() => Release(abandoning: true);

    /// <summary>The port once the target reaches the routine, or null when its call ended first.</summary>
    public Task<int?> PortAsync() => _port.Task;

    /// <summary>
    /// True when <paramref name="step"/> answered before this settled. The step keeps running on its connection either
    /// way; only the wait on it ends.
    /// </summary>
    public async Task<bool> AnswersFirstAsync(Task step) => await Task.WhenAny(step, _settled.Task) == step;

    private void Release(bool abandoning)
    {
        lock (_lock)
        {
            if (_settled.Task.IsCompleted)
            {
                return;
            }

            _abandoned = abandoning;
            _settled.TrySetResult();
        }

        _port.TrySetResult(null);
    }
}
