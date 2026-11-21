using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Services;

// A query tab completes from its connection's catalog, the reads the object tree shares, in the database it runs in.
internal sealed class SessionCompletion(DatabaseSession session, Func<string?> database) : ICompletionSource
{
    public Task<SqlCompletion?> CompleteAsync(string text, int caret, bool asked, CancellationToken cancellationToken) =>
        session.CompleteAsync(text, caret, asked, database(), cancellationToken);
}
