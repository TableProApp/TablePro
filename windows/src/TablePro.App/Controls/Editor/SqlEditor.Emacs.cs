using Microsoft.UI.Xaml.Input;
using TablePro.Core.Keymaps;
using Windows.System;

namespace TablePro.App.Controls.Editor;

/// <summary>Emacs key bindings: the keymap and engine in TablePro.Core.Keymaps, acting at every caret.</summary>
public sealed partial class SqlEditor
{
    private EmacsEngine? _emacs;

    /// <summary>
    /// Whether Ctrl and Alt chords take their Emacs meaning, as Settings > Editor sets it. Vim mode wins while both are
    /// on, as only one key bindings mode can own the keys.
    /// </summary>
    public bool EmacsEnabled
    {
        get => _emacs is not null;
        set
        {
            if (value != EmacsEnabled)
            {
                _emacs = value ? new EmacsEngine(_carets) : null;
            }
        }
    }

    /// <summary>
    /// Runs an Emacs binding. Consulted after Vim and the completion list, at the same point of the one key handler,
    /// so no key is seen by two modes.
    /// </summary>
    private bool TryHandleEmacsKey(KeyRoutedEventArgs e, bool ctrl, bool alt, bool shift)
    {
        if (_emacs is not { } emacs || _vim is not null)
        {
            return false;
        }

        var keystroke = ToEmacsKeystroke(e, ctrl, alt, shift);
        if (keystroke.Key == EmacsKey.Other || (keystroke.Key == EmacsKey.Character && !ctrl && !alt))
        {
            return false;
        }

        // A click or a Shift+arrow since the last command ends the region; the check reads no text.
        SyncCaretSelectionWithView();

        // The arrows stay with an open completion list.
        var extends = emacs.IsMarkActive && !_completionPopup.IsOpen;
        if (EmacsKeymap.Resolve(keystroke, extends) is not { } command)
        {
            return false;
        }

        if (command.Kind == EmacsCommandKind.Quit)
        {
            HideCompletion();
            HideSuggestion();
        }

        SyncCaretsWithView();
        emacs.Perform(command);
        return true;
    }

    private static EmacsKeystroke ToEmacsKeystroke(KeyRoutedEventArgs e, bool ctrl, bool alt, bool shift)
    {
        var key = e.Key switch
        {
            VirtualKey.Space => EmacsKey.Space,
            VirtualKey.Back => EmacsKey.Backspace,
            VirtualKey.Left => EmacsKey.Left,
            VirtualKey.Right => EmacsKey.Right,
            VirtualKey.Up => EmacsKey.Up,
            VirtualKey.Down => EmacsKey.Down,
            >= VirtualKey.A and <= VirtualKey.Z => EmacsKey.Character,
            >= VirtualKey.Number0 and <= VirtualKey.Number9 => EmacsKey.Character,
            _ => EmacsKey.Other,
        };

        // Letters by key, whatever the layout types with Ctrl or Alt held; other keys as the layout types them, so
        // Ctrl+@ is found on whichever key makes '@'.
        var character = key switch
        {
            EmacsKey.Character when e.Key is >= VirtualKey.A and <= VirtualKey.Z => (char)('a' + (e.Key - VirtualKey.A)),
            EmacsKey.Character => CharacterFor(e, ctrl: false, alt: false, shift),
            EmacsKey.Space => ' ',
            _ => '\0',
        };
        return new EmacsKeystroke(key, character, ctrl, alt, shift);
    }
}
