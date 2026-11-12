using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using TablePro.Editor.Model;
using Windows.UI.ViewManagement;
using static TerraFX.Interop.Windows.SPI;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Editor;

public sealed partial class SqlEditor
{
    private readonly CaretBlink _blink = new();
    private DispatcherQueueTimer? _blinkTimer;
    private InputActivationListener? _activation;
    private bool _hooked;

    internal bool IsCaretBlinking => _blink.IsBlinking;

    internal bool WatchesWindowActivation => _activation is not null;

    internal bool IsInActiveWindow => _activation?.State == InputActivationState.Activated;

    // Only while loaded: UISettings, the window's listener and the timer would hold the editor through its handlers.
    private void Hook()
    {
        if (_hooked)
        {
            return;
        }
        _hooked = true;
        _uiSettings.ColorValuesChanged += OnColorValuesChanged;
        // The window the editor is in now, since a tab can be dragged to another one.
        if (XamlRoot?.ContentIslandEnvironment?.AppWindowId is { Value: not 0 } window)
        {
            _activation = InputActivationListener.GetForWindowId(window);
        }
        if (_activation is not null)
        {
            _activation.InputActivationChanged += OnInputActivationChanged;
        }
        _blinkTimer ??= DispatcherQueue.CreateTimer();
        _blinkTimer.Tick += OnBlinkTick;
        ReadCaretSettings();
        _blink.SetActive(_activation?.State != InputActivationState.Deactivated);
        SyncBlinkTimer();
    }

    private void Unhook()
    {
        if (!_hooked)
        {
            return;
        }
        _hooked = false;
        _uiSettings.ColorValuesChanged -= OnColorValuesChanged;
        if (_activation is not null)
        {
            _activation.InputActivationChanged -= OnInputActivationChanged;
            _activation = null;
        }
        if (_blinkTimer is not null)
        {
            _blinkTimer.Stop();
            _blinkTimer.Tick -= OnBlinkTick;
        }
    }

    // Input shows the caret and starts its timeout again.
    private void RestartBlink()
    {
        if (_blink.Restart())
        {
            Invalidate();
        }
        SyncBlinkTimer();
    }

    // Started again on each change, so the next blink is a full interval after it.
    private void SyncBlinkTimer()
    {
        if (_blinkTimer is null)
        {
            return;
        }
        _blinkTimer.Stop();
        if (_hooked && _blink.IsBlinking)
        {
            _blinkTimer.Interval = _blink.Interval;
            _blinkTimer.Start();
        }
    }

    private void OnBlinkTick(DispatcherQueueTimer sender, object args)
    {
        if (_blink.Tick())
        {
            Invalidate();
        }
        if (!_blink.IsBlinking)
        {
            sender.Stop();
        }
    }

    private void OnInputActivationChanged(InputActivationListener sender,
        InputActivationListenerActivationChangedEventArgs args)
    {
        if (_blink.SetActive(sender.State != InputActivationState.Deactivated))
        {
            Invalidate();
        }
        SyncBlinkTimer();
    }

    // AccessibilitySettings.HighContrastChanged needs a CoreWindow, and this one fires for contrast themes too.
    private void OnColorValuesChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(RebuildBrushes);

    private unsafe void ReadCaretSettings()
    {
        var blink = GetCaretBlinkTime();
        // INFINITE is blinking turned off, and 0 a failed call.
        _blink.Interval = blink is > 0 and < uint.MaxValue ? TimeSpan.FromMilliseconds(blink) : TimeSpan.Zero;
        uint timeout;
        // A system that does not know SPI_GETCARETTIMEOUT fails the call; Windows' default stands in.
        _blink.Timeout = SystemParametersInfoW(SPI_GETCARETTIMEOUT, 0, &timeout, 0)
            ? TimeSpan.FromMilliseconds(timeout)
            : CaretBlink.DefaultTimeout;
    }
}
