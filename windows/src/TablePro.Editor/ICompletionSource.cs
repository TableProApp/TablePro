using TablePro.Interop;

namespace TablePro.Editor;

// What the editor completes from: a connection's catalog, through DatabaseSession.CompleteAsync.
public interface ICompletionSource
{
    // Caret is in UTF-16 units of text. Null where nothing completes.
    Task<SqlCompletion?> CompleteAsync(string text, int caret, bool asked, CancellationToken cancellationToken);
}
