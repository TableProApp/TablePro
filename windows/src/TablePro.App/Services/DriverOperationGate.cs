namespace TablePro.App.Services;

// UI-thread callers share this gate so a repeated Loaded event cannot interrupt an install.
internal sealed class DriverOperationGate
{
    public bool IsBusy { get; private set; }

    public async Task RunAsync(Func<Task> operation, Action<bool> busyChanged)
    {
        if (IsBusy)
        {
            return;
        }

        IsBusy = true;
        try
        {
            busyChanged(true);
            await operation().ConfigureAwait(true);
        }
        finally
        {
            IsBusy = false;
            busyChanged(false);
        }
    }
}
