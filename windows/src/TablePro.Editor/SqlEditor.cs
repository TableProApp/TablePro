using System.Diagnostics;
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
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Editor;

// What one presented frame cost, for the gate harness and later for a debug overlay.
public readonly record struct EditorFrame(
    long PresentedAt,
    double RenderMilliseconds,
    double LexMilliseconds,
    long DocumentVersion,
    int FirstLine,
    int LastLine,
    int LayoutsCreated,
    bool Software);

// The SQL editor: TablePro's own text control over the EditorModel, drawn with Direct2D and DirectWrite into a
// SwapChainPanel, with TSF for input methods and a UIA text provider. windows/docs/decisions/0002-sql-editor-control.md
// has the design.
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
    private DispatcherQueueTimer? _blinkTimer;
    private FindBar? _findBar;
    private SqlEditorAutomationPeer? _peer;
    private bool _renderQueued;
    private bool _caretOn = true;
    private bool _focused;
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
        // AccessibilitySettings.HighContrastChanged needs a CoreWindow (0x80070490 in a desktop app);
        // UISettings raises this one for contrast themes too, off the UI thread.
        _uiSettings.ColorValuesChanged += (_, _) => DispatcherQueue.TryEnqueue(RebuildBrushes);
        GotFocus += (_, _) => OnFocusChanged(true);
        LostFocus += (_, _) => OnFocusChanged(false);
        CharacterReceived += OnCharacterReceived;
        HookPointer();
    }

    public event EventHandler<EditorFrame>? FramePresented;

    public event EventHandler? TextChanged;

    public EditorModel Model => _model;

    public TextDocument Document => _model.Document;

    // The text with the document's own line breaks. Setting it clears undo.
    public string Text
    {
        get => Document.ExportText(0, Document.Length);
        set => Document.SetText(value ?? string.Empty);
    }

    // The lexer that colors the text; null leaves it plain. A later slice swaps in the connection's grammar.
    public ISyntaxLexer? Lexer
    {
        get => _lexer;
        set
        {
            _lexer = value;
            _highlighter?.Dispose();
            _highlighter = value is null ? null : new SyntaxHighlighter(Document, value);
            _layouts?.Clear();
            Invalidate();
        }
    }

    // Draws with WARP even when a GPU is there. Read when the editor loads.
    public bool PreferSoftwareRendering { get; set; }

    public bool IsSoftwareRendering => _device?.IsSoftware ?? false;

    public string AdapterName => _device?.AdapterName ?? string.Empty;

    public bool HasTextServices => _tsf is not null;

    public bool IsComposing => _tsf?.HasActiveComposition == true || _composition.Length > 0;

    public float EditorFontSize { get; set; } = DefaultFontSize;

    public float Zoom
    {
        get => _zoom;
        set
        {
            _zoom = Math.Clamp(value, 0.5f, 3f);
            _layouts?.Configure(EditorFontSize * _zoom, _model.Options.TabSize);
            UpdateScrollBars();
            Invalidate();
        }
    }

    public double LineHeight => _layouts?.LineHeight ?? 0;

    public int FirstVisibleLine => _layouts is null ? 0 : (int)(_scrollY / _layouts.LineHeight);

    public int VisibleLineCount => _layouts is null ? 0 : Math.Max(1, (int)(ViewHeight / _layouts.LineHeight));

    public SyntaxHighlighter? Highlighter => _highlighter;

    // Redraws soon. Many calls before the frame give one frame.
    public void Invalidate()
    {
        if (_renderQueued || _disposed)
        {
            return;
        }
        _renderQueued = true;
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Normal, Render);
    }

    // Draws now. The gate harness calls it to time one frame on its own.
    public void RenderNow() => Render();

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _highlighter?.Dispose();
        ReleaseDevice();
        _tsf?.Dispose();
        _tsf = null;
        _blinkTimer?.Stop();
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
        _layouts?.Clear();
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
        CreateDevice();
        _tsf ??= TsfInput.Create(new TsfHost(this));
        var blink = GetCaretBlinkTime();
        if (_blinkTimer is null && blink is > 0 and < uint.MaxValue)
        {
            _blinkTimer = DispatcherQueue.CreateTimer();
            _blinkTimer.Interval = TimeSpan.FromMilliseconds(blink);
            _blinkTimer.Tick += (_, _) =>
            {
                _caretOn = !_caretOn;
                Invalidate();
            };
        }
        if (_focused)
        {
            _blinkTimer?.Start();
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _blinkTimer?.Stop();
        ReleaseDevice();
    }

    private unsafe void CreateDevice()
    {
        if (_device is not null || _panel.ActualWidth < 1 || _panel.ActualHeight < 1)
        {
            return;
        }
        _device = new GraphicsDevice(PreferSoftwareRendering);
        _layouts = new TextLayouts(_device.DWrite, EditorFontSize * _zoom, _model.Options.TabSize);
        _device.Attach(_panel, PixelWidth(), PixelHeight(), _panel.CompositionScaleX, _panel.CompositionScaleY);
        RebuildBrushes();
        UpdateScrollBars();
        Invalidate();
    }

    private void ReleaseDevice()
    {
        _brushes?.Dispose();
        _brushes = null;
        _layouts?.Dispose();
        _layouts = null;
        _device?.Dispose();
        _device = null;
    }

    private void OnViewResized()
    {
        if (_device is null)
        {
            CreateDevice();
            return;
        }
        _device.Resize(PixelWidth(), PixelHeight(), _panel.CompositionScaleX, _panel.CompositionScaleY);
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
        _layouts?.Clear();
        Invalidate();
    }

    private void OnFocusChanged(bool focused)
    {
        _focused = focused;
        if (focused)
        {
            _tsf?.Focus();
            RestartBlink();
        }
        else
        {
            _tsf?.Unfocus();
            _blinkTimer?.Stop();
            _model.Document.Undo.BreakJoin();
        }
        Invalidate();
    }

    private void RestartBlink()
    {
        _caretOn = true;
        if (_blinkTimer is not null && _focused)
        {
            _blinkTimer.Stop();
            _blinkTimer.Start();
        }
    }

    private int PixelWidth() => (int)Math.Ceiling(_panel.ActualWidth * _panel.CompositionScaleX);

    private int PixelHeight() => (int)Math.Ceiling(_panel.ActualHeight * _panel.CompositionScaleY);

    private static long Now() => Stopwatch.GetTimestamp();

    private static double Milliseconds(long from, long to) => (to - from) * 1000.0 / Stopwatch.Frequency;
}
