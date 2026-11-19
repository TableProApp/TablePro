using System.Globalization;
using TablePro.Editor.Model;
using TablePro.Editor.Model.Vim;
using TablePro.Graphics;
using Windows.System;

namespace TablePro.Editor;

// Vim's modes and keys over the editor (windows/docs/decisions/0017-vim-mode.md). The engine is the model's; this
// routes the keys to it, draws its block caret and hands its commands to the host.
public sealed partial class SqlEditor
{
    private VimEngine? _vim;

    // Mode, pending keys or macro recording changed, or Vim was turned on or off.
    public event EventHandler? VimStatusChanged;

    // An ex command, or gt and gT as "tabnext" and "tabprevious"; VimCommandLine reads it.
    public event EventHandler<string>? VimCommand;

    // Off by default; turning it off leaves the text and the carets as they are.
    public bool IsVimEnabled
    {
        get => _vim is not null;
        set
        {
            if (value == IsVimEnabled)
            {
                return;
            }
            if (value)
            {
                _vim = new VimEngine(_model, new VimHost(this), VimRegisters.Shared);
                _vim.StatusChanged += OnVimStatusChanged;
            }
            else
            {
                _vim!.StatusChanged -= OnVimStatusChanged;
                _vim.Dispose();
                _vim = null;
            }
            Invalidate();
            VimStatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    // Null while Vim is off.
    public VimEngine? Vim => _vim;

    // Normal, Visual and the command line draw a block over the character, as Vim and the macOS editor do.
    internal bool DrawsBlockCaret => _vim is { } vim && !vim.Mode.IsInsert();

    private void OnVimStatusChanged(object? sender, EventArgs e)
    {
        Invalidate();
        VimStatusChanged?.Invoke(this, EventArgs.Empty);
    }

    // Also for tests that drive the editor without input; true when Vim took the key.
    internal bool RouteVimKey(VirtualKey key, bool control, bool shift, bool alt)
    {
        if (_vim is not { } vim)
        {
            return false;
        }
        var down = ToVimKey(key, control, shift, alt);
        var route = VimKeyRouter.Route(down, vim.Mode, vim.IsPending);
        if (route.Kind == VimRouteKind.Editor && vim.Mode.IsInsert())
        {
            if (!control && !shift && !alt && EditorKey(down.Key) is { } editorKey)
            {
                vim.NoteEditorKey(editorKey);
            }
            else if (MovesTheCaret(down.Key))
            {
                vim.BreakInsertUndo();
            }
        }
        return route.Kind switch
        {
            VimRouteKind.Discard => true,
            VimRouteKind.Engine => ProcessVim(route.Key, shift),
            _ => false,
        };
    }

    // A typed character goes to Vim first; Insert mode leaves it to the editor.
    internal bool RouteVimText(string text, bool shift)
    {
        if (_vim is null)
        {
            return false;
        }
        if (_vim.Mode == VimMode.Insert)
        {
            return ProcessVim(text, shift);
        }
        // Replace mode overwrites a character for each one typed, so a committed word goes a character at a time.
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext())
        {
            var element = elements.GetTextElement();
            if (!ProcessVim(element, shift))
            {
                TypeText(element);
            }
        }
        return true;
    }

    private static VimEditorKey? EditorKey(VimKey key) => key switch
    {
        VimKey.Left => VimEditorKey.Left,
        VimKey.Right => VimEditorKey.Right,
        VimKey.Up => VimEditorKey.Up,
        VimKey.Down => VimEditorKey.Down,
        VimKey.Home => VimEditorKey.Home,
        VimKey.End => VimEditorKey.End,
        VimKey.Delete => VimEditorKey.Delete,
        _ => null,
    };

    private static bool MovesTheCaret(VimKey key) => key is VimKey.Left or VimKey.Right or VimKey.Up or VimKey.Down
        or VimKey.Home or VimKey.End or VimKey.PageUp or VimKey.PageDown;

    private bool ProcessVim(string key, bool shift)
    {
        if (!_vim!.Process(key, shift))
        {
            return false;
        }
        EnsureCaretVisible();
        Invalidate();
        return true;
    }

    private static VimKeyDown ToVimKey(VirtualKey key, bool control, bool shift, bool alt)
    {
        var kind = key switch
        {
            VirtualKey.Escape => VimKey.Escape,
            VirtualKey.Left => VimKey.Left,
            VirtualKey.Right => VimKey.Right,
            VirtualKey.Up => VimKey.Up,
            VirtualKey.Down => VimKey.Down,
            VirtualKey.Home => VimKey.Home,
            VirtualKey.End => VimKey.End,
            VirtualKey.PageUp => VimKey.PageUp,
            VirtualKey.PageDown => VimKey.PageDown,
            VirtualKey.Delete => VimKey.Delete,
            VirtualKey.Back => VimKey.Backspace,
            VirtualKey.Enter => VimKey.Enter,
            VirtualKey.Tab => VimKey.Tab,
            // VK_OEM_4, '[' on a US keyboard, which Ctrl turns into Escape in a terminal.
            (VirtualKey)219 => VimKey.OpenBracket,
            >= VirtualKey.A and <= VirtualKey.Z => VimKey.Letter,
            _ => VimKey.Other,
        };
        var letter = kind == VimKey.Letter ? (char)('A' + (key - VirtualKey.A)) : '\0';
        return new VimKeyDown(kind, letter, control, shift, alt);
    }

    // zz, zt and zb: the cursor's row in the middle, at the top or at the bottom of the view.
    private void ScrollCursorTo(VimScroll position)
    {
        if (_layouts is null || _vim is null)
        {
            return;
        }
        var row = _model.Rows.RowOf(_vim.CursorPosition);
        var rows = Math.Max(1, VisibleLineCount);
        var top = position switch
        {
            VimScroll.Top => row,
            VimScroll.Bottom => row - rows + 1,
            _ => row - rows / 2,
        };
        SetScroll(_scrollX, Math.Max(0, top) * _layouts.LineHeight);
    }

    private void FoldForVim(VimFold command)
    {
        switch (command)
        {
            case VimFold.Open:
                UnfoldAtCaret();
                break;
            case VimFold.Close:
                FoldAtCaret();
                break;
            case VimFold.Toggle:
                if (!UnfoldAtCaret())
                {
                    FoldAtCaret();
                }
                break;
            case VimFold.OpenAll:
                UnfoldAll();
                break;
            case VimFold.CloseAll:
                FoldAll();
                break;
        }
    }

    private sealed class VimHost(SqlEditor editor) : IVimHost
    {
        public (int First, int Last) VisibleRows() =>
            (editor.FirstVisibleRow, editor.FirstVisibleRow + Math.Max(1, editor.VisibleLineCount) - 1);

        // Vim writes on every yank and delete, so its text stays out of clipboard history and other devices.
        public void WriteClipboard(string text) => ClipboardText.TrySet(
            editor.Document.LineEnding == LineEnding.CrLf ? text.Replace("\n", "\r\n", StringComparison.Ordinal) : text,
            inHistory: false);

        public void ScrollRows(int rows) => editor.ScrollBy(0, rows * editor.LineHeight);

        public void ScrollCaret(VimScroll position) => editor.ScrollCursorTo(position);

        public void Fold(VimFold command) => editor.FoldForVim(command);

        public void Command(string command) => editor.VimCommand?.Invoke(editor, command);
    }
}
