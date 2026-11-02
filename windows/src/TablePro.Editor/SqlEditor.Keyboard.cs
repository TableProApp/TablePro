using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Input;
using TablePro.Editor.Model;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI.Core;

namespace TablePro.Editor;

public sealed partial class SqlEditor
{
    private char _pendingHighSurrogate;

    // Keys as Windows text boxes and VS Code on Windows have them; windows/docs/decisions/0001-sql-editor-control.md
    // lists the full map.
    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _tsf?.FlushPendingComposition();
        // While the IME composes, its keys are its own; it hands back the ones it does not use after.
        if (IsComposing || e.Key == (VirtualKey)229)
        {
            return;
        }
        e.Handled = HandleKey(e.Key, Down(VirtualKey.Control), Down(VirtualKey.Shift), Down(VirtualKey.Menu));
        if (!e.Handled)
        {
            base.OnKeyDown(e);
        }
    }

    // One key press with its modifiers, for the keyboard and for tests that drive the editor without input.
    public bool HandleKey(VirtualKey key, bool control, bool shift, bool alt)
    {
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
                return true;
        }
        if (!control || alt)
        {
            return false;
        }
        switch (key)
        {
            case VirtualKey.A:
                _model.SelectAll();
                return true;
            case VirtualKey.C:
                Copy();
                return true;
            case VirtualKey.X:
                Cut();
                return true;
            case VirtualKey.V:
                _ = PasteAsync();
                return true;
            case VirtualKey.Z when shift:
            case VirtualKey.Y:
                Edit(_model.Redo);
                return true;
            case VirtualKey.Z:
                Edit(_model.Undo);
                return true;
            case VirtualKey.D:
                Edit(_model.SelectNextOccurrence);
                return true;
            case VirtualKey.F:
                OpenFind();
                return true;
            case VirtualKey.K when shift:
                Edit(_model.DeleteLines);
                return true;
            case (VirtualKey)191:
                Edit(_model.ToggleLineComment);
                return true;
            case (VirtualKey)221:
                Edit(_model.Indent);
                return true;
            case (VirtualKey)219:
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

    // Typed text from the keyboard layout. Input methods send theirs through TSF instead.
    private void OnCharacterReceived(Microsoft.UI.Xaml.UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        var c = e.Character;
        if (IsComposing)
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
        TypeText(text);
        e.Handled = true;
    }

    // Typing as the keyboard does it, for tests and the gate harness.
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
            SetClipboard(text);
        }
    }

    public void Cut()
    {
        string text = string.Empty;
        Edit(() => text = _model.Cut());
        if (text.Length > 0)
        {
            SetClipboard(text);
        }
    }

    public async Task PasteAsync()
    {
        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Text))
        {
            return;
        }
        var text = await content.GetTextAsync();
        Edit(() => _model.Paste(text));
    }

    private void SetClipboard(string text)
    {
        var package = new DataPackage();
        package.SetText(Document.LineEnding == LineEnding.CrLf ? text.Replace("\n", "\r\n", StringComparison.Ordinal) : text);
        Clipboard.SetContent(package);
    }

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
}
