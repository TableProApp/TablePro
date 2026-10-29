using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.App.Helpers;
using TablePro.Core.Results;
using Windows.Foundation;

namespace TablePro.App.Controls;

public enum ChartKind
{
    Bar,
    Line,
    Area,
}

/// <summary>
/// Charts a result: one column for the categories and up to three numeric columns as series. It draws with shapes on a
/// canvas in the theme's accent palette and redraws on resize; past <see cref="MaxPoints"/> rows it charts the first ones
/// and says so.
/// </summary>
public sealed partial class ResultChart : UserControl
{
    public const int MaxPoints = 500;

    private readonly Canvas _canvas = new();
    private readonly ComboBox _kind = new() { MinWidth = 110 };
    private readonly ComboBox _category = new() { MinWidth = 160, Header = null };
    private readonly ComboBox _series = new() { MinWidth = 160 };
    private readonly TextBlock _note = new() { VerticalAlignment = VerticalAlignment.Center, Opacity = 0.7 };
    private ResultSet? _result;

    public ResultChart()
    {
        foreach (var kind in Enum.GetValues<ChartKind>())
        {
            _kind.Items.Add(KindName(kind));
        }

        _kind.SelectedIndex = 0;
        _kind.SelectionChanged += (_, _) => Draw();
        _category.SelectionChanged += (_, _) => Draw();
        _series.SelectionChanged += (_, _) => Draw();

        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(12, 6, 12, 6) };
        toolbar.Children.Add(new TextBlock { Text = Strings.Get("Results/ChartLead"), VerticalAlignment = VerticalAlignment.Center });
        toolbar.Children.Add(_kind);
        toolbar.Children.Add(new TextBlock { Text = Strings.Get("Results/ChartOf"), VerticalAlignment = VerticalAlignment.Center });
        toolbar.Children.Add(_series);
        toolbar.Children.Add(new TextBlock { Text = Strings.Get("Results/ChartBy"), VerticalAlignment = VerticalAlignment.Center });
        toolbar.Children.Add(_category);
        toolbar.Children.Add(_note);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(toolbar);
        var host = new Border { Child = _canvas, Margin = new Thickness(12, 0, 12, 12) };
        Grid.SetRow(host, 1);
        root.Children.Add(host);
        host.SizeChanged += (_, _) => Draw();
        Content = root;
        ActualThemeChanged += (_, _) => Draw();
    }

    public ResultSet? Result
    {
        get => _result;
        set
        {
            _result = value;
            _category.Items.Clear();
            _series.Items.Clear();
            if (value is null)
            {
                Draw();
                return;
            }

            foreach (var column in value.Columns)
            {
                _category.Items.Add(column.Name);
                if (column.IsNumeric)
                {
                    _series.Items.Add(column.Name);
                }
            }

            _series.Items.Add(Strings.Get("Results/ChartAllNumericColumns"));
            var firstText = value.Columns.ToList().FindIndex(c => !c.IsNumeric);
            _category.SelectedIndex = Math.Max(0, firstText);
            _series.SelectedIndex = _series.Items.Count > 1 ? 0 : -1;
            Draw();
        }
    }

    public bool CanChart => _result is not null && _result.Columns.Any(c => c.IsNumeric) && _result.RowCount > 0;

    private void Draw()
    {
        _canvas.Children.Clear();
        var width = _canvas.ActualWidth > 0 ? _canvas.ActualWidth : ((FrameworkElement)_canvas.Parent).ActualWidth;
        var height = ((FrameworkElement)_canvas.Parent).ActualHeight;
        if (_result is null || !CanChart || width < 80 || height < 80 || _category.SelectedIndex < 0 || _series.SelectedIndex < 0)
        {
            _note.Text = _result is not null && !CanChart ? Strings.Get("Results/ChartNoNumericColumn") : string.Empty;
            return;
        }

        var categoryIndex = _category.SelectedIndex;
        // The "all numeric columns" entry is always last, so the index tells it from a column that happens to share its text.
        var seriesNames = _series.SelectedIndex == _series.Items.Count - 1
            ? _result.Columns.Where(c => c.IsNumeric).Select(c => c.Name).Take(3).ToArray()
            : [(string)_series.SelectedItem];
        var seriesIndexes = seriesNames.Select(_result.ColumnIndex).ToArray();
        var count = Math.Min(_result.RowCount, MaxPoints);
        _note.Text = _result.RowCount > MaxPoints ? Strings.Plural("Results/ChartFirstRows", _result.RowCount, MaxPoints) : string.Empty;

        var values = new double[seriesIndexes.Length][];
        var max = 0d;
        var min = 0d;
        for (var s = 0; s < seriesIndexes.Length; s++)
        {
            values[s] = new double[count];
            for (var r = 0; r < count; r++)
            {
                var v = ToDouble(_result[r, seriesIndexes[s]]);
                values[s][r] = v;
                max = Math.Max(max, v);
                min = Math.Min(min, v);
            }
        }

        if (max == min)
        {
            max = min + 1;
        }

        const double left = 64;
        const double bottom = 36;
        var plotWidth = width - left - 12;
        var plotHeight = height - bottom - 12;
        var text = ThemeResources.Brush(this, "TextFillColorSecondaryBrush");
        var line = ThemeResources.Brush(this, "DividerStrokeColorDefaultBrush");
        var palette = new[]
        {
            ThemeResources.Brush(this, "AccentFillColorDefaultBrush"),
            ThemeResources.Brush(this, "SystemFillColorSuccessBrush"),
            ThemeResources.Brush(this, "SystemFillColorCautionBrush"),
        };

        double Y(double v) => 12 + (plotHeight * (1 - ((v - min) / (max - min))));
        var zero = Y(0);

        for (var tick = 0; tick <= 4; tick++)
        {
            var v = min + ((max - min) * tick / 4);
            var y = Y(v);
            _canvas.Children.Add(new Line { X1 = left, X2 = left + plotWidth, Y1 = y, Y2 = y, Stroke = line, StrokeThickness = 1 });
            AddText(Compact(v), 4, y - 8, text, left - 10, TextAlignment.Right);
        }

        var slot = plotWidth / count;
        var kind = (ChartKind)Math.Max(0, _kind.SelectedIndex);
        for (var s = 0; s < values.Length; s++)
        {
            var brush = palette[s % palette.Length];
            if (kind == ChartKind.Bar)
            {
                var barWidth = Math.Max(1, (slot * 0.8) / values.Length);
                for (var r = 0; r < count; r++)
                {
                    var y = Y(values[s][r]);
                    var bar = new Rectangle { Width = barWidth, Height = Math.Max(1, Math.Abs(zero - y)), Fill = brush, RadiusX = 2, RadiusY = 2 };
                    ToolTipService.SetToolTip(bar, Strings.Format("Results/ChartBarTooltip", Label(r, categoryIndex), values[s][r]));
                    Canvas.SetLeft(bar, left + (r * slot) + (slot * 0.1) + (s * barWidth));
                    Canvas.SetTop(bar, Math.Min(zero, y));
                    _canvas.Children.Add(bar);
                }
            }
            else
            {
                var points = new PointCollection();
                for (var r = 0; r < count; r++)
                {
                    points.Add(new Point(left + (r * slot) + (slot / 2), Y(values[s][r])));
                }

                if (kind == ChartKind.Area && points.Count > 0)
                {
                    var area = new PointCollection { new Point(points[0].X, zero) };
                    foreach (var point in points)
                    {
                        area.Add(point);
                    }

                    area.Add(new Point(points[^1].X, zero));
                    _canvas.Children.Add(new Polygon { Points = area, Fill = brush, Opacity = 0.25 });
                }

                _canvas.Children.Add(new Polyline { Points = points, Stroke = brush, StrokeThickness = 2, StrokeLineJoin = PenLineJoin.Round });
            }
        }

        // Category labels, thinned so they never overlap.
        var every = Math.Max(1, (int)Math.Ceiling(count / Math.Max(1, plotWidth / 90)));
        for (var r = 0; r < count; r += every)
        {
            AddText(Label(r, categoryIndex), left + (r * slot), 12 + plotHeight + 8, text, Math.Max(40, slot * every), TextAlignment.Left);
        }

        for (var s = 0; s < seriesNames.Length; s++)
        {
            var swatch = new Rectangle { Width = 10, Height = 10, Fill = palette[s % palette.Length], RadiusX = 2, RadiusY = 2 };
            Canvas.SetLeft(swatch, left + 8 + (s * 140));
            Canvas.SetTop(swatch, 0);
            _canvas.Children.Add(swatch);
            AddText(seriesNames[s], left + 22 + (s * 140), -4, text, 120, TextAlignment.Left);
        }
    }

    private static string KindName(ChartKind kind) => kind switch
    {
        ChartKind.Bar => Strings.Get("Results/ChartKindBar"),
        ChartKind.Line => Strings.Get("Results/ChartKindLine"),
        _ => Strings.Get("Results/ChartKindArea"),
    };

    private string Label(int row, int column) => CellFormatter.FormatForCell(_result![row, column]);

    private void AddText(string value, double x, double y, Brush brush, double width, TextAlignment alignment)
    {
        var block = new TextBlock { Text = value, FontSize = 11, Foreground = brush, Width = width, TextAlignment = alignment, TextTrimming = TextTrimming.CharacterEllipsis };
        Canvas.SetLeft(block, x);
        Canvas.SetTop(block, y);
        _canvas.Children.Add(block);
    }

    private static double ToDouble(object? value)
    {
        try
        {
            return value switch
            {
                null => 0,
                System.Numerics.BigInteger big => (double)big,
                IConvertible convertible => convertible.ToDouble(CultureInfo.InvariantCulture),
                _ => 0,
            };
        }
        catch (Exception ex) when (ex is FormatException or InvalidCastException or OverflowException)
        {
            // A value that is not a number plots as zero rather than stopping the chart.
            return 0;
        }
    }

    private static string Compact(double value) => Math.Abs(value) switch
    {
        >= 1e9 => (value / 1e9).ToString("0.#", CultureInfo.CurrentCulture) + "B",
        >= 1e6 => (value / 1e6).ToString("0.#", CultureInfo.CurrentCulture) + "M",
        >= 1e4 => (value / 1e3).ToString("0.#", CultureInfo.CurrentCulture) + "K",
        _ => value.ToString("0.##", CultureInfo.CurrentCulture),
    };
}
