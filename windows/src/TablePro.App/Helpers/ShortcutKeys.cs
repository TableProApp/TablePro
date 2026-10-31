using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Input;
using TablePro.Core.Shortcuts;
using Windows.System;
using Windows.UI.Core;

namespace TablePro.App.Helpers;

/// <summary>
/// Converts between Core's chords and WinUI's keys. Core's key and modifier values are the Win32 virtual-key numbers
/// WinUI uses, so each conversion is a cast rather than a lookup.
/// </summary>
public static class ShortcutKeys
{
    private const ShortcutModifiers KnownModifiers = ShortcutModifiers.Control | ShortcutModifiers.Alt | ShortcutModifiers.Shift | ShortcutModifiers.Windows;

    /// <summary>The chord a key press makes, or <see cref="KeyChord.None"/> for a modifier alone or a key no chord can end in.</summary>
    public static KeyChord ToChord(VirtualKey key, VirtualKeyModifiers modifiers) =>
        KeyChord.IsChordKey((int)key) ? new KeyChord((ShortcutKey)(int)key, (ShortcutModifiers)(int)modifiers & KnownModifiers) : KeyChord.None;

    public static VirtualKey ToVirtualKey(ShortcutKey key) => (VirtualKey)(int)key;

    public static VirtualKeyModifiers ToModifiers(ShortcutModifiers modifiers) => (VirtualKeyModifiers)(int)modifiers;

    /// <summary>
    /// The modifiers held right now. Key events report the key but not the modifiers, and reading the thread's key
    /// state is how WinUI code learns them.
    /// </summary>
    public static VirtualKeyModifiers CurrentModifiers()
    {
        var modifiers = VirtualKeyModifiers.None;
        if (IsDown(VirtualKey.Control))
        {
            modifiers |= VirtualKeyModifiers.Control;
        }

        if (IsDown(VirtualKey.Menu))
        {
            modifiers |= VirtualKeyModifiers.Menu;
        }

        if (IsDown(VirtualKey.Shift))
        {
            modifiers |= VirtualKeyModifiers.Shift;
        }

        if (IsDown(VirtualKey.LeftWindows) || IsDown(VirtualKey.RightWindows))
        {
            modifiers |= VirtualKeyModifiers.Windows;
        }

        return modifiers;
    }

    /// <summary>Whether the key is one of the modifiers, which only ever qualify a chord and never end one.</summary>
    public static bool IsModifierKey(VirtualKey key) => key is VirtualKey.Control or VirtualKey.LeftControl or VirtualKey.RightControl
        or VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu
        or VirtualKey.Shift or VirtualKey.LeftShift or VirtualKey.RightShift
        or VirtualKey.LeftWindows or VirtualKey.RightWindows;

    /// <summary>The modifiers alone as the recorder shows them while they are held, <c>Ctrl+Shift+</c>.</summary>
    public static string ModifierText(VirtualKeyModifiers modifiers)
    {
        var text = string.Empty;
        if (modifiers.HasFlag(VirtualKeyModifiers.Windows))
        {
            text += "Win+";
        }

        if (modifiers.HasFlag(VirtualKeyModifiers.Control))
        {
            text += "Ctrl+";
        }

        if (modifiers.HasFlag(VirtualKeyModifiers.Menu))
        {
            text += "Alt+";
        }

        if (modifiers.HasFlag(VirtualKeyModifiers.Shift))
        {
            text += "Shift+";
        }

        return text;
    }

    public static KeyboardAccelerator Accelerator(KeyChord chord) =>
        new() { Key = ToVirtualKey(chord.Key), Modifiers = ToModifiers(chord.Modifiers) };

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
}
