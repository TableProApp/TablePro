using System.Globalization;
using System.Text;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.App.Helpers;
using TablePro.Core.Geometry;
using TablePro.Core.Results;
using Windows.Foundation;
using Windows.System;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace TablePro.App.Controls;

/// <summary>
/// Draws a result's geometry, or its latitude and longitude columns, on a vector map: shapes only over a degree grid,
/// since the app has no web view and no tile source. Pan by dragging, zoom with the wheel or Ctrl+plus and minus, and a
/// click on a shape selects its row.
/// </summary>
/// <remarks>
/// Polygons and lines are each one <see cref="Path"/> whose geometry is built once per result, off the UI thread, as
/// path markup parsed natively; panning and zooming only change its transform. Points and the grid keep a constant size
/// on screen, so they are rebuilt in screen units when the zoom changes and only shifted while dragging.
/// </remarks>
public sealed partial class ResultMap : UserControl
{
    /// <summary>
    /// XAML geometry costs far more per vertex than MapKit's aggregate overlays, which the macOS budget of 100,000 shapes
    /// and 2,000,000 vertices was measured against, so the canvas takes a smaller allowance and says when it is reached.
    /// </summary>
    private static readonly ShapeBudget DrawingBudget = new(20_000, 400_000);

    private const double PointRadius = 4.5;
    private const double ClickSlop = 6;
    private const double DragThreshold = 4;

    // The frame scene geometry is written in: coordinates relative to the extent's corner, so single-precision rendering
    // keeps sub-pixel detail however far in the map zooms.
    private const double FrameSize = 1000;

    private readonly Canvas _canvas = new();
    private readonly Canvas _labels = new() { IsHitTestVisible = false };
    private readonly Path _graticule = new() { StrokeThickness = 1, IsHitTestVisible = false };
    private readonly Path _polygons = new() { StrokeThickness = 1.25, StrokeLineJoin = PenLineJoin.Round };
    private readonly Path _lines = new() { StrokeThickness = 2, StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly Path _points = new() { StrokeThickness = 1.5 };
    private readonly Path _selectedShapes = new() { StrokeThickness = 3, StrokeLineJoin = PenLineJoin.Round, IsHitTestVisible = false };
    private readonly Path _selectedPoints = new() { StrokeThickness = 2.5, IsHitTestVisible = false };
    private readonly ComboBox _source = new() { MinWidth = 160, Visibility = Visibility.Collapsed };
    private readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Opacity = 0.7 };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 460, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressRing _progress = new() { Width = 24, Height = 24, IsActive = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    private ResultSet? _result;
    private IReadOnlyList<MapSource> _sources = [];
    private string? _preferredSource;
    private CancellationTokenSource? _projection;
    private ScenePaths? _scene;
    private MapView _view = new(256, 0, 0);
    private bool _viewFollowsFit = true;
    private HashSet<int> _selected = [];
    private MatrixTransform _polygonTransform = new();
    private MatrixTransform _lineTransform = new();

    // The view the screen-space layers were last built for; while dragging they are only shifted from it.
    private MapView _builtView;
    private Point? _pressed;
    private MapView _pressedView;
    private bool _dragging;

    public ResultMap()
    {
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        AutomationProperties.SetName(this, "Map");

        _source.SelectionChanged += (_, _) =>
        {
            if (_source.SelectedIndex >= 0 && _source.SelectedIndex < _sources.Count)
            {
                _preferredSource = _sources[_source.SelectedIndex].DisplayName;
                Project();
            }
        };

        var fit = ToolbarButton("", "Fit to result", (_, _) => FitToResult());
        var zoomIn = ToolbarButton("", "Zoom in", (_, _) => ZoomBy(1.5));
        var zoomOut = ToolbarButton("", "Zoom out", (_, _) => ZoomBy(1 / 1.5));

        var toolbar = new Grid { Padding = new Thickness(12, 6, 12, 6), ColumnSpacing = 8 };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        buttons.Children.Add(zoomOut);
        buttons.Children.Add(zoomIn);
        buttons.Children.Add(fit);
        AutomationProperties.SetName(_source, "Map source");
        toolbar.Children.Add(_source);
        Grid.SetColumn(_status, 1);
        toolbar.Children.Add(_status);
        Grid.SetColumn(buttons, 2);
        toolbar.Children.Add(buttons);

        _canvas.Children.Add(_graticule);
        _canvas.Children.Add(_polygons);
        _canvas.Children.Add(_lines);
        _canvas.Children.Add(_points);
        _canvas.Children.Add(_selectedShapes);
        _canvas.Children.Add(_selectedPoints);
        _canvas.Children.Add(_labels);
        _canvas.PointerPressed += OnPointerPressed;
        _canvas.PointerMoved += OnPointerMoved;
        _canvas.PointerReleased += OnPointerReleased;
        _canvas.PointerCaptureLost += (_, _) => EndDrag();
        _canvas.PointerWheelChanged += OnPointerWheelChanged;
        _canvas.SizeChanged += OnCanvasSizeChanged;
        AutomationProperties.SetName(_canvas, "Map");

        var host = new Border { Child = _canvas, BorderThickness = new Thickness(0, 1, 0, 0) };
        var surface = new Grid();
        surface.Children.Add(host);
        surface.Children.Add(_empty);
        surface.Children.Add(_progress);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(toolbar);
        Grid.SetRow(surface, 1);
        root.Children.Add(surface);
        Content = root;

        KeyDown += OnKeyDown;
        ActualThemeChanged += (_, _) => ApplyTheme(host);
        Loaded += (_, _) => ApplyTheme(host);
        Unloaded += (_, _) => _projection?.Cancel();
    }

    /// <summary>The row a click on the map landed on, as an index into <see cref="Result"/>'s rows.</summary>
    public event EventHandler<int>? RowSelected;

    /// <summary>The result to map; null clears the map and stops any projection still running.</summary>
    public ResultSet? Result
    {
        get => _result;
        set
        {
            if (ReferenceEquals(value, _result))
            {
                return;
            }

            _result = value;
            _sources = value is null ? [] : MapSourceDetector.Find(value);
            _source.Items.Clear();
            foreach (var source in _sources)
            {
                _source.Items.Add(source.DisplayName);
            }

            _source.Visibility = _sources.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
            _viewFollowsFit = true;
            _selected = [];

            // The picked source is found again by name, so a re-run that reorders the SELECT list keeps it.
            var index = _preferredSource is null ? -1 : _sources.ToList().FindIndex(s => s.DisplayName == _preferredSource);
            if (_sources.Count > 0)
            {
                // Setting the index raises SelectionChanged, which projects.
                var target = Math.Max(0, index);
                if (_source.SelectedIndex == target)
                {
                    Project();
                }
                else
                {
                    _source.SelectedIndex = target;
                }
            }
            else
            {
                Project();
            }
        }
    }

    /// <summary>Rows to highlight, such as the grid's selection when the map is shown.</summary>
    public IReadOnlyList<int> SelectedRows
    {
        get => [.. _selected];
        set
        {
            _selected = [.. value];
            DrawSelection();
        }
    }

    private MapSource? CurrentSource => _source.SelectedIndex >= 0 && _source.SelectedIndex < _sources.Count ? _sources[_source.SelectedIndex] : null;

    private static Button ToolbarButton(string glyph, string name, RoutedEventHandler click)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            Padding = new Thickness(8, 5, 8, 5),
            Background = null,
            BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        button.Click += click;
        return button;
    }

    private void ApplyTheme(Border host)
    {
        var accent = ThemeResources.Brush(this, "AccentFillColorDefaultBrush");
        var accentColor = accent is SolidColorBrush solid ? solid.Color : ThemeResources.Color(this, "SystemAccentColor");
        _canvas.Background = ThemeResources.Brush(this, "CardBackgroundFillColorSecondaryBrush");
        host.BorderBrush = ThemeResources.Brush(this, "DividerStrokeColorDefaultBrush");
        _graticule.Stroke = ThemeResources.Brush(this, "DividerStrokeColorDefaultBrush");

        // The fill is the accent made translucent so overlapping polygons and the grid beneath stay readable; a brush
        // of its own, because changing the opacity of the shared theme brush would change it everywhere.
        _polygons.Fill = new SolidColorBrush(accentColor) { Opacity = 0.28 };
        _polygons.Stroke = accent;
        _lines.Stroke = accent;
        _points.Fill = accent;
        _points.Stroke = ThemeResources.Brush(this, "SolidBackgroundFillColorBaseBrush");
        _selectedShapes.Stroke = ThemeResources.Brush(this, "TextFillColorPrimaryBrush");
        _selectedPoints.Stroke = ThemeResources.Brush(this, "TextFillColorPrimaryBrush");
        _selectedPoints.Fill = accent;
        _empty.Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush");
        RebuildScreenLayers();
    }

    private async void Project()
    {
        _projection?.Cancel();
        _projection = null;
        var result = _result;
        var source = CurrentSource;
        if (result is null || source is null)
        {
            Show(null, result is null ? string.Empty : "A map needs a geometry column, or latitude and longitude columns. This result has none.");
            return;
        }

        if (result.RowCount == 0)
        {
            Show(null, "Run a query to map its rows.");
            return;
        }

        using var cancellation = new CancellationTokenSource();
        _projection = cancellation;
        var token = cancellation.Token;
        _progress.IsActive = true;
        _empty.Text = string.Empty;
        try
        {
            var scene = await Task.Run(() => ScenePaths.Build(result, source, DrawingBudget, token), token);
            if (!token.IsCancellationRequested)
            {
                Show(scene, scene.Projection.IsEmpty ? scene.Projection.Diagnostics.EmptyReason : null);
            }
        }
        catch (OperationCanceledException)
        {
            // A newer result or source replaced this one, which shows its own state.
        }
        finally
        {
            if (ReferenceEquals(_projection, cancellation))
            {
                _projection = null;
                _progress.IsActive = false;
            }
        }
    }

    private void Show(ScenePaths? scene, string? emptyReason)
    {
        _scene = scene;
        _progress.IsActive = false;
        _empty.Text = emptyReason ?? string.Empty;
        _empty.Visibility = string.IsNullOrEmpty(emptyReason) ? Visibility.Collapsed : Visibility.Visible;
        _status.Text = scene?.Projection.Diagnostics.StatusText ?? string.Empty;
        ToolTipService.SetToolTip(_status, string.IsNullOrEmpty(_status.Text) ? null : _status.Text);
        // Each geometry keeps one transform for its life, so a pan only rewrites a matrix rather than allocating.
        _polygons.Data = ParseGeometry(scene?.PolygonMarkup);
        _lines.Data = ParseGeometry(scene?.LineMarkup);
        _polygonTransform = new MatrixTransform();
        _lineTransform = new MatrixTransform();
        if (_polygons.Data is { } polygons)
        {
            polygons.Transform = _polygonTransform;
        }

        if (_lines.Data is { } lines)
        {
            lines.Transform = _lineTransform;
        }
        var diagnostics = scene?.Projection.Diagnostics;
        AutomationProperties.SetName(_canvas, diagnostics is null
            ? "Map"
            : string.Create(CultureInfo.CurrentCulture, $"Map of {diagnostics.DrawnShapes:N0} shapes from {diagnostics.DrawnRows:N0} rows"));
        if (_viewFollowsFit)
        {
            FitToResult();
        }
        else
        {
            ApplyView(_view);
        }
    }

    private static Microsoft.UI.Xaml.Media.Geometry? ParseGeometry(string? markup) =>
        string.IsNullOrEmpty(markup) ? null : (Microsoft.UI.Xaml.Media.Geometry)XamlBindingHelper.ConvertValue(typeof(Microsoft.UI.Xaml.Media.Geometry), markup);

    private void FitToResult()
    {
        _viewFollowsFit = true;
        var extent = _scene?.Scene.Extent ?? WorldRect.None;
        ApplyView(MapView.Fit(extent, _canvas.ActualWidth, _canvas.ActualHeight));
    }

    private void ZoomBy(double factor) => ApplyView(_view.ZoomAt(factor, _canvas.ActualWidth / 2, _canvas.ActualHeight / 2), userMoved: true);

    private void ApplyView(MapView view, bool userMoved = false)
    {
        if (userMoved)
        {
            _viewFollowsFit = false;
        }

        _view = view;
        UpdateSceneTransforms();
        RebuildScreenLayers();
    }

    /// <summary>Maps the scene frame onto the screen: frame units to world, then world to pixels.</summary>
    private void UpdateSceneTransforms()
    {
        if (_scene is not { } scene)
        {
            return;
        }

        var unit = scene.FrameScale * _view.Scale;
        var matrix = new Matrix(unit, 0, 0, unit, (scene.Origin.X * _view.Scale) + _view.OffsetX, (scene.Origin.Y * _view.Scale) + _view.OffsetY);
        _polygonTransform.Matrix = matrix;
        _lineTransform.Matrix = matrix;
    }

    /// <summary>The layers drawn in screen units: points, the selection and the degree grid.</summary>
    private void RebuildScreenLayers()
    {
        _builtView = _view;
        _points.RenderTransform = _graticule.RenderTransform = _labels.RenderTransform = _selectedPoints.RenderTransform = _selectedShapes.RenderTransform = null;
        _canvas.Clip = new RectangleGeometry { Rect = new Rect(0, 0, Math.Max(0, _canvas.ActualWidth), Math.Max(0, _canvas.ActualHeight)) };
        DrawGraticule();
        _points.Data = _scene is { } scene ? ParseGeometry(PointMarkup(scene.Scene.Points)) : null;
        DrawSelection();
    }

    private void DrawSelection()
    {
        if (_scene is not { } scene || _selected.Count == 0)
        {
            _selectedShapes.Data = null;
            _selectedPoints.Data = null;
            return;
        }

        var shapes = new StringBuilder();
        var points = new List<MapSceneShape>();
        foreach (var row in _selected)
        {
            if (!scene.ShapesByRow.TryGetValue(row, out var owned))
            {
                continue;
            }

            foreach (var shape in owned)
            {
                if (shape.Kind == MapShapeKind.Point)
                {
                    points.Add(shape);
                }
                else
                {
                    // Few shapes are ever selected, so their outline is written in screen units each time.
                    foreach (var ring in shape.Rings)
                    {
                        AppendRun(shapes, ring, shape.Kind == MapShapeKind.Polygon, _view);
                    }
                }
            }
        }

        _selectedShapes.Data = ParseGeometry(shapes.ToString());
        _selectedPoints.Data = ParseGeometry(PointMarkup(points, PointRadius + 1.5));
    }

    private string PointMarkup(IReadOnlyList<MapSceneShape> points, double radius = PointRadius)
    {
        if (points.Count == 0)
        {
            return string.Empty;
        }

        var markup = new StringBuilder(Math.Min(points.Count, 4096) * 64);
        var width = _canvas.ActualWidth;
        var height = _canvas.ActualHeight;
        foreach (var point in points)
        {
            var (x, y) = _view.ToScreen(point.Rings[0][0], point.Rings[0][1]);

            // Points off screen are left out: a whole result of points would otherwise be re-parsed on every zoom.
            if (x < -radius || y < -radius || x > width + radius || y > height + radius)
            {
                continue;
            }

            markup.Append(CultureInfo.InvariantCulture, $"M{x - radius:0.##},{y:0.##}A{radius},{radius} 0 1 0 {x + radius:0.##},{y:0.##}A{radius},{radius} 0 1 0 {x - radius:0.##},{y:0.##}Z");
        }

        return markup.ToString();
    }

    private static void AppendRun(StringBuilder markup, double[] ring, bool closed, MapView view)
    {
        for (var i = 0; i < ring.Length; i += 2)
        {
            var (x, y) = view.ToScreen(ring[i], ring[i + 1]);
            markup.Append(CultureInfo.InvariantCulture, $"{(i == 0 ? 'M' : 'L')}{x:0.##},{y:0.##} ");
        }

        if (closed)
        {
            markup.Append('Z');
        }
    }

    /// <summary>
    /// Meridians and parallels at a round step that leaves a handful of lines on screen, with degree labels on the left
    /// and bottom edges, so a reader can tell where on Earth the shapes are without a tile layer.
    /// </summary>
    private void DrawGraticule()
    {
        _labels.Children.Clear();
        var width = _canvas.ActualWidth;
        var height = _canvas.ActualHeight;
        if (width < 1 || height < 1)
        {
            _graticule.Data = null;
            return;
        }

        var (left, top) = _view.ToWorld(0, 0);
        var (right, bottom) = _view.ToWorld(width, height);
        left = Math.Clamp(left, 0, 1);
        right = Math.Clamp(right, 0, 1);
        top = Math.Clamp(top, 0, 1);
        bottom = Math.Clamp(bottom, 0, 1);
        var west = WebMercator.FromWorld(left, top).Longitude;
        var east = WebMercator.FromWorld(right, top).Longitude;
        var north = WebMercator.FromWorld(left, top).Latitude;
        var south = WebMercator.FromWorld(left, bottom).Latitude;
        var lonStep = GridStep(east - west, (right - left) * _view.Scale);
        var latStep = GridStep(north - south, (bottom - top) * _view.Scale);
        var brush = ThemeResources.Brush(this, "TextFillColorTertiaryBrush");
        var markup = new StringBuilder(1024);

        // The world's edge, so panning past it is visible.
        var (x0, y0) = _view.ToScreen(0, 0);
        var (x1, y1) = _view.ToScreen(1, 1);
        markup.Append(CultureInfo.InvariantCulture, $"M{x0:0.#},{y0:0.#}L{x1:0.#},{y0:0.#}L{x1:0.#},{y1:0.#}L{x0:0.#},{y1:0.#}Z ");

        var yTop = Math.Max(0, y0);
        var yBottom = Math.Min(height, y1);
        // Multiples of the step by index rather than by repeated addition, which drifts at small steps.
        for (var k = Math.Ceiling(west / lonStep); k * lonStep <= east; k++)
        {
            var longitude = k * lonStep;
            var (x, _) = _view.ToScreen(WebMercator.ToWorld(new GeographicCoordinate(longitude, 0)).X, 0);
            markup.Append(CultureInfo.InvariantCulture, $"M{x:0.#},{yTop:0.#}L{x:0.#},{yBottom:0.#} ");
            AddLabel(Degrees(longitude, lonStep, 'E', 'W'), x + 3, yBottom - 16, brush);
        }

        var xLeft = Math.Max(0, x0);
        var xRight = Math.Min(width, x1);
        for (var k = Math.Ceiling(south / latStep); k * latStep <= north; k++)
        {
            var latitude = k * latStep;
            if (Math.Abs(latitude) > WebMercator.MaximumLatitude)
            {
                continue;
            }

            var (_, y) = _view.ToScreen(0, WebMercator.ToWorld(new GeographicCoordinate(0, latitude)).Y);
            markup.Append(CultureInfo.InvariantCulture, $"M{xLeft:0.#},{y:0.#}L{xRight:0.#},{y:0.#} ");
            AddLabel(Degrees(latitude, latStep, 'N', 'S'), xLeft + 4, y - 15, brush);
        }

        _graticule.Data = ParseGeometry(markup.ToString());
    }

    /// <summary>The finest round step that keeps grid lines at least about a hundred pixels apart along one axis.</summary>
    private static double GridStep(double degrees, double pixels)
    {
        ReadOnlySpan<double> steps = [0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 45, 90];
        if (degrees <= 0 || pixels <= 0)
        {
            return steps[^1];
        }

        foreach (var step in steps)
        {
            if (step / degrees * pixels >= 100)
            {
                return step;
            }
        }

        return steps[^1];
    }

    private static string Degrees(double value, double step, char positive, char negative)
    {
        var decimals = step >= 1 ? 0 : (int)Math.Ceiling(-Math.Log10(step));
        var rounded = Math.Round(value, decimals);
        var text = Math.Abs(rounded).ToString("F" + decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.CurrentCulture);
        return rounded == 0 ? text + "°" : text + "°" + (rounded > 0 ? positive : negative);
    }

    private void AddLabel(string text, double x, double y, Brush brush)
    {
        var block = new TextBlock { Text = text, FontSize = 10, Foreground = brush };
        Canvas.SetLeft(block, x);
        Canvas.SetTop(block, y);
        _labels.Children.Add(block);
    }

    private void OnCanvasSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_viewFollowsFit)
        {
            FitToResult();
        }
        else
        {
            // Keeps the centre where it was rather than the top-left corner.
            ApplyView(_view.Pan((e.NewSize.Width - e.PreviousSize.Width) / 2, (e.NewSize.Height - e.PreviousSize.Height) / 2));
        }
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Focus(FocusState.Pointer);
        var point = e.GetCurrentPoint(_canvas);
        if (!point.Properties.IsLeftButtonPressed && point.PointerDeviceType == PointerDeviceType.Mouse)
        {
            return;
        }

        _pressed = point.Position;
        _pressedView = _view;
        _dragging = false;
        _canvas.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_pressed is not { } start)
        {
            return;
        }

        var position = e.GetCurrentPoint(_canvas).Position;
        var dx = position.X - start.X;
        var dy = position.Y - start.Y;
        if (!_dragging && (dx * dx) + (dy * dy) < DragThreshold * DragThreshold)
        {
            return;
        }

        _dragging = true;
        _viewFollowsFit = false;
        _view = _pressedView.Pan(dx, dy);
        UpdateSceneTransforms();

        // Screen-space layers are shifted rather than rebuilt while the pointer moves, and rebuilt when it lets go.
        var shift = new TranslateTransform { X = _view.OffsetX - _builtView.OffsetX, Y = _view.OffsetY - _builtView.OffsetY };
        _points.RenderTransform = shift;
        _graticule.RenderTransform = new TranslateTransform { X = shift.X, Y = shift.Y };
        _labels.RenderTransform = new TranslateTransform { X = shift.X, Y = shift.Y };
        _selectedPoints.RenderTransform = new TranslateTransform { X = shift.X, Y = shift.Y };
        _selectedShapes.RenderTransform = new TranslateTransform { X = shift.X, Y = shift.Y };
        e.Handled = true;
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_pressed is null)
        {
            return;
        }

        var wasDrag = _dragging;
        var position = e.GetCurrentPoint(_canvas).Position;
        _canvas.ReleasePointerCapture(e.Pointer);
        EndDrag();
        if (!wasDrag)
        {
            SelectAt(position);
        }

        e.Handled = true;
    }

    private void EndDrag()
    {
        var wasDragging = _dragging;
        _pressed = null;
        _dragging = false;
        if (wasDragging)
        {
            RebuildScreenLayers();
        }
    }

    private void SelectAt(Point position)
    {
        if (_scene is not { } scene)
        {
            return;
        }

        var (x, y) = _view.ToWorld(position.X, position.Y);
        var row = scene.Scene.HitTest(x, y, ClickSlop / _view.Scale);
        _selected = row >= 0 ? [row] : [];
        DrawSelection();
        if (row >= 0)
        {
            RowSelected?.Invoke(this, row);
        }
    }

    private void OnPointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_canvas);
        var delta = point.Properties.MouseWheelDelta;
        if (delta == 0)
        {
            return;
        }

        // 120 is one notch of a standard wheel, a fifth more or less per notch; precision touchpads send smaller deltas.
        ApplyView(_view.ZoomAt(Math.Pow(1.2, delta / 120.0), point.Position.X, point.Position.Y), userMoved: true);
        e.Handled = true;
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        const double pan = 80;
        switch (e.Key)
        {
            case VirtualKey.Add or (VirtualKey)187:
                ZoomBy(1.5);
                break;
            case VirtualKey.Subtract or (VirtualKey)189:
                ZoomBy(1 / 1.5);
                break;
            case VirtualKey.Left:
                ApplyView(_view.Pan(pan, 0), userMoved: true);
                break;
            case VirtualKey.Right:
                ApplyView(_view.Pan(-pan, 0), userMoved: true);
                break;
            case VirtualKey.Up:
                ApplyView(_view.Pan(0, pan), userMoved: true);
                break;
            case VirtualKey.Down:
                ApplyView(_view.Pan(0, -pan), userMoved: true);
                break;
            case VirtualKey.Home or VirtualKey.Number0:
                FitToResult();
                break;
            default:
                return;
        }

        e.Handled = true;
    }

    /// <summary>A projection with its scene, its path markup and its shapes by row, all built off the UI thread.</summary>
    private sealed class ScenePaths
    {
        private ScenePaths(ResultMapProjection projection, MapScene scene, (double X, double Y) origin, double frameScale, string polygons, string lines, Dictionary<int, List<MapSceneShape>> byRow)
        {
            Projection = projection;
            Scene = scene;
            Origin = origin;
            FrameScale = frameScale;
            PolygonMarkup = polygons;
            LineMarkup = lines;
            ShapesByRow = byRow;
        }

        public ResultMapProjection Projection { get; }

        public MapScene Scene { get; }

        /// <summary>The world point the frame's zero sits on.</summary>
        public (double X, double Y) Origin { get; }

        /// <summary>World units per frame unit.</summary>
        public double FrameScale { get; }

        public string PolygonMarkup { get; }

        public string LineMarkup { get; }

        public Dictionary<int, List<MapSceneShape>> ShapesByRow { get; }

        public static ScenePaths Build(ResultSet result, MapSource source, ShapeBudget budget, CancellationToken token)
        {
            var projection = ResultMapProjector.Project(result, source, budget, null, token);
            var scene = MapScene.Build(projection, token);
            var extent = scene.Extent;
            var origin = extent.IsNone ? (0d, 0d) : (extent.Left, extent.Top);
            var size = extent.IsNone ? 1 : Math.Max(Math.Max(extent.Width, extent.Height), 1e-12);
            var frameScale = size / FrameSize;

            // F0 is the even-odd fill rule: a hole often winds the same way as its exterior, and non-zero would fill it.
            var polygons = new StringBuilder("F0 ");
            foreach (var shape in scene.Polygons)
            {
                token.ThrowIfCancellationRequested();
                foreach (var ring in shape.Rings)
                {
                    AppendFrameRun(polygons, ring, origin, frameScale, closed: true);
                }
            }

            var lines = new StringBuilder();
            foreach (var shape in scene.Lines)
            {
                token.ThrowIfCancellationRequested();
                AppendFrameRun(lines, shape.Rings[0], origin, frameScale, closed: false);
            }

            var byRow = new Dictionary<int, List<MapSceneShape>>();
            foreach (var list in (ReadOnlySpan<IReadOnlyList<MapSceneShape>>)[scene.Polygons, scene.Lines, scene.Points])
            {
                foreach (var shape in list)
                {
                    if (!byRow.TryGetValue(shape.Row, out var owned))
                    {
                        byRow[shape.Row] = owned = [];
                    }

                    owned.Add(shape);
                }
            }

            return new ScenePaths(projection, scene, origin, frameScale, scene.Polygons.Count > 0 ? polygons.ToString() : string.Empty, lines.ToString(), byRow);
        }

        private static void AppendFrameRun(StringBuilder markup, double[] ring, (double X, double Y) origin, double frameScale, bool closed)
        {
            for (var i = 0; i < ring.Length; i += 2)
            {
                var x = (ring[i] - origin.X) / frameScale;
                var y = (ring[i + 1] - origin.Y) / frameScale;
                markup.Append(CultureInfo.InvariantCulture, $"{(i == 0 ? 'M' : 'L')}{x:0.####},{y:0.####} ");
            }

            if (closed)
            {
                markup.Append("Z ");
            }
        }
    }
}
