namespace TablePro.Core.Vim;

/// <summary>
/// The text the Vim engine edits. Offsets are UTF-16 code units and the text uses '\n' line ends, whatever the
/// editor stores, so the engine reads the same offsets as the editor's caret.
/// </summary>
public interface IVimBuffer
{
    /// <summary>The whole text. The engine reads it after every edit, so an implementation should cache it.</summary>
    string Text { get; }

    int SelectionStart { get; }

    int SelectionLength { get; }

    /// <summary>The text one level of indentation inserts, used by the indent operators and insert-mode Ctrl+T.</summary>
    string IndentUnit { get; }

    /// <summary>Selects a range, clamped to the text, and scrolls it into view.</summary>
    void Select(int start, int length);

    /// <summary>Replaces a range with text ('\n' line ends) and leaves the caret after the inserted text.</summary>
    void Replace(int start, int length, string text);

    void Undo();

    void Redo();

    /// <summary>
    /// Opens an undo group: every edit until the matching <see cref="EndUndoGroup"/> undoes as one step. Groups nest,
    /// so only the outermost pair bounds the step.
    /// </summary>
    void BeginUndoGroup();

    void EndUndoGroup();

    /// <summary>The first and last 0-based lines the editor shows, for H, M, L and the scroll keys.</summary>
    (int First, int Last) VisibleLines();
}
