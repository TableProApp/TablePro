using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Editor.Model;
using Windows.System;
using Windows.UI.Core;

namespace TablePro.App.Controls;

// Records one chord for a command, a mirror of apple ShortcutRecorderButton. WinUI has no app-global key monitor, so
// while armed it rides its own key events, swallows them before any accelerator fires, reads the modifier state, maps
// the key through EditorKey and reports the chord; Delete removes the binding, Esc or losing focus cancels, and plain
// Tab is let through so focus can move on.
internal sealed partial class ShortcutRecorderButton : Button
{
    private bool _armed;
    private bool _swallowing;
    private (bool Control, bool Alt, bool Shift) _held;
    private string? _label;
    private string _name = string.Empty;

    public ShortcutRecorderButton()
    {
        MinWidth = 128;
        HorizontalContentAlignment = HorizontalAlignment.Center;
        Click += OnClick;
        PreviewKeyDown += OnPreviewKeyDown;
        KeyDown += OnKeyDown;
        KeyUp += OnKeyUp;
        LostFocus += OnLostFocus;
        ToolTipService.SetToolTip(this, Strings.Get("ShortcutRecorderHelp"));
        AutomationProperties.SetHelpText(this, Strings.Get("ShortcutRecorderHelp"));
        Render();
    }

    public event EventHandler<KeyChord>? Captured;

    public event EventHandler? RemoveRequested;

    // The command this row binds, and its current key as the page words it (null shows None).
    public void Configure(string action, string name, string? label)
    {
        _name = name;
        _label = label;
        AutomationProperties.SetAutomationId(this, "shortcut-recorder-" + action);
        if (!_armed)
        {
            Render();
        }
    }

    public void Cancel()
    {
        if (_armed)
        {
            Disarm();
        }
    }

    private static bool IsModifier(VirtualKey key) => key is VirtualKey.Control or VirtualKey.LeftControl
        or VirtualKey.RightControl or VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu
        or VirtualKey.Shift or VirtualKey.LeftShift or VirtualKey.RightShift
        or VirtualKey.LeftWindows or VirtualKey.RightWindows;

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void OnClick(object sender, RoutedEventArgs e)
    {
        if (_armed)
        {
            Disarm();
        }
        else
        {
            Arm();
        }
    }

    private void Arm()
    {
        _armed = true;
        _held = (Down(VirtualKey.Control), Down(VirtualKey.Menu), Down(VirtualKey.Shift));
        Focus(FocusState.Programmatic);
        Render();
    }

    private void Disarm()
    {
        _armed = false;
        _swallowing = false;
        _held = default;
        Render();
    }

    private void OnLostFocus(object sender, RoutedEventArgs e) => Cancel();

    // Tunnels to the control first, so it can swallow arrows, Tab, Alt and function keys before the framework moves
    // focus or arms the menu; marking the event handled here keeps any accelerator from firing on the bubble.
    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_armed)
        {
            return;
        }

        if (IsModifier(e.Key))
        {
            UpdateHeld();
            e.Handled = true;
            _swallowing = true;
            return;
        }

        var control = Down(VirtualKey.Control);
        var alt = Down(VirtualKey.Menu);
        var shift = Down(VirtualKey.Shift);

        // Plain Tab leaves recording and moves focus on; Ctrl or Alt with Tab is a chord to capture.
        if (e.Key == VirtualKey.Tab && !control && !alt)
        {
            Disarm();
            return;
        }

        e.Handled = true;
        _swallowing = true;
        if (e.Key == VirtualKey.Escape && !control && !alt && !shift)
        {
            Disarm();
            return;
        }

        if (e.Key == VirtualKey.Delete && !control && !alt && !shift)
        {
            Disarm();
            RemoveRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        if (EditorKey.FromVirtualKey((int)e.Key, control, alt, shift) is { } key)
        {
            var chord = new KeyChord(key.Key, control, alt, shift);
            Disarm();
            Captured?.Invoke(this, chord);
        }
    }

    // Belt and braces: swallow the bubbling event too, so a chord we began consuming never reaches an accelerator even
    // where the framework does not share the handled state with the preview event.
    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_swallowing)
        {
            e.Handled = true;
        }
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        _swallowing = false;
        if (_armed)
        {
            UpdateHeld();
        }
    }

    private void UpdateHeld()
    {
        var held = (Down(VirtualKey.Control), Down(VirtualKey.Menu), Down(VirtualKey.Shift));
        if (held != _held)
        {
            _held = held;
            Render();
        }
    }

    private void Render()
    {
        if (_armed)
        {
            Background = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"];
            Foreground = (Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"];
            Opacity = 1;
            Content = HeldText();
            AutomationProperties.SetName(this, Strings.Get("ShortcutRecording"));
            return;
        }

        Background = null;
        Foreground = null;
        AutomationProperties.SetName(this, Strings.Format("ShortcutRecorderName", _name));
        var placeholder = string.IsNullOrEmpty(_label);
        Content = placeholder ? Strings.Get("ShortcutNone") : _label;
        Opacity = placeholder ? 0.6 : 1;
    }

    private string HeldText()
    {
        var parts = new List<string>();
        if (_held.Control)
        {
            parts.Add(Strings.Get("Key_Ctrl"));
        }

        if (_held.Alt)
        {
            parts.Add(Strings.Get("Key_Alt"));
        }

        if (_held.Shift)
        {
            parts.Add(Strings.Get("Key_Shift"));
        }

        return parts.Count == 0
            ? Strings.Get("ShortcutTypeHint")
            : parts.Aggregate((text, part) => Strings.Format("Key_Join", text, part));
    }
}
