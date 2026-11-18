using System.Collections.Concurrent;
using Microsoft.UI.Dispatching;
using TablePro.Interop;

namespace TablePro.App.Services;

// The MCP server's questions arrive on a core thread that may block; the windows answer them on the UI thread.
internal sealed class McpBridge(DispatcherQueue queue, Func<MainWindow?> window) : IMcpAppHost
{
    private readonly ConcurrentDictionary<ulong, CancellationTokenSource> _asking = new();

    // The core calls Approve and Withdraw on threads of their own, so a withdrawal can arrive before its question.
    private readonly ConcurrentDictionary<ulong, bool> _withdrawn = new();

    public bool OpenConnection(Guid connectionId) =>
        OnUi(() => window() is { } shown ? shown.OpenForClientAsync(connectionId) : Task.FromResult(false));

    public bool IsConnecting(Guid connectionId) =>
        OnUi(() => Task.FromResult(window()?.IsConnecting(connectionId) ?? false));

    public bool Approve(McpWriteRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        using var withdrawn = new CancellationTokenSource();
        if (!_asking.TryAdd(request.Id, withdrawn))
        {
            return false;
        }

        // Checked after the question is listed, so a withdrawal lands in one of the two.
        if (_withdrawn.TryRemove(request.Id, out _))
        {
            _asking.TryRemove(request.Id, out _);
            return false;
        }

        try
        {
            return OnUi(() => window() is { } shown
                ? shown.ApproveForClientAsync(request, withdrawn.Token)
                : Task.FromResult(false));
        }
        finally
        {
            _asking.TryRemove(request.Id, out _);
        }
    }

    public void Withdraw(ulong requestId)
    {
        _withdrawn[requestId] = true;
        if (_asking.TryGetValue(requestId, out var withdrawn))
        {
            _withdrawn.TryRemove(requestId, out _);
            try
            {
                withdrawn.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // The question was answered as the client went away.
            }
        }
    }

    // False when the UI thread is gone, as the app quits.
    private bool OnUi(Func<Task<bool>> ask)
    {
        var answer = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(() => _ = AnswerAsync(ask, answer)))
        {
            return false;
        }

        return answer.Task.GetAwaiter().GetResult();
    }

    private static async Task AnswerAsync(Func<Task<bool>> ask, TaskCompletionSource<bool> answer)
    {
        try
        {
            answer.TrySetResult(await ask().ConfigureAwait(true));
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            answer.TrySetResult(false);
        }
    }
}
