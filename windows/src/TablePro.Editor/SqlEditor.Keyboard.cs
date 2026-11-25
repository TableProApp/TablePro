using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Input;
using TablePro.Editor.Model;
using TablePro.Graphics;
using Windows.System;
using Windows.UI.Core;

namespace TablePro.Editor;

public sealed partial class SqlEditor
{
    private char _pendingHighSurrogate;
    private EditorKeymap _keymap = EditorKeymap.Default;

    // The host lays a shortcut preset over the editor's own keys; caret and text box keys never move.
    public EditorKeymap Keymap
    {
        get => _keymap;
        set
        {
            _keymap = value ?? EditorKeymap.Default;
            SyncFindBar();
        }
    }

    // The command's key as the context menu and the find bar show it, empty when it has none.
    public string KeyLabel(EditorCommand command) => _keymap.Label(command, KeyWord);

    internal static string KeyWord(string id) => HostStrings.Get("Key_" + id);

    // The Edit menu and the context menu run a command, never the key that runs it now.
    public bool Run(EditorCommand command)
    {
        switch (command)
        {
            case EditorCommand.Undo:
                Edit(_model.Undo);
                break;
            case EditorCommand.Redo:
                Edit(_model.Redo);
                break;
            case EditorCommand.Cut:
                Cut();
                break;
            case EditorCommand.Copy:
                Copy();
                break;
            case EditorCommand.Paste:
                _ = PasteAsync();
                break;
            case EditorCommand.SelectAll:
                _model.SelectAll();
                break;
            case EditorCommand.Find:
                OpenFind();
                SyncFindBar();
                break;
            case EditorCommand.Replace:
                OpenReplace();
                SyncFindBar();
                break;
            case EditorCommand.FormatQuery:
                _ = FormatAsync();
                break;
            case EditorCommand.ToggleComment:
                Edit(_model.ToggleLineComment);
                break;
            case EditorCommand.DeleteLine:
                Edit(_model.DeleteLines);
                break;
            case EditorCommand.NextOccurrence:
                Edit(_model.SelectNextOccurrence);
                break;
            case EditorCommand.Fold:
                FoldAtCaret();
                break;
            case EditorCommand.Unfold:
                UnfoldAtCaret();
                break;
            default:
                return false;
        }
        return true;
    }

    // The bar is made on first use, so it learns the keys then and whenever they change.
    private void SyncFindBar()
    {
        if (_findBar is { } bar && !ReferenceEquals(bar.Keymap, _keymap))
        {
            bar.Keymap = _keymap;
        }
    }

    // Keys as Windows text boxes and VS Code have them; the map is in 0002-sql-editor-control.md.
    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        // Keys typed into the find box bubble up here; they are the box's.
        if (!ReferenceEquals(e.OriginalSource, this))
        {
            base.OnKeyDown(e);
            return;
        }
        RestartBlink();
        _tsf?.FlushPendingComposition();
        // While the IME composes, its keys are its own; it hands back the ones it does not use after.
        if (IsComposing || e.Key == (VirtualKey)229)
        {
            return;
        }
        var control = Down(VirtualKey.Control);
        var shift = Down(VirtualKey.Shift);
        var alt = Down(VirtualKey.Menu);
        // An open completion list takes its keys first, Insert mode's Enter and Tab included.
        if (HandleCompletionKey(e.Key, control, shift, alt))
        {
            e.Handled = true;
            return;
        }
        // Vim sees a key before the editor's own commands, and the app's accelerators come after both.
        e.Handled = _vim is null ? HandleKey(e.Key, control, shift, alt) : HandleVimKey(e.Key, control, shift, alt);
        if (!e.Handled)
        {
            base.OnKeyDown(e);
        }
    }

    // Also for tests that drive the editor without input.
    public bool HandleKey(VirtualKey key, bool control, bool shift, bool alt)
    {
        // EditorKeymap.IsBuiltIn picks the keys that reach the switches below, so the app refuses a preset on those.
        if (EditorKey.FromVirtualKey((int)key, control, alt, shift) is { } pressed && !EditorKeymap.IsBuiltIn(pressed))
        {
            return _keymap.CommandFor(pressed) is { } command && Run(command);
        }
        var page = Math.Max(1, VisibleLineCount - 1);
        switch (key)
        {
            case VirtualKey.Left:
                Move(control ? CaretMove.WordLeft : CaretMove.Left, shift);
                return true;
            case VirtualKey.Right:
                Move(control ? CaretMove.WordRight : CaretMove.Right, shift);
                return true;
            case VirtualKey.Up when alt && !control:
                Edit(() => { if (shift) { _model.CopyLines(down: false); } else { _model.MoveLines(down: false); } });
                return true;
            case VirtualKey.Down when alt && !control:
                Edit(() => { if (shift) { _model.CopyLines(down: true); } else { _model.MoveLines(down: true); } });
                return true;
            case VirtualKey.Up when control && alt:
                Edit(() => _model.AddCaretVertically(-1));
                return true;
            case VirtualKey.Down when control && alt:
                Edit(() => _model.AddCaretVertically(1));
                return true;
            case VirtualKey.Up when control:
                ScrollBy(0, -LineHeight);
                return true;
            case VirtualKey.Down when control:
                ScrollBy(0, LineHeight);
                return true;
            case VirtualKey.Up:
                Move(CaretMove.Up, shift);
                return true;
            case VirtualKey.Down:
                Move(CaretMove.Down, shift);
                return true;
            case VirtualKey.PageUp:
                ScrollBy(0, -page * LineHeight);
                Move(CaretMove.PageUp, shift, page);
                return true;
            case VirtualKey.PageDown:
                ScrollBy(0, page * LineHeight);
                Move(CaretMove.PageDown, shift, page);
                return true;
            case VirtualKey.Home:
                Move(control ? CaretMove.DocumentStart : CaretMove.LineStart, shift);
                return true;
            case VirtualKey.End:
                Move(control ? CaretMove.DocumentEnd : CaretMove.LineEnd, shift);
                return true;
            case VirtualKey.Back:
                Edit(() => _model.Backspace(word: control));
                return true;
            case VirtualKey.Delete when shift && !control:
                Cut();
                return true;
            case VirtualKey.Delete:
                Edit(() => _model.Delete(word: control));
                return true;
            case VirtualKey.Enter when !control && !alt:
                Edit(_model.NewLine);
                return true;
            case VirtualKey.Tab when !control && !alt:
                Edit(() => { if (shift) { _model.Outdent(); } else { _model.Tab(); } });
                return true;
            case VirtualKey.Escape:
                if (_findBar?.IsOpen == true)
                {
                    CloseFind();
                    return true;
                }
                return _model.CollapseToPrimary();
            case VirtualKey.Insert when control && !shift:
                Copy();
                return true;
            case VirtualKey.Insert when shift && !control:
                _ = PasteAsync();
                return true;
            case VirtualKey.F3:
                FindNext(backward: shift);
                SyncFindBar();
                return true;
        }
        if (!control || alt)
        {
            return false;
        }
        switch (key)
        {
            case VirtualKey.Space when !shift:
                ShowCompletion();
                return true;
            case (VirtualKey)221 when !shift:
                Edit(_model.Indent);
                return true;
            case (VirtualKey)219 when !shift:
                Edit(_model.Outdent);
                return true;
            case (VirtualKey)187 or VirtualKey.Add:
                Zoom += 0.1f;
                return true;
            case (VirtualKey)189 or VirtualKey.Subtract:
                Zoom -= 0.1f;
                return true;
            case VirtualKey.Number0 or VirtualKey.NumberPad0:
                Zoom = 1;
                return true;
        }
        return false;
    }

    // Input methods send their text through TSF instead.
    private void OnCharacterReceived(Microsoft.UI.Xaml.UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        var c = e.Character;
        if (IsComposing || !ReferenceEquals(e.OriginalSource, this))
        {
            return;
        }
        if (char.IsHighSurrogate(c))
        {
            _pendingHighSurrogate = c;
            e.Handled = true;
            return;
        }
        if (char.IsControl(c))
        {
            return;
        }
        var text = char.IsLowSurrogate(c) && _pendingHighSurrogate != 0 ? new string([_pendingHighSurrogate, c]) : c.ToString();
        _pendingHighSurrogate = '\0';
        var version = Document.Version;
        if (!RouteVimText(text, Down(VirtualKey.Shift)))
        {
            TypeText(text);
        }
        if (Document.Version != version)
        {
            AfterTyped(text);
        }
        e.Handled = true;
    }

    // For tests and the gate harness.
    public void TypeText(string text)
    {
        Edit(() => _model.Type(text));
    }

    private void Move(CaretMove move, bool extend, int pageLines = 1)
    {
        _model.Move(move, extend, pageLines);
        EnsureCaretVisible();
    }

    private void Edit(Action action)
    {
        action();
        EnsureCaretVisible();
        Invalidate();
    }

    public void Copy()
    {
        var text = _model.CopyText();
        if (text.Length > 0)
        {
            _ = SetClipboard(text);
        }
    }

    // The text leaves the document only once the clipboard took it, so a held clipboard loses nothing.
    public void Cut()
    {
        var text = _model.CopyText();
        if (text.Length > 0 && SetClipboard(text))
        {
            Edit(() => _model.Cut());
        }
    }

    public async Task PasteAsync()
    {
        if (await ClipboardText.TryGetAsync() is { } text)
        {
            Edit(() => _model.Paste(text));
        }
    }

    private bool SetClipboard(string text) => ClipboardText.TrySet(
        Document.LineEnding == LineEnding.CrLf ? text.Replace("\n", "\r\n", StringComparison.Ordinal) : text);

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
}
