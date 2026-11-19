using System.Globalization;
using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

// A Vim engine over a real editor model, for the ports of the macOS suites in apple/TableProTests/Core/Vim.
internal sealed class VimSession : IVimHost
{
    public const int LeftKey = 37;

    public const int RightKey = 39;

    public VimSession(string text = "", int caret = 0, VimRegisters? registers = null)
    {
        // The macOS mock types exactly what it is given, so brackets are not closed for it.
        Model = new EditorModel(new TextDocument(text), new EditorOptions { AutoClosePairs = false });
        Engine = new VimEngine(Model, this, registers ?? new VimRegisters());
        Model.SetCaret(caret);
    }

    public EditorModel Model { get; }

    public VimEngine Engine { get; }

    public string Text => Model.Document.GetText();

    public int Caret => Model.Primary.Start;

    // Start and length of the primary selection, as macOS's selectedRange() gives them.
    public (int Location, int Length) Selection => (Model.Primary.Start, Model.Primary.Length);

    public List<string> Clipboard { get; } = [];

    public List<string> Commands { get; } = [];

    public List<VimEditorKey> EditorKeys { get; } = [];

    public List<VimFold> Folds { get; } = [];

    public List<VimScroll> Scrolls { get; } = [];

    public List<int> ScrolledRows { get; } = [];

    // Rows on screen; every row unless a test narrows it.
    public (int First, int Last) Visible { get; set; } = (0, int.MaxValue);

    public VimMode Mode => Engine.Mode;

    public int UndoCount => Model.Document.Undo.UndoCount;

    public int RedoCount => Model.Document.Undo.RedoCount;

    // Each text element is one key, as Swift's Character is.
    public void Press(string keys)
    {
        var elements = StringInfo.GetTextElementEnumerator(keys);
        while (elements.MoveNext())
        {
            Engine.Process(elements.GetTextElement());
        }
    }

    public bool Key(string key, bool shift = false) => Engine.Process(key, shift);

    public void Escape() => Engine.Process(VimEngine.Escape);

    public void Backspace() => Engine.Process("\u007F");

    // Insert mode leaves typing to the editor, which puts the text at the caret.
    public void Type(string text)
    {
        foreach (var c in text)
        {
            if (!Engine.Process(c.ToString()))
            {
                Model.Type(c.ToString());
            }
        }
    }

    public void SetCaret(int offset) => Model.SetCaret(offset);

    public void SetSelection(int location, int length) => Model.SetSelection(location, location + length);

    (int First, int Last) IVimHost.VisibleRows() => Visible;

    void IVimHost.WriteClipboard(string text) => Clipboard.Add(text);

    void IVimHost.ScrollRows(int rows)
    {
        ScrolledRows.Add(rows);
        if (Visible.Last != int.MaxValue)
        {
            Visible = (Visible.First + rows, Visible.Last + rows);
        }
    }

    void IVimHost.ScrollCaret(VimScroll position) => Scrolls.Add(position);

    void IVimHost.Fold(VimFold command) => Folds.Add(command);

    void IVimHost.Command(string command) => Commands.Add(command);

    // The editor's own Left and Right, which the macro tests record.
    void IVimHost.ReplayEditorKey(VimEditorKey key)
    {
        EditorKeys.Add(key);
        if (key.Code is LeftKey or RightKey)
        {
            Model.Move(key.Code == LeftKey ? CaretMove.Left : CaretMove.Right, extend: key.Shift);
        }
    }
}
