using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Helpers;
using TablePro.Core.Shortcuts;
using Windows.System;

namespace TablePro.App.Controls;

/// <summary>
/// A button that records the next key chord pressed. Focus alone does not arm it, so Tab moves through a list of
/// recorders without capturing anything; a click, Space or Enter starts recording. While recording, Esc cancels,
/// Backspace or Delete clears the shortcut, and Tab gives up and moves on.
/// </summary>
public sealed partial class ShortcutRecorder : Button
{
    private KeyChord _chord;
    private bool _recording;

    public ShortcutRecorder()
    {
        MinWidth = 168;
        HorizontalContentAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetHelpText(this, Strings.Get("Shortcuts/RecorderHelpText"));
        Click += (_, _) => StartRecording();
        PreviewKeyDown += OnPreviewKeyDown;
        PreviewKeyUp += OnPreviewKeyUp;
        LostFocus += (_, _) => StopRecording();
        UpdateContent(VirtualKeyModifiers.None);
    }

    /// <summary>A chord was pressed. The owner decides whether it can be assigned and sets <see cref="Chord"/> if so.</summary>
    public event EventHandler<KeyChord>? Recorded;

    /// <summary>Backspace or Delete was pressed while recording, asking for the command to have no shortcut.</summary>
    public event EventHandler? Cleared;

    public KeyChord Chord
    {
        get => _chord;
        set
        {
            _chord = value;
            UpdateContent(VirtualKeyModifiers.None);
        }
    }

    public bool IsRecording => _recording;

    private void StartRecording()
    {
        if (_recording)
        {
            return;
        }

        _recording = true;
        Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        UpdateContent(ShortcutKeys.CurrentModifiers());
    }

    private void StopRecording()
    {
        if (!_recording)
        {
            return;
        }

        _recording = false;
        Style = (Style)Application.Current.Resources["DefaultButtonStyle"];
        UpdateContent(VirtualKeyModifiers.None);
    }

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_recording)
        {
            return;
        }

        var modifiers = ShortcutKeys.CurrentModifiers();
        if (ShortcutKeys.IsModifierKey(e.Key))
        {
            UpdateContent(modifiers);
            e.Handled = true;
            return;
        }

        var bare = modifiers == VirtualKeyModifiers.None;
        switch (e.Key)
        {
            case VirtualKey.Tab when bare:
                // Not handled, so focus moves on and LostFocus ends the recording.
                return;
            case VirtualKey.Escape when bare:
                StopRecording();
                break;
            case VirtualKey.Back or VirtualKey.Delete when bare:
                StopRecording();
                Cleared?.Invoke(this, EventArgs.Empty);
                break;
            default:
                var chord = ShortcutKeys.ToChord(e.Key, modifiers);
                if (chord.IsEmpty)
                {
                    // A key no chord can end in (an IME or media key): keep waiting for a real one.
                    break;
                }

                StopRecording();
                Recorded?.Invoke(this, chord);
                break;
        }

        // Handled even for Space and Enter, or the button would take them as a click and start recording again.
        e.Handled = true;
    }

    private void OnPreviewKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (_recording && ShortcutKeys.IsModifierKey(e.Key))
        {
            UpdateContent(ShortcutKeys.CurrentModifiers());
            e.Handled = true;
        }
    }

    private void UpdateContent(VirtualKeyModifiers held)
    {
        string text;
        if (_recording)
        {
            var modifiers = ShortcutKeys.ModifierText(held);
            text = modifiers.Length == 0 ? Strings.Get("Shortcuts/RecorderPrompt") : modifiers;
        }
        else
        {
            text = _chord.IsEmpty ? Strings.Get("Common/None") : _chord.ToString();
        }

        Content = text;
        AutomationProperties.SetItemStatus(this, _recording ? Strings.Get("Shortcuts/RecorderRecording") : string.Empty);
    }
}
