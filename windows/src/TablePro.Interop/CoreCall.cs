using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The generated code polls the core's future on the thread that awaits it, so every call starts on the
// thread pool. UniFFI cannot cancel a call, so a CancellationToken fires the core's own cancel token.
internal static class CoreCall
{
    public static async Task<T> RunAsync<T>(
        Func<Native.CancelToken, Task<T>> call,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var token = new Native.CancelToken();
        using var registration = cancellationToken.UnsafeRegister(
            static state => ((Native.CancelToken)state!).Cancel(),
            token);
        try
        {
            return await Task.Run(() => call(token), CancellationToken.None).ConfigureAwait(false);
        }
        catch (Native.CoreException exception)
        {
            throw Translate(exception, cancellationToken);
        }
    }

    public static async Task<T> RunAsync<T>(Func<Task<T>> call)
    {
        try
        {
            return await Task.Run(call, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Native.CoreException exception)
        {
            throw Translate(exception, CancellationToken.None);
        }
    }

    public static async Task RunAsync(Func<Task> call)
    {
        try
        {
            await Task.Run(call, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Native.CoreException exception)
        {
            throw Translate(exception, CancellationToken.None);
        }
    }

    public static T Run<T>(Func<T> call)
    {
        try
        {
            return call();
        }
        catch (Native.CoreException exception)
        {
            throw Translate(exception, CancellationToken.None);
        }
    }

    private static Exception Translate(Native.CoreException exception, CancellationToken cancellationToken) =>
        exception switch
        {
            Native.CoreException.Failed failed => new TableProException(Mapping.Error(failed.info)),
            _ when cancellationToken.IsCancellationRequested => new OperationCanceledException(cancellationToken),
            _ => new OperationCanceledException(),
        };
}
