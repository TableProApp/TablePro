using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.App.Helpers;
using TablePro.App.ViewModels;
using TablePro.Core.Schema;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace TablePro.App.Views;

/// <summary>
/// Draws the schema as cards on a zoomable canvas, laid out in columns by how many tables reference each one, with
/// a curve per foreign key. Cards can be dragged; their curves follow.
/// </summary>
public sealed partial class DiagramTabView : UserControl
{
    private const double CardWidth = 240;
    private const double RowHeight = 22;
    private const double HeaderHeight = 34;
    private const double Gap = 80;

    private readonly Canvas _canvas = new();
    private readonly ScrollViewer _scroller;
    private readonly Dictionary<ObjectName, Border> _cards = [];
    private readonly List<(Path Path, ObjectName From, int FromRow, ObjectName To, int ToRow)> _links = [];
    private readonly TextBlock _status = new() { Margin = new Thickness(12, 8, 12, 8) };
    private Point _dragStart;
    private Point _cardStart;
    private Border? _dragging;

    public DiagramTabView(DiagramTabViewModel viewModel)
    {
        ViewModel = viewModel;
        _scroller = new ScrollViewer
        {
            Content = _canvas,
            ZoomMode = ZoomMode.Enabled,
            MinZoomFactor = 0.2f,
            MaxZoomFactor = 2f,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Enabled,
        };

        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Padding = new Thickness(8, 4, 8, 4) };
        toolbar.Children.Add(ToolButton("", "Reload", async () => await ViewModel.LoadAsync()));
        toolbar.Children.Add(ToolButton("", "Zoom in", () => Zoom(1.25f)));
        toolbar.Children.Add(ToolButton("", "Zoom out", () => Zoom(0.8f)));
        toolbar.Children.Add(ToolButton("", "Fit", Fit));
        toolbar.Children.Add(_status);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(toolbar);
        Grid.SetRow(_scroller, 1);
        root.Children.Add(_scroller);
        Content = root;

        _canvas.PointerMoved += OnPointerMoved;
        _canvas.PointerReleased += (_, e) =>
        {
            _dragging?.ReleasePointerCapture(e.Pointer);
            _dragging = null;
        };
        viewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(DiagramTabViewModel.Tables))
            {
                Build();
            }
            else if (e.PropertyName == nameof(TabViewModel.StatusText))
            {
                _status.Text = viewModel.StatusText ?? string.Empty;
            }
        };
        Loaded += async (_, _) =>
        {
            if (viewModel.Tables.Count == 0)
            {
                await viewModel.LoadAsync();
            }
        };
    }

    public event EventHandler<DatabaseObject>? TableOpenRequested;

    public DiagramTabViewModel ViewModel { get; }

    private static Button ToolButton(string glyph, string tooltip, Action action)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Style = (Style)Application.Current.Resources["ToolbarButtonStyle"] };
        button.Click += (_, _) => action();
        ToolTipService.SetToolTip(button, tooltip);
        return button;
    }

    private void Zoom(float factor) => _scroller.ChangeView(null, null, Math.Clamp(_scroller.ZoomFactor * factor, 0.2f, 2f));

    private void Fit()
    {
        if (_canvas.Width <= 0 || _canvas.Height <= 0)
        {
            return;
        }

        var zoom = (float)Math.Clamp(Math.Min(_scroller.ViewportWidth / _canvas.Width, _scroller.ViewportHeight / _canvas.Height), 0.2, 1.5);
        _scroller.ChangeView(0, 0, zoom);
    }

    private void Build()
    {
        _canvas.Children.Clear();
        _cards.Clear();
        _links.Clear();
        var tables = ViewModel.Tables;
        if (tables.Count == 0)
        {
            return;
        }

        // Tables that many others point at go left, so most curves run in one direction.
        var incoming = tables.ToDictionary(t => t.Table.Name, _ => 0);
        foreach (var (_, structure) in tables)
        {
            foreach (var fk in structure.ForeignKeys)
            {
                if (incoming.TryGetValue(fk.ReferencedTable, out var count))
                {
                    incoming[fk.ReferencedTable] = count + 1;
                }
            }
        }

        var ordered = tables.OrderByDescending(t => incoming[t.Table.Name]).ThenBy(t => t.Table.Name.Name, StringComparer.OrdinalIgnoreCase).ToArray();
        var columns = Math.Max(1, (int)Math.Ceiling(Math.Sqrt(ordered.Length * 1.5)));
        var columnHeights = new double[columns];
        for (var i = 0; i < ordered.Length; i++)
        {
            var column = Array.IndexOf(columnHeights, columnHeights.Min());
            var (table, structure) = ordered[i];
            var card = CreateCard(table, structure);
            var height = HeaderHeight + (structure.Columns.Count * RowHeight) + 8;
            Canvas.SetLeft(card, Gap + (column * (CardWidth + Gap)));
            Canvas.SetTop(card, Gap + columnHeights[column]);
            columnHeights[column] += height + Gap;
            _cards[table.Name] = card;
            _canvas.Children.Add(card);
        }

        var stroke = ThemeResources.Brush(this, "AccentFillColorDefaultBrush");
        foreach (var (table, structure) in tables)
        {
            foreach (var fk in structure.ForeignKeys)
            {
                var target = tables.FirstOrDefault(t => t.Table.Name == fk.ReferencedTable);
                if (target.Structure is null || fk.Columns.Count == 0 || fk.ReferencedColumns.Count == 0)
                {
                    continue;
                }

                var fromRow = Index(structure, fk.Columns[0]);
                var toRow = Index(target.Structure, fk.ReferencedColumns[0]);
                var path = new Path { Stroke = stroke, StrokeThickness = 1.5, Opacity = 0.75, IsHitTestVisible = false };
                ToolTipService.SetToolTip(path, fk.Name);
                Canvas.SetZIndex(path, -1);
                _canvas.Children.Add(path);
                _links.Add((path, table.Name, fromRow, fk.ReferencedTable, toRow));
            }
        }

        _canvas.Width = Gap + (columns * (CardWidth + Gap));
        _canvas.Height = columnHeights.Max() + Gap;
        UpdateLinks();
        DispatcherQueue.TryEnqueue(Fit);
    }

    private static int Index(TableStructure structure, string column)
    {
        for (var i = 0; i < structure.Columns.Count; i++)
        {
            if (string.Equals(structure.Columns[i].Name, column, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }

        return 0;
    }

    private Border CreateCard(DatabaseObject table, TableStructure structure)
    {
        var foreignKeyColumns = structure.ForeignKeys.SelectMany(f => f.Columns).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var stack = new StackPanel();
        var header = new Grid { Height = HeaderHeight, Padding = new Thickness(12, 0, 12, 0), Background = ThemeResources.Brush(this, "SubtleFillColorSecondaryBrush") };
        header.Children.Add(new TextBlock { Text = table.Name.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        stack.Children.Add(header);
        foreach (var column in structure.Columns)
        {
            var row = new Grid { Height = RowHeight, Padding = new Thickness(12, 0, 12, 0), ColumnSpacing = 6 };
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = new GridLength(16) });
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = GridLength.Auto });
            var glyph = column.IsPrimaryKey ? "" : foreignKeyColumns.Contains(column.Name) ? "" : string.Empty;
            row.Children.Add(new FontIcon { Glyph = glyph, FontSize = 10, Foreground = ThemeResources.Brush(this, "AccentTextFillColorPrimaryBrush") });
            var name = new TextBlock { Text = column.Name, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetColumn(name, 1);
            row.Children.Add(name);
            var type = new TextBlock { Text = column.DataType, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Foreground = ThemeResources.Brush(this, "TextFillColorTertiaryBrush"), MaxWidth = 100, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetColumn(type, 2);
            row.Children.Add(type);
            stack.Children.Add(row);
        }

        var card = new Border
        {
            Width = CardWidth,
            Child = stack,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = ThemeResources.Brush(this, "CardStrokeColorDefaultBrush"),
            Background = ThemeResources.Brush(this, "CardBackgroundFillColorDefaultBrush"),
            Shadow = new ThemeShadow(),
            Translation = new System.Numerics.Vector3(0, 0, 8),
            Tag = table,
            Padding = new Thickness(0, 0, 0, 8),
        };
        card.PointerPressed += (_, e) =>
        {
            _dragging = card;
            _dragStart = e.GetCurrentPoint(_canvas).Position;
            _cardStart = new Point(Canvas.GetLeft(card), Canvas.GetTop(card));
            card.CapturePointer(e.Pointer);
            e.Handled = true;
        };
        card.PointerMoved += OnPointerMoved;
        card.PointerReleased += (_, e) =>
        {
            card.ReleasePointerCapture(e.Pointer);
            _dragging = null;
        };
        card.DoubleTapped += (_, _) => TableOpenRequested?.Invoke(this, table);
        return card;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging is null)
        {
            return;
        }

        var point = e.GetCurrentPoint(_canvas).Position;
        Canvas.SetLeft(_dragging, Math.Max(0, _cardStart.X + point.X - _dragStart.X));
        Canvas.SetTop(_dragging, Math.Max(0, _cardStart.Y + point.Y - _dragStart.Y));
        UpdateLinks();
    }

    private void UpdateLinks()
    {
        foreach (var (path, from, fromRow, to, toRow) in _links)
        {
            if (!_cards.TryGetValue(from, out var fromCard) || !_cards.TryGetValue(to, out var toCard))
            {
                continue;
            }

            var fromLeft = Canvas.GetLeft(fromCard);
            var toLeft = Canvas.GetLeft(toCard);
            var fromY = Canvas.GetTop(fromCard) + HeaderHeight + (fromRow * RowHeight) + (RowHeight / 2);
            var toY = Canvas.GetTop(toCard) + HeaderHeight + (toRow * RowHeight) + (RowHeight / 2);
            var leftToRight = fromLeft > toLeft;
            var start = new Point(leftToRight ? fromLeft : fromLeft + CardWidth, fromY);
            var end = new Point(leftToRight ? toLeft + CardWidth : toLeft, toY);
            if (ReferenceEquals(fromCard, toCard))
            {
                start = new Point(fromLeft + CardWidth, fromY);
                end = new Point(fromLeft + CardWidth, toY);
            }

            var bend = Math.Max(40, Math.Abs(end.X - start.X) / 2);
            var direction = leftToRight ? -1 : 1;
            var figure = new PathFigure { StartPoint = start };
            figure.Segments.Add(new BezierSegment
            {
                Point1 = new Point(start.X + (direction * bend), start.Y),
                Point2 = new Point(end.X - (direction * bend), end.Y),
                Point3 = end,
            });
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            path.Data = geometry;
        }
    }
}
