using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using TablePro.Editor.Automation;
using TablePro.Editor.Input;
using TablePro.Editor.Model;
using TablePro.Editor.Rendering;
using TablePro.Graphics;
using Windows.UI.ViewManagement;

namespace TablePro.Editor;

// What one presented frame cost, for the gate harness.
public readonly record struct EditorFrame(
    long PresentedAt,
    double RenderMilliseconds,
    double LexMilliseconds,
    long DocumentVersion,
    int FirstLine,
    int LastLine,
    int LayoutsCreated,
    bool Software);

// Our own control, since RichEditBox failed its gate (windows/docs/decisions/0002-sql-editor-control.md).
public sealed partial class SqlEditor : UserControl, IDisposable
{
    private const float DefaultFontSize = 14;

    private readonly Grid _root = new();
    private readonly SwapChainPanel _panel = new();
    private readonly ScrollBar _verticalBar = new() { Orientation = Orientation.Vertical, IndicatorMode = ScrollingIndicatorMode.MouseIndicator };
    private readonly ScrollBar _horizontalBar = new() { Orientation = Orientation.Horizontal, IndicatorMode = ScrollingIndicatorMode.MouseIndicator };
    private readonly List<SyntaxSpan> _spans = [];
    private readonly UISettings _uiSettings = new();
    private readonly EditorModel _model;
    private SyntaxHighlighter? _highlighter;
    private ISyntaxLexer? _lexer;
    private GraphicsDevice? _device;
    private TextLayouts? _layouts;
    private Brushes? _brushes;
    private TsfInput? _tsf;
    private FindBar? _findBar;
    private SqlEditorAutomationPeer? _peer;
    private bool _renderQueued;
    private bool _loaded;
    private float _fontSize = DefaultFontSize;
    private float _zoom = 1;
    private string _composition = string.Empty;
    private int _compositionCaret;
    private IReadOnlyList<CompositionRun> _compositionRuns = [];
    private bool _disposed;

    public SqlEditor()
    {
        _model = new EditorModel(new TextDocument());
        Attach(_model);
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        Background = new SolidColorBrush(Colors.Transparent);
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _root.Children.Add(_panel);
        Grid.SetColumn(_verticalBar, 1);
        _root.Children.Add(_verticalBar);
        Grid.SetRow(_horizontalBar, 1);
        _root.Children.Add(_horizontalBar);
        Content = _root;

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        _panel.SizeChanged += (_, _) => OnViewResized();
        _panel.CompositionScaleChanged += (_, _) => OnViewResized();
        _verticalBar.ValueChanged += (_, e) => ScrollFromBar(vertical: true, e.NewValue);
        _horizontalBar.ValueChanged += (_, e) => ScrollFromBar(vertical: false, e.NewValue);
        ActualThemeChanged += (_, _) => RebuildBrushes();
        GotFocus += (_, _) => OnFocusChanged(true);
        LostFocus += (_, _) => OnFocusChanged(false);
        CharacterReceived += OnCharacterReceived;
        HookPointer();
    }

    public event EventHandler<EditorFrame>? FramePresented;

    public event EventHandler? TextChanged;

    // The host's own commands for the context menu, added after the editor's each time the menu opens.
    public event EventHandler<IList<MenuFlyoutItemBase>>? ContextMenuOpening;

    public EditorModel Model => _model;

    public TextDocument Document => _model.Document;

    // With the document's own line breaks; setting it clears undo.
    public string Text
    {
        get => Document.ExportText(0, Document.Length);
        set => Document.SetText(value ?? string.Empty);
    }

    public ISyntaxLexer? Lexer
    {
        get => _lexer;
        set
        {
            _lexer = value;
            _highlighter?.Dispose();
            _highlighter = value is null ? null : new SyntaxHighlighter(Document, value);
            ForgetLayouts();
            Invalidate();
        }
    }

    // WARP even when a GPU is there; read once, when the editor loads.
    public bool PreferSoftwareRendering { get; set; }

    public bool IsSoftwareRendering => _device?.IsSoftware ?? false;

    public string AdapterName => _device?.AdapterName ?? string.Empty;

    internal bool HoldsSwapChain => _device?.HasSwapChain == true;

    public bool HasTextServices => _tsf is not null;

    public bool IsComposing => _tsf?.HasActiveComposition == true || _composition.Length > 0;

    public float EditorFontSize
    {
        get => _fontSize;
        set
        {
            _fontSize = value;
            ConfigureLayouts();
            UpdateScrollBars();
            Invalidate();
        }
    }

    public float Zoom
    {
        get => _zoom;
        set
        {
            _zoom = Math.Clamp(value, 0.5f, 3f);
            ConfigureLayouts();
            UpdateScrollBars();
            Invalidate();
        }
    }

    public double LineHeight => _layouts?.LineHeight ?? 0;

    public int FirstVisibleLine => _layouts is null ? 0 : (int)(_scrollY / _layouts.LineHeight);

    public int VisibleLineCount => _layouts is null ? 0 : Math.Max(1, (int)(ViewHeight / _layouts.LineHeight));

    public SyntaxHighlighter? Highlighter => _highlighter;

    // Calls before the next frame give one frame.
    public void Invalidate()
    {
        if (_renderQueued || _disposed)
        {
            return;
        }
        _renderQueued = true;
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Normal, Render);
    }

    // For the gate harness, to time one frame on its own.
    public void RenderNow() => Render();

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Unhook();
        _highlighter?.Dispose();
        ReleaseCaretLayer();
        ReleaseDevice();
        _tsf?.Dispose();
        _tsf = null;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => _peer = new SqlEditorAutomationPeer(this);

    private void Attach(EditorModel model)
    {
        model.Document.Changed += OnDocumentChanged;
        model.Document.Reset += (_, _) => OnDocumentReset();
        model.SelectionsChanged += (_, _) => OnSelectionsChanged();
    }

    private void OnDocumentChanged(object? sender, TextChange change)
    {
        UpdateScrollBars();
        Invalidate();
        TextChanged?.Invoke(this, EventArgs.Empty);
        _peer?.RaiseTextChanged();
    }

    private void OnDocumentReset()
    {
        _scrollX = 0;
        _scrollY = 0;
        _widest = 0;
        ForgetLayouts();
        UpdateScrollBars();
        Invalidate();
        TextChanged?.Invoke(this, EventArgs.Empty);
        _peer?.RaiseTextChanged();
    }

    private void OnSelectionsChanged()
    {
        RestartBlink();
        Invalidate();
        _peer?.RaiseSelectionChanged();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_disposed)
        {
            return;
        }
        // A flyout keeps the window it first opened in (microsoft/microsoft-ui-xaml#10207); a tab can move the editor.
        if (ContextFlyout?.XamlRoot is { } shown && !ReferenceEquals(shown, XamlRoot))
        {
            ContextFlyout = BuildContextMenu();
        }

        _loaded = true;
        // A tab moved to another window can load there before its old window unloads it, still bound to the old one.
        Unhook();
        Hook();
        PrepareDevice();
        AttachSwapChain();
        _tsf ??= TsfInput.Create(new TsfHost(this));
    }

    // TabView unloads a tab's content on every switch; a hidden tab keeps its layouts and brushes.
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        // A tab moved to another window can hear its old window's Unloaded after the new one's Loaded.
        if (IsLoaded)
        {
            return;
        }
        _loaded = false;
        Unhook();
        ClearCarets();
        _device?.Detach();
    }

    private unsafe void PrepareDevice()
    {
        if (_device is null)
        {
            _device = new GraphicsDevice(PreferSoftwareRendering);
            _layouts = new TextLayouts(_device.DWrite, EditorFontSize * _zoom, _model.Options.TabSize);
            RebuildBrushes();
            UpdateScrollBars();
        }
        // ColorValuesChanged is watched only while loaded, so the colors may have changed while the tab was hidden.
        else if (_device.IsCurrent && (_brushes is null || !_brushes.Palette.SameAs(Palette.Resolve(ActualTheme))))
        {
            RebuildBrushes();
        }
    }

    private void AttachSwapChain()
    {
        if (!_loaded || _device is null || _device.HasSwapChain || _panel.ActualWidth < 1 || _panel.ActualHeight < 1)
        {
            return;
        }
        if (_device.NeedsRecovery)
        {
            _device.Recover(lost: false);
            RebuildBrushes();
        }
        try
        {
            _device.Attach(_panel, PixelWidth(), PixelHeight(), _panel.CompositionScaleX, _panel.CompositionScaleY);
        }
        catch (COMException exception) when (GraphicsDevice.IsDeviceLoss(exception.HResult))
        {
            // Lost between the check and the call; a new device takes it.
            _device.Recover(lost: true);
            RebuildBrushes();
            _device.Attach(_panel, PixelWidth(), PixelHeight(), _panel.CompositionScaleX, _panel.CompositionScaleY);
        }
        UpdateScrollBars();
        Invalidate();
    }

    // Brushes are made on the device, and the cached layouts hold them as drawing effects.
    private void RecoverDevice(bool lost)
    {
        _device!.Recover(lost);
        RebuildBrushes();
        AttachSwapChain();
    }

    private void ReleaseDevice()
    {
        _brushes?.Dispose();
        _brushes = null;
        ForgetLayouts();
        _layouts?.Dispose();
        _layouts = null;
        _device?.Dispose();
        _device = null;
    }

    private void OnViewResized()
    {
        if (_device is null || !_device.HasSwapChain)
        {
            AttachSwapChain();
            return;
        }
        // A swap chain on a removed device fails ResizeBuffers; the new one is made at the new size.
        if (_device.NeedsRecovery)
        {
            RecoverDevice(lost: false);
            return;
        }
        try
        {
            _device.Resize(PixelWidth(), PixelHeight(), _panel.CompositionScaleX, _panel.CompositionScaleY);
        }
        catch (COMException exception) when (GraphicsDevice.IsDeviceLoss(exception.HResult))
        {
            RecoverDevice(lost: true);
            return;
        }
        UpdateScrollBars();
        RenderNow();
    }

    private unsafe void RebuildBrushes()
    {
        if (_device is null)
        {
            return;
        }
        _brushes?.Dispose();
        _brushes = new Brushes(_device.Context, Palette.Resolve(ActualTheme));
        if (_caretBrush is not null)
        {
            _caretBrush.Color = _brushes.Palette.Caret;
        }
        ForgetLayouts();
        Invalidate();
    }

    private void OnFocusChanged(bool focused)
    {
        _blink.SetFocused(focused);
        ShowCaretState();
        SyncBlinkTimer();
        if (focused)
        {
            _tsf?.Focus();
        }
        else
        {
            _tsf?.Unfocus();
            _model.Document.Undo.BreakJoin();
        }
    }

    private int PixelWidth() => (int)Math.Ceiling(_panel.ActualWidth * _panel.CompositionScaleX);

    private int PixelHeight() => (int)Math.Ceiling(_panel.ActualHeight * _panel.CompositionScaleY);

    private static long Now() => Stopwatch.GetTimestamp();

    private static double Milliseconds(long from, long to) => (to - from) * 1000.0 / Stopwatch.Frequency;
}
