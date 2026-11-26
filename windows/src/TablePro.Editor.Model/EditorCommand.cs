namespace TablePro.Editor.Model;

// The commands a key reaches through EditorKeymap; caret, selection and text box keys stay in the editor's switch.
public enum EditorCommand
{
    Undo,
    Redo,
    Cut,
    Copy,
    Paste,
    SelectAll,
    Find,
    Replace,
    FormatQuery,
    ToggleComment,
    DeleteLine,
    NextOccurrence,
    Fold,
    Unfold,
}
