using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Hosting;
using TablePro.Editor.Model;
using Windows.UI.ViewManagement;
using static TerraFX.Interop.Windows.SPI;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Editor;

public sealed partial class SqlEditor
{
    private readonly CaretBlink _blink = new();
    private readonly List<CaretSpot> _caretSpots = [];
    private readonly List<SpriteVisual> _caretSprites = [];
    private DispatcherQueueTimer? _blinkTimer;
    private InputActivationListener? _activation;
    private ContainerVisual? _caretLayer;
    private InsetClip? _caretClip;
    private CompositionColorBrush? _caretBrush;
    private CompositionColorBrush? _blockCaretBrush;
    private int _caretsPlaced;
    private uint _caretPixels;
    private bool _hooked;

    internal bool IsCaretBlinking => _blink.IsBlinking;

    internal bool WatchesWindowActivation => _activation is not null;

    internal bool IsInActiveWindow => _activation?.State == InputActivationState.Activated;

    internal bool IsCaretShown => _caretLayer is { IsVisible: true } && _caretsPlaced > 0;

    // The first caret's block width from the last frame; 0 for a bar.
    internal float FirstCaretBlockWidth => _caretSpots.Count > 0 ? _caretSpots[0].BlockWidth : 0;

    // Each time a blink, focus or the window showed or hid the carets.
    internal int CaretToggles { get; private set; }

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
        ShowCaretState();
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
        _blink.Restart();
        ShowCaretState();
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
        _blink.Tick();
        ShowCaretState();
        if (!_blink.IsBlinking)
        {
            sender.Stop();
        }
    }

    private void OnInputActivationChanged(InputActivationListener sender,
        InputActivationListenerActivationChangedEventArgs args)
    {
        _blink.SetActive(sender.State != InputActivationState.Deactivated);
        ShowCaretState();
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

    // A visual of its own over the swap chain, as WinUI's TextBox has a caret element, so a blink draws no frame.
    private void EnsureCaretLayer()
    {
        if (_caretLayer is not null)
        {
            return;
        }
        var compositor = ElementCompositionPreview.GetElementVisual(_panel).Compositor;
        _caretBrush = compositor.CreateColorBrush(_brushes?.Palette.Caret ?? default);
        _blockCaretBrush = compositor.CreateColorBrush(BlockCaretColor(_brushes?.Palette.Caret ?? default));
        _caretClip = compositor.CreateInsetClip();
        _caretLayer = compositor.CreateContainerVisual();
        _caretLayer.Clip = _caretClip;
        _caretLayer.IsVisible = _blink.CaretVisible;
        // SwapChainPanel puts its swap chain first in render order, so a child visual draws above it.
        ElementCompositionPreview.SetElementChildVisual(_panel, _caretLayer);
    }

    private void ShowCaretState()
    {
        if (_caretLayer is null || _caretLayer.IsVisible == _blink.CaretVisible)
        {
            return;
        }
        _caretLayer.IsVisible = _blink.CaretVisible;
        CaretToggles++;
    }

    // With the frame just presented, so the carets move with the text; snapped to pixels, as a Win32 caret is.
    private void PlaceCarets(float gutter, float width, float height, float lineHeight)
    {
        EnsureCaretLayer();
        var layer = _caretLayer!;
        var scaleX = Math.Max(_panel.CompositionScaleX, 0.01f);
        var scaleY = Math.Max(_panel.CompositionScaleY, 0.01f);
        var caretWidth = CaretPixels() / scaleX;
        layer.Size = new Vector2(width, height);
        _caretClip!.LeftInset = gutter;
        for (var i = 0; i < _caretSpots.Count; i++)
        {
            var (spot, blockWidth) = _caretSpots[i];
            if (i == _caretSprites.Count)
            {
                _caretSprites.Add(layer.Compositor.CreateSpriteVisual());
            }
            var sprite = _caretSprites[i];
            sprite.Brush = blockWidth > 0 ? _blockCaretBrush : _caretBrush;
            var top = MathF.Round(spot.Y * scaleY) / scaleY;
            var bottom = MathF.Round((spot.Y + lineHeight) * scaleY) / scaleY;
            var left = MathF.Round(spot.X * scaleX) / scaleX;
            var spriteWidth = blockWidth > 0 ? MathF.Round((spot.X + blockWidth) * scaleX) / scaleX - left : caretWidth;
            sprite.Offset = new Vector3(left, top, 0);
            sprite.Size = new Vector2(Math.Max(spriteWidth, caretWidth), bottom - top);
            if (i >= _caretsPlaced)
            {
                layer.Children.InsertAtTop(sprite);
            }
        }
        for (var i = _caretSpots.Count; i < _caretsPlaced; i++)
        {
            layer.Children.Remove(_caretSprites[i]);
        }
        _caretsPlaced = _caretSpots.Count;
        ShowCaretState();
    }

    // A tab shown again draws on a new swap chain, so its carets wait for that first frame.
    private void ClearCarets()
    {
        if (_caretLayer is null)
        {
            return;
        }
        _caretLayer.Children.RemoveAll();
        _caretsPlaced = 0;
    }

    private unsafe uint CaretPixels()
    {
        if (_caretPixels == 0)
        {
            uint pixels = 1;
            SystemParametersInfoW(SPI_GETCARETWIDTH, 0, &pixels, 0);
            _caretPixels = Math.Max(1, pixels);
        }
        return _caretPixels;
    }

    private void ReleaseCaretLayer()
    {
        if (_caretLayer is null)
        {
            return;
        }
        ElementCompositionPreview.SetElementChildVisual(_panel, null);
        foreach (var sprite in _caretSprites)
        {
            sprite.Dispose();
        }
        _caretSprites.Clear();
        _caretsPlaced = 0;
        _caretLayer.Dispose();
        _caretLayer = null;
        _caretClip?.Dispose();
        _caretClip = null;
        _caretBrush?.Dispose();
        _caretBrush = null;
        _blockCaretBrush?.Dispose();
        _blockCaretBrush = null;
    }

    // The caret's color over the character it covers, so the character still reads, as the macOS block does.
    private static Windows.UI.Color BlockCaretColor(Windows.UI.Color caret) =>
        Windows.UI.Color.FromArgb((byte)(caret.A * 2 / 5), caret.R, caret.G, caret.B);

    // Width 0 is a bar caret at the system width; more is Vim's block over a character.
    private readonly record struct CaretSpot(Vector2 Position, float BlockWidth);
}
