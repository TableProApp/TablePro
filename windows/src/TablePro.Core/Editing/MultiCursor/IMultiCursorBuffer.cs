namespace TablePro.Core.Editing.MultiCursor;

/// <summary>
/// The text a <see cref="MultiCursorModel"/> edits. The model keeps the carets; the buffer holds the text and owns
/// undo, so each <see cref="Apply"/> call is one undo step whatever the number of carets it edits at.
/// </summary>
public interface IMultiCursorBuffer
{
    /// <summary>The whole text. The model reads it at the start of every command, so an implementation should cache it.</summary>
    string Text { get; }

    /// <summary>What a line break is in <see cref="Text"/>: "\r" for a RichEdit document, "\n" elsewhere.</summary>
    string LineBreak { get; }

    /// <summary>
    /// Applies edits that are sorted by start and never overlap, with offsets into the text as it was before any of
    /// them, as one undo step.
    /// </summary>
    void Apply(IReadOnlyList<TextEdit> edits, MultiCursorEditKind kind);
}
