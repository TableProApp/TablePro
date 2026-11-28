using System.Collections.Concurrent;
using Microsoft.UI.Dispatching;
using TablePro.Interop;

namespace TablePro.App.Services;

// The agent's write questions arrive on a core thread that may block; the pane answers them on the UI thread, as
// McpBridge answers the MCP server's. Model B in ADR 0014: the approval surfaces in the pane, not the window.
internal sealed class AssistantApprover(DispatcherQueue queue, Func<AiWriteRequest, CancellationToken, Task<bool>> ask)
    : IAiApprover
{
    private readonly ConcurrentDictionary<ulong, CancellationTokenSource> _asking = new();
    private readonly ConcurrentDictionary<ulong, bool> _withdrawn = new();

    public bool Approve(AiWriteRequest request)
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
            return OnUi(() => ask(request, withdrawn.Token));
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
                // The question was answered as the reply ended.
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
