using System.Runtime.InteropServices;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.App.Helpers;
using TablePro.Core.Vim;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI.Core;

namespace TablePro.App.Controls.Editor;

/// <summary>Vim keybindings: the engine in TablePro.Core.Vim driven from the editor's key handler.</summary>
public sealed partial class SqlEditor
{
    private const uint KeepKeyboardState = 0x4;

    private VimEngine? _vim;
    private VimCommandLineHandler? _vimCommands;
    private Canvas? _vimCaretLayer;
    private Rectangle? _vimCaret;
    private ScrollViewer? _scroller;
    private bool _vimHandlersAttached;
    private bool _vimEdited;
    private int _undoGroupDepth;
    private bool _undoGroupSnapshotTaken;

    /// <summary>Raised when <see cref="VimStatus"/> changes.</summary>
    public event EventHandler? VimStatusChanged;

    /// <summary>:q in Vim mode: close this editor's tab.</summary>
    public event EventHandler? VimQuitRequested;

    /// <summary>:tabnext N in Vim mode, or Ngt: select the tab at a 1-based position.</summary>
    public event EventHandler<int>? VimTabRequested;

    /// <summary>gt, gT, :tabnext, :tabprevious in Vim mode: select a tab relative to this one, positive to the right.</summary>
    public event EventHandler<int>? VimAdjacentTabRequested;

    /// <summary>How many tabs the window has, so Vim tab counts clamp and wrap like Vim's.</summary>
    public Func<int>? VimTabCount { get; set; }

    /// <summary>Whether keys go through the Vim engine. Off, the editor behaves exactly as without Vim.</summary>
    public bool VimEnabled
    {
        get => _vim is not null;
        set
        {
            if (value == VimEnabled)
            {
                return;
            }

            if (value)
            {
                EnableVim();
            }
            else
            {
                DisableVim();
            }
        }
    }

    /// <summary>The Vim mode and any half-typed command, such as "NORMAL", "INSERT", "NORMAL  2d" or ":w"; empty when Vim is off.</summary>
    public string VimStatus => _vim?.Status ?? string.Empty;

    private void EnableVim()
    {
        SyncText();
        _vimCommands = new VimCommandLineHandler { TabCount = () => VimTabCount?.Invoke() ?? 0 };
        _vimCommands.WriteRequested += (_, _) => SaveRequested?.Invoke(this, EventArgs.Empty);
        _vimCommands.QuitRequested += (_, _) => VimQuitRequested?.Invoke(this, EventArgs.Empty);
        _vimCommands.TabSelected += (_, number) => VimTabRequested?.Invoke(this, number);
        _vimCommands.AdjacentTabSelected += (_, offset) => VimAdjacentTabRequested?.Invoke(this, offset);

        _vim = new VimEngine(new VimBuffer(this));
        _vim.CommandEntered += (_, command) => _vimCommands?.Handle(command);
        _vim.StatusChanged += (_, _) => VimStatusChanged?.Invoke(this, EventArgs.Empty);
        _vim.ModeChanged += (_, _) => OnVimModeChanged();
        _vim.RegisterWritten += (_, register) => CopyToClipboard(register.Text);

        if (SelectionLength > 0)
        {
            Select(SelectionStart, 0);
        }

        EnsureVimCaret();
        HideCompletion();
        HideSuggestion();
        UpdateVimCaret();
        VimStatusChanged?.Invoke(this, EventArgs.Empty);
    }

    private void DisableVim()
    {
        // Reset closes an insert-mode undo group that would otherwise swallow every later edit into one step.
        _vim?.Reset();
        _vim = null;
        _vimCommands = null;
        _undoGroupDepth = 0;
        _undoGroupSnapshotTaken = false;
        if (_vimCaret is not null)
        {
            _vimCaret.Visibility = Visibility.Collapsed;
        }

        VimStatusChanged?.Invoke(this, EventArgs.Empty);
    }

    private bool IsVimOutsideInsert => _vim is { } vim && !vim.Mode.IsInsert;

    private void OnVimModeChanged()
    {
        if (IsVimOutsideInsert)
        {
            HideCompletion();
            HideSuggestion();
        }

        UpdateVimCaret();
    }

    private static void CopyToClipboard(string text)
    {
        var package = new DataPackage();
        package.SetText(text.Replace("\n", "\r\n", StringComparison.Ordinal));
        Clipboard.SetContent(package);
    }

    /// <summary>
    /// Escape leaves insert mode and closes completion and the inline suggestion with the same press, as Xcode and
    /// IdeaVim do; it runs before the completion list, which would otherwise take Escape for itself.
    /// </summary>
    private bool TryHandleVimEscape(KeyRoutedEventArgs e)
    {
        if (_vim is not { } vim || e.Key != VirtualKey.Escape)
        {
            return false;
        }

        // In normal mode with nothing pending, Escape is the find bar's, as without Vim.
        if (vim.Mode.Kind == VimModeKind.Normal && vim.PendingKeys.Length == 0 && _findBar.Visibility == Visibility.Visible)
        {
            return false;
        }

        HideCompletion();
        HideSuggestion();
        RunVimKey('\u001B', shift: false);
        return true;
    }

    /// <summary>Routes a key through the engine. Returns true when the key is done with; false lets the editor handle it.</summary>
    private bool TryHandleVimKey(KeyRoutedEventArgs e)
    {
        if (_vim is not { } vim)
        {
            return false;
        }

        var keystroke = ToVimKeystroke(e);
        var route = VimKeyRouter.Route(keystroke, vim.Mode);
        return route.Kind switch
        {
            VimKeyRouteKind.Discard => true,
            VimKeyRouteKind.Engine => RunVimKey(route.Key, keystroke.Shift),
            _ => false,
        };
    }

    private bool RunVimKey(char key, bool shift)
    {
        if (_vim is not { } vim)
        {
            return false;
        }

        // Typed characters may not have reached the cached text yet; the engine must see them.
        SyncText();
        _vimEdited = false;
        var consumed = vim.Process(key, shift);
        if (_vimEdited)
        {
            _vimEdited = false;
            _highlightTimer.Restart();
            TextChanged?.Invoke(this, EventArgs.Empty);
        }

        UpdateVimCaret();
        return consumed;
    }

    private VimKeystroke ToVimKeystroke(KeyRoutedEventArgs e)
    {
        var ctrl = IsDown(VirtualKey.Control);
        var alt = IsDown(VirtualKey.Menu);
        var shift = IsDown(VirtualKey.Shift);
        var kind = e.Key switch
        {
            VirtualKey.Escape => VimKeyKind.Escape,
            VirtualKey.Enter => VimKeyKind.Enter,
            VirtualKey.Tab => VimKeyKind.Tab,
            VirtualKey.Back => VimKeyKind.Backspace,
            VirtualKey.Delete => VimKeyKind.Delete,
            VirtualKey.Left => VimKeyKind.Left,
            VirtualKey.Right => VimKeyKind.Right,
            VirtualKey.Up => VimKeyKind.Up,
            VirtualKey.Down => VimKeyKind.Down,
            >= VirtualKey.F1 and <= VirtualKey.F24 => VimKeyKind.Other,
            VirtualKey.Shift or VirtualKey.Control or VirtualKey.Menu or VirtualKey.LeftShift or VirtualKey.RightShift
                or VirtualKey.LeftControl or VirtualKey.RightControl or VirtualKey.LeftMenu or VirtualKey.RightMenu
                or VirtualKey.LeftWindows or VirtualKey.RightWindows or VirtualKey.CapitalLock or VirtualKey.NumberKeyLock
                or VirtualKey.Scroll or VirtualKey.Home or VirtualKey.End or VirtualKey.PageUp or VirtualKey.PageDown
                or VirtualKey.Insert or VirtualKey.Application or VirtualKey.Snapshot or VirtualKey.Pause => VimKeyKind.Other,
            _ => VimKeyKind.Character,
        };
        var character = kind == VimKeyKind.Character ? CharacterFor(e, ctrl, alt, shift) : '\0';
        return new VimKeystroke(kind, character, ctrl, alt, shift);
    }

    /// <summary>
    /// What the key types under the current keyboard layout, so Vim's '$' or '{' work wherever a layout puts them.
    /// Ctrl+letter is the letter's control character, the way a terminal reports it.
    /// </summary>
    private static unsafe char CharacterFor(KeyRoutedEventArgs e, bool ctrl, bool alt, bool shift)
    {
        if (ctrl && !alt)
        {
            if (e.Key is >= VirtualKey.A and <= VirtualKey.Z)
            {
                return (char)(e.Key - VirtualKey.A + 1);
            }

            if (e.Key == VirtualKey.Space)
            {
                return ' ';
            }
        }

        var state = stackalloc byte[256];
        state[(int)VirtualKey.Shift] = (byte)(shift ? 0x80 : 0);
        state[(int)VirtualKey.Control] = (byte)(ctrl ? 0x80 : 0);
        state[(int)VirtualKey.Menu] = (byte)(alt ? 0x80 : 0);
        if (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.CapitalLock).HasFlag(CoreVirtualKeyStates.Locked))
        {
            state[(int)VirtualKey.CapitalLock] = 1;
        }

        var buffer = stackalloc char[4];

        // Leaving the keyboard state alone keeps a pending dead key for the text box when insert mode types it.
        var count = ToUnicodeEx((uint)e.Key, e.KeyStatus.ScanCode, state, buffer, 4, KeepKeyboardState, GetKeyboardLayout(0));
        return count == 1 ? buffer[0] : '\0';
    }

    private void EnsureVimCaret()
    {
        if (_vimCaretLayer is null && Content is Grid root)
        {
            _vimCaret = new Rectangle { Visibility = Visibility.Collapsed, Opacity = 0.45, RadiusX = 1, RadiusY = 1 };
            _vimCaretLayer = new Canvas { IsHitTestVisible = false };
            _vimCaretLayer.Children.Add(_vimCaret);
            _vimCaretLayer.SizeChanged += (_, args) => _vimCaretLayer.Clip = new RectangleGeometry
            {
                Rect = new Windows.Foundation.Rect(0, 0, args.NewSize.Width, args.NewSize.Height),
            };
            Grid.SetRow(_vimCaretLayer, 1);
            Grid.SetColumn(_vimCaretLayer, 1);
            root.Children.Add(_vimCaretLayer);
        }

        if (_vimCaret is not null)
        {
            _vimCaret.Fill = ThemeResources.Brush(this, "TextFillColorPrimaryBrush");
        }

        if (_vimHandlersAttached)
        {
            return;
        }

        _vimHandlersAttached = true;
        _box.SelectionChanged += (_, _) => UpdateVimCaret();
        _box.GotFocus += (_, _) => UpdateVimCaret();
        _box.LostFocus += (_, _) => UpdateVimCaret();
        _box.SizeChanged += (_, _) => UpdateVimCaret();
        ActualThemeChanged += (_, _) => EnsureVimCaret();

        // Enabled before the window applies its theme, the caret brush is picked again once the editor is in the tree.
        Loaded += (_, _) =>
        {
            if (_vim is not null)
            {
                EnsureVimCaret();
                UpdateVimCaret();
            }
        };
        if (Scroller is { } scroller)
        {
            scroller.ViewChanged += (_, _) => UpdateVimCaret();
        }
        else
        {
            _box.Loaded += (_, _) =>
            {
                if (Scroller is { } loaded)
                {
                    loaded.ViewChanged += (_, _) => UpdateVimCaret();
                }
            };
        }
    }

    private ScrollViewer? Scroller => _scroller ??= FindDescendant<ScrollViewer>(_box);

    /// <summary>
    /// Draws the normal-mode block caret over the character under the cursor. An overlay rather than a one-character
    /// selection, so the selection keeps meaning what it does for Run Current and Copy.
    /// </summary>
    private void UpdateVimCaret()
    {
        if (_vimCaret is null || _vimCaretLayer is null)
        {
            return;
        }

        if (_vim is not { } vim || vim.Mode.IsInsert || _box.FocusState == FocusState.Unfocused)
        {
            _vimCaret.Visibility = Visibility.Collapsed;
            return;
        }

        var offset = Math.Clamp(vim.Mode.IsVisual ? vim.CursorOffset : SelectionStart, 0, _text.Length);
        var onCharacter = offset < _text.Length && _text[offset] != '\r';
        var range = _box.Document.GetRange(offset, onCharacter ? offset + 1 : offset);
        range.GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        var origin = _box.TransformToVisual(_vimCaretLayer).TransformPoint(new Windows.Foundation.Point(rect.X, rect.Y));
        var width = onCharacter && rect.Width > 1 ? rect.Width : Math.Max(4, _box.FontSize * 0.6);
        var height = rect.Height > 1 ? rect.Height : LineHeightPixels;
        Canvas.SetLeft(_vimCaret, origin.X);
        Canvas.SetTop(_vimCaret, origin.Y);
        _vimCaret.Width = width;
        _vimCaret.Height = height;
        _vimCaret.Visibility = Visibility.Visible;
    }

    /// <summary>Applies a Vim edit through RichEdit's own range, so formatting and scroll stay put, as one undo step.</summary>
    private void ReplaceForVim(int start, int length, string text)
    {
        SyncText();
        var at = Math.Clamp(start, 0, _text.Length);
        var end = Math.Clamp(at + length, at, _text.Length);
        PushUndo(force: false);
        _suppress = true;
        try
        {
            _box.Document.GetRange(at, end).SetText(TextSetOptions.None, text);
            _text = ReadDocument();
            var caret = Math.Min(at + text.Length, _text.Length);
            _box.Document.Selection.SetRange(caret, caret);
        }
        finally
        {
            _suppress = false;
        }

        UpdateGutter();
        _vimEdited = true;
    }

    private (int First, int Last) VisibleLineRange()
    {
        var lastLine = Math.Max(0, _lineCount - 1);
        if (Scroller is not { } scroller || scroller.ViewportHeight <= 0)
        {
            return (0, lastLine);
        }

        // Exact line spacing makes every line LineHeightPixels tall below the top padding.
        var top = Math.Max(0, scroller.VerticalOffset - _box.Padding.Top);
        var first = Math.Clamp((int)(top / LineHeightPixels), 0, lastLine);
        var last = Math.Clamp((int)((top + scroller.ViewportHeight) / LineHeightPixels) - 1, first, lastLine);
        return (first, last);
    }

    [LibraryImport("user32.dll")]
    private static unsafe partial int ToUnicodeEx(uint virtualKey, uint scanCode, byte* keyState, char* buffer, int bufferSize, uint flags, nint layout);

    [LibraryImport("user32.dll")]
    private static partial nint GetKeyboardLayout(uint threadId);

    /// <summary>The editor's text as the engine reads it: '\n' line ends over the document's '\r', offsets unchanged.</summary>
    private sealed class VimBuffer(SqlEditor editor) : IVimBuffer
    {
        private string? _source;
        private string _normalized = string.Empty;

        public string Text
        {
            get
            {
                // Rebuilt only when an edit replaced the cached text, since the engine reads it many times per key.
                var raw = editor._text;
                if (!ReferenceEquals(raw, _source))
                {
                    _source = raw;
                    _normalized = raw.Replace('\r', '\n');
                }

                return _normalized;
            }
        }

        public int SelectionStart => editor.SelectionStart;

        public int SelectionLength => editor.SelectionLength;

        public string IndentUnit => Indent;

        public void Select(int start, int length)
        {
            var textLength = editor._text.Length;
            var at = Math.Clamp(start, 0, textLength);
            var end = Math.Clamp(at + length, at, textLength);
            if (editor.SelectionStart == at && editor.SelectionStart + editor.SelectionLength == end)
            {
                return;
            }

            editor.Select(at, end - at);
        }

        public void Replace(int start, int length, string text) => editor.ReplaceForVim(start, length, text.Replace('\n', '\r'));

        public void Undo()
        {
            editor.Undo();
            Collapse();
        }

        public void Redo()
        {
            editor.Redo();
            Collapse();
        }

        public void BeginUndoGroup() => editor._undoGroupDepth++;

        public void EndUndoGroup()
        {
            if (editor._undoGroupDepth > 0 && --editor._undoGroupDepth == 0)
            {
                editor._undoGroupSnapshotTaken = false;
            }
        }

        public (int First, int Last) VisibleLines() => editor.VisibleLineRange();

        // An undo snapshot keeps the selection it was taken with, which outside visual mode would read as one.
        private void Collapse()
        {
            if (editor.SelectionLength > 0)
            {
                editor.Select(editor.SelectionStart, 0);
            }
        }
    }
}
