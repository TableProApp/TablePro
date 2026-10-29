using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.App.ViewModels;
using TablePro.Core.Browse;
using TablePro.Core.JoinBuilder;
using Windows.Foundation;
using GridColumn = Microsoft.UI.Xaml.Controls.ColumnDefinition;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace TablePro.App.Views;

/// <summary>
/// The join builder: tables on the left, the picked ones as cards on a canvas with a curve for each join, and the joins,
/// filters and sort on the right above the SQL they make. Open in Query Tab hands the SQL to a new editor tab.
/// </summary>
public sealed partial class JoinBuilderTabView : UserControl
{
    private const double CardWidth = 220;
    private const double HeaderHeight = 36;
    private const double RowHeight = 26;
    private const double Gap = 70;

    private static readonly FilterOperator[] Operators = Enum.GetValues<FilterOperator>();

    private readonly TextBox _tableFilter = new() { PlaceholderText = Strings.Get("Tools/JoinFilterTables"), Margin = new Thickness(12, 8, 12, 8) };
    private readonly StackPanel _tableList = new() { Padding = new Thickness(8, 0, 8, 8) };
    private readonly Canvas _canvas = new();
    private readonly ScrollViewer _canvasScroller;
    private readonly StackPanel _details = new() { Spacing = 16, Padding = new Thickness(16) };
    private readonly TextBlock _sql = new() { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    private readonly TextBlock _hint = new() { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.75 };
    private readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
    private readonly Button _open = new() { Content = Strings.Get("Tools/JoinOpenInQueryTab") };
    private readonly Button _copy = new() { Content = Strings.Get("Tools/JoinCopySql") };
    private readonly InfoBar _error = new() { Severity = InfoBarSeverity.Error, Title = Strings.Get("Tools/JoinCannotReadTables"), IsClosable = false };
    private readonly Dictionary<string, Border> _cards = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Point> _positions = new(StringComparer.Ordinal);
    private readonly List<(Path Path, string Child, int ChildRow, string Parent, int ParentRow)> _links = [];
    private bool _rebuildQueued;
    private Point _dragStart;
    private Point _cardStart;
    private Border? _dragging;

    public JoinBuilderTabView(JoinBuilderTabViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        ViewModel = viewModel;
        AutomationProperties.SetName(_tableFilter, Strings.Get("Tools/JoinFilterTables"));
        _open.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        _open.Click += (_, _) =>
        {
            if (ViewModel.Sql is { } sql)
            {
                OpenSqlRequested?.Invoke(this, sql);
            }
        };
        _copy.Click += (_, _) =>
        {
            if (ViewModel.Sql is { } sql)
            {
                GridCommands.SetClipboard(sql);
            }
        };
        _tableFilter.TextChanged += (_, _) =>
        {
            ViewModel.TableFilter = _tableFilter.Text;
            BuildTableList();
        };
        var retry = new Button { Content = Strings.Get("Tools/JoinTryAgain") };
        retry.Click += async (_, _) => await ViewModel.LoadAsync();
        _error.ActionButton = retry;

        _canvasScroller = new ScrollViewer
        {
            Content = _canvas,
            ZoomMode = ZoomMode.Enabled,
            MinZoomFactor = 0.3f,
            MaxZoomFactor = 2f,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Enabled,
        };
        _canvas.PointerMoved += OnPointerMoved;
        _canvas.PointerReleased += (_, e) =>
        {
            _dragging?.ReleasePointerCapture(e.Pointer);
            _dragging = null;
        };

        Content = BuildLayout();
        viewModel.Changed += (_, change) =>
        {
            if (change == JoinBuilderChange.Structure)
            {
                QueueRebuild();
            }
            else
            {
                UpdateSql();
            }
        };
        viewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(TabViewModel.StatusText))
            {
                _status.Text = viewModel.StatusText ?? string.Empty;
            }
        };
        Loaded += async (_, _) =>
        {
            if (!viewModel.IsLoaded && !viewModel.IsBusy)
            {
                await viewModel.LoadAsync();
            }
            else
            {
                Rebuild();
            }
        };
    }

    /// <summary>Raised with the finished SELECT when the user opens it in a query tab.</summary>
    public event EventHandler<string>? OpenSqlRequested;

    public JoinBuilderTabViewModel ViewModel { get; }

    private Grid BuildLayout()
    {
        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Padding = new Thickness(8, 4, 8, 4) };
        toolbar.Children.Add(ToolButton("", Strings.Get("Tools/JoinReloadTables"), async () => await ViewModel.LoadAsync()));
        toolbar.Children.Add(ToolButton("", Strings.Get("Tools/JoinClearQuery"), ViewModel.Clear));
        toolbar.Children.Add(ToolButton("", Strings.Get("Tools/JoinZoomIn"), () => Zoom(1.25f)));
        toolbar.Children.Add(ToolButton("", Strings.Get("Tools/JoinZoomOut"), () => Zoom(0.8f)));
        toolbar.Children.Add(_status);

        var left = new Grid();
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        left.Children.Add(_tableFilter);
        var tables = new ScrollViewer { Content = _tableList };
        Grid.SetRow(tables, 1);
        left.Children.Add(tables);
        var leftBorder = new Border
        {
            Child = left,
            BorderThickness = new Thickness(0, 0, 1, 0),
            BorderBrush = ThemeResources.Brush(this, "DividerStrokeColorDefaultBrush"),
        };

        var sqlFont = Application.Current.Resources.TryGetValue("CodeFontFamily", out var font) && font is FontFamily family ? family : null;
        if (sqlFont is not null)
        {
            _sql.FontFamily = sqlFont;
        }

        var sqlBox = new Border
        {
            Child = new ScrollViewer { Content = _sql, MaxHeight = 180, Padding = new Thickness(12) },
            Background = ThemeResources.Brush(this, "SubtleFillColorSecondaryBrush"),
            BorderBrush = ThemeResources.Brush(this, "CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Margin = new Thickness(12, 0, 12, 0),
        };
        AutomationProperties.SetName(sqlBox, Strings.Get("Tools/JoinGeneratedSql"));

        var footer = new Grid { Padding = new Thickness(12), ColumnSpacing = 8 };
        footer.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        footer.Children.Add(_hint);
        Grid.SetColumn(_copy, 1);
        Grid.SetColumn(_open, 2);
        footer.Children.Add(_copy);
        footer.Children.Add(_open);

        var center = new Grid();
        center.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        center.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        center.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        center.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        center.Children.Add(_error);
        Grid.SetRow(_canvasScroller, 1);
        center.Children.Add(_canvasScroller);
        Grid.SetRow(sqlBox, 2);
        center.Children.Add(sqlBox);
        Grid.SetRow(footer, 3);
        center.Children.Add(footer);

        var right = new Border
        {
            Child = new ScrollViewer { Content = _details },
            BorderThickness = new Thickness(1, 0, 0, 0),
            BorderBrush = ThemeResources.Brush(this, "DividerStrokeColorDefaultBrush"),
        };

        var body = new Grid();
        body.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(240) });
        body.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        body.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(380) });
        body.Children.Add(leftBorder);
        Grid.SetColumn(center, 1);
        body.Children.Add(center);
        Grid.SetColumn(right, 2);
        body.Children.Add(right);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(toolbar);
        Grid.SetRow(body, 1);
        root.Children.Add(body);
        return root;
    }

    private static Button ToolButton(string glyph, string name, Action action)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Style = (Style)Application.Current.Resources["ToolbarButtonStyle"] };
        button.Click += (_, _) => action();
        ToolTipService.SetToolTip(button, name);
        AutomationProperties.SetName(button, name);
        return button;
    }

    private void Zoom(float factor) => _canvasScroller.ChangeView(null, null, Math.Clamp(_canvasScroller.ZoomFactor * factor, 0.3f, 2f));

    // A combo box that changes the query is rebuilt only after its own selection event has finished.
    private void QueueRebuild()
    {
        if (_rebuildQueued)
        {
            return;
        }

        _rebuildQueued = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            _rebuildQueued = false;
            Rebuild();
        });
    }

    private void Rebuild()
    {
        _error.IsOpen = ViewModel.LoadError is not null;
        _error.Message = ViewModel.LoadError ?? string.Empty;
        BuildTableList();
        BuildCanvas();
        BuildDetails();
        UpdateSql();
    }

    private void UpdateSql()
    {
        var sql = ViewModel.Sql;
        _sql.Text = sql ?? Strings.Get("Tools/JoinSqlPlaceholder");
        _open.IsEnabled = sql is not null;
        _copy.IsEnabled = sql is not null;
        _hint.Text = ViewModel.Hint;
    }

    private void BuildTableList()
    {
        _tableList.Children.Clear();
        foreach (var table in ViewModel.FilteredTables)
        {
            var box = new CheckBox { Content = table, IsChecked = ViewModel.IsIncluded(table), MinWidth = 0 };
            ToolTipService.SetToolTip(box, table);
            box.Click += (_, _) => ViewModel.SetIncluded(table, box.IsChecked == true);
            _tableList.Children.Add(box);
        }

        if (ViewModel.IsLoaded && ViewModel.Graph.IsEmpty)
        {
            _tableList.Children.Add(new TextBlock { Text = Strings.Get("Tools/JoinNoTables"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
        }
    }

    private void BuildCanvas()
    {
        _canvas.Children.Clear();
        _cards.Clear();
        _links.Clear();
        var tables = ViewModel.Draft.Tables;
        for (var i = 0; i < tables.Count; i++)
        {
            var name = tables[i].Name;
            if (!_positions.TryGetValue(name, out var position))
            {
                // New cards go to the right of the last one, staggered so a join's curve has room to bend.
                position = new Point(Gap / 2 + (i * (CardWidth + Gap)), Gap / 2 + (i % 2 * 40));
                _positions[name] = position;
            }

            var card = CreateCard(name);
            Canvas.SetLeft(card, position.X);
            Canvas.SetTop(card, position.Y);
            _cards[name] = card;
            _canvas.Children.Add(card);
        }

        var stroke = ThemeResources.Brush(this, "AccentFillColorDefaultBrush");
        foreach (var table in tables)
        {
            if (table.Condition is not { ColumnPairs.Count: > 0 } condition)
            {
                continue;
            }

            var pair = condition.ColumnPairs[0];
            var path = new Path { Stroke = stroke, StrokeThickness = 1.5, Opacity = 0.8, IsHitTestVisible = false };
            Canvas.SetZIndex(path, -1);
            _canvas.Children.Add(path);
            _links.Add((path, condition.ChildTable, Row(condition.ChildTable, pair.Child), condition.ParentTable, Row(condition.ParentTable, pair.Parent)));
        }

        var right = _positions.Where(p => _cards.ContainsKey(p.Key)).Select(p => p.Value.X + CardWidth).DefaultIfEmpty(0).Max();
        var bottom = tables.Select(t => _positions[t.Name].Y + HeaderHeight + (ViewModel.Graph.ColumnsOf(t.Name).Count * RowHeight)).DefaultIfEmpty(0).Max();
        _canvas.Width = right + Gap;
        _canvas.Height = bottom + Gap;
        UpdateLinks();
    }

    private int Row(string table, string column)
    {
        var columns = ViewModel.Graph.ColumnsOf(table);
        for (var i = 0; i < columns.Count; i++)
        {
            if (columns[i] == column)
            {
                return i;
            }
        }

        return 0;
    }

    private Border CreateCard(string table)
    {
        var stack = new StackPanel();
        var header = new Grid { Height = HeaderHeight, Padding = new Thickness(12, 0, 4, 0), Background = ThemeResources.Brush(this, "SubtleFillColorSecondaryBrush") };
        header.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = table, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 10 }, Style = (Style)Application.Current.Resources["ToolbarButtonStyle"] };
        AutomationProperties.SetName(remove, Strings.Format("Tools/JoinRemoveTable", table));
        ToolTipService.SetToolTip(remove, Strings.Format("Tools/JoinRemoveTable", table));
        remove.Click += (_, _) => ViewModel.SetIncluded(table, false);
        Grid.SetColumn(remove, 1);
        header.Children.Add(remove);
        stack.Children.Add(header);

        foreach (var column in ViewModel.Graph.ColumnsOf(table))
        {
            var reference = new JoinColumnRef(table, column);
            var box = new CheckBox
            {
                Content = new TextBlock { Text = column, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis },
                IsChecked = ViewModel.IsSelected(reference),
                MinWidth = 0,
                MinHeight = 0,
                Height = RowHeight,
                Padding = new Thickness(6, 0, 0, 0),
                Margin = new Thickness(12, 0, 8, 0),
            };
            AutomationProperties.SetName(box, Strings.Format("Tools/JoinSelectColumn", table, column));
            ToolTipService.SetToolTip(box, ViewModel.Graph.TypeOf(table, column) is { } type ? $"{column} {type}" : column);
            box.Click += (_, _) => ViewModel.SetSelected(reference, box.IsChecked == true);
            stack.Children.Add(box);
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
            Padding = new Thickness(0, 0, 0, 6),
        };

        // Only the header drags, so the column check boxes keep their clicks.
        header.PointerPressed += (_, e) =>
        {
            _dragging = card;
            _dragStart = e.GetCurrentPoint(_canvas).Position;
            _cardStart = new Point(Canvas.GetLeft(card), Canvas.GetTop(card));
            header.CapturePointer(e.Pointer);
            e.Handled = true;
        };
        header.PointerMoved += OnPointerMoved;
        header.PointerReleased += (_, e) =>
        {
            header.ReleasePointerCapture(e.Pointer);
            _dragging = null;
        };
        return card;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging is null)
        {
            return;
        }

        var point = e.GetCurrentPoint(_canvas).Position;
        var left = Math.Max(0, _cardStart.X + point.X - _dragStart.X);
        var top = Math.Max(0, _cardStart.Y + point.Y - _dragStart.Y);
        Canvas.SetLeft(_dragging, left);
        Canvas.SetTop(_dragging, top);
        var name = _cards.First(c => ReferenceEquals(c.Value, _dragging)).Key;
        _positions[name] = new Point(left, top);
        _canvas.Width = Math.Max(_canvas.Width, left + CardWidth + Gap);
        UpdateLinks();
    }

    private void UpdateLinks()
    {
        foreach (var (path, child, childRow, parent, parentRow) in _links)
        {
            if (!_cards.TryGetValue(child, out var childCard) || !_cards.TryGetValue(parent, out var parentCard))
            {
                continue;
            }

            var childLeft = Canvas.GetLeft(childCard);
            var parentLeft = Canvas.GetLeft(parentCard);
            var childY = Canvas.GetTop(childCard) + HeaderHeight + (childRow * RowHeight) + (RowHeight / 2);
            var parentY = Canvas.GetTop(parentCard) + HeaderHeight + (parentRow * RowHeight) + (RowHeight / 2);
            var childOnRight = childLeft > parentLeft;
            var start = new Point(childOnRight ? childLeft : childLeft + CardWidth, childY);
            var end = new Point(childOnRight ? parentLeft + CardWidth : parentLeft, parentY);
            var bend = Math.Max(40, Math.Abs(end.X - start.X) / 2);
            var direction = childOnRight ? -1 : 1;
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

    private void BuildDetails()
    {
        _details.Children.Clear();
        if (!ViewModel.IsLoaded)
        {
            _details.Children.Add(new ProgressRing { IsActive = ViewModel.IsBusy, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left });
            return;
        }

        _details.Children.Add(Section(Strings.Get("Tools/JoinSectionJoins")));
        var tables = ViewModel.Draft.Tables;
        if (tables.Count < 2)
        {
            _details.Children.Add(Note(Strings.Get("Tools/JoinPickSecondTable")));
        }

        for (var i = 1; i < tables.Count; i++)
        {
            _details.Children.Add(JoinRow(i, tables[i]));
        }

        _details.Children.Add(Section(Strings.Get("Tools/JoinSectionFilters")));
        foreach (var filter in ViewModel.Draft.Filters)
        {
            _details.Children.Add(FilterRow(filter));
        }

        _details.Children.Add(AddButton(Strings.Get("Tools/JoinAddFilter"), ViewModel.AddFilter, tables.Count > 0));

        _details.Children.Add(Section(Strings.Get("Tools/JoinSectionSort")));
        foreach (var sort in ViewModel.Draft.Sorts)
        {
            _details.Children.Add(SortRow(sort));
        }

        _details.Children.Add(AddButton(Strings.Get("Tools/JoinAddSort"), ViewModel.AddSort, tables.Count > 0));
    }

    private static TextBlock Section(string text) => new() { Text = text, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] };

    private static TextBlock Note(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };

    private static Button AddButton(string text, Action action, bool enabled)
    {
        var button = new Button { Content = text, IsEnabled = enabled };
        button.Click += (_, _) => action();
        return button;
    }

    private StackPanel JoinRow(int index, JoinTable table)
    {
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(new TextBlock { Text = table.Name, TextTrimming = TextTrimming.CharacterEllipsis });

        var candidates = ViewModel.Candidates(index);
        var condition = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(condition, Strings.Format("Tools/JoinConditionFor", table.Name));
        foreach (var candidate in candidates)
        {
            condition.Items.Add(candidate.Title);
        }

        condition.Items.Add(Strings.Get("Tools/JoinCrossJoin"));
        condition.SelectedIndex = table.Condition is { } current && IndexOf(candidates, current) is var at and >= 0 ? at : candidates.Count;
        condition.SelectionChanged += (_, _) =>
        {
            var selected = condition.SelectedIndex;
            ViewModel.SetCondition(index, selected >= 0 && selected < candidates.Count ? candidates[selected] : null);
        };

        var kind = new ComboBox { MinWidth = 130, IsEnabled = table.Condition is not null };
        AutomationProperties.SetName(kind, Strings.Format("Tools/JoinTypeFor", table.Name));
        foreach (var option in ViewModel.JoinKinds)
        {
            kind.Items.Add(ToolsNames.JoinKindName(option));
        }

        kind.SelectedIndex = Math.Max(0, IndexOf(ViewModel.JoinKinds, table.Kind));
        kind.SelectionChanged += (_, _) =>
        {
            if (kind.SelectedIndex >= 0)
            {
                ViewModel.SetKind(index, ViewModel.JoinKinds[kind.SelectedIndex]);
            }
        };

        var row = new Grid { ColumnSpacing = 6 };
        row.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(kind);
        Grid.SetColumn(condition, 1);
        row.Children.Add(condition);
        panel.Children.Add(row);
        return panel;
    }

    private static int IndexOf<T>(IReadOnlyList<T> list, T value)
    {
        for (var i = 0; i < list.Count; i++)
        {
            if (EqualityComparer<T>.Default.Equals(list[i], value))
            {
                return i;
            }
        }

        return -1;
    }

    private ComboBox ColumnPicker(JoinColumnRef selected, Action<JoinColumnRef> changed)
    {
        var columns = ViewModel.AvailableColumns;
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = columns.Select(c => c.ToString()).ToList() };
        AutomationProperties.SetName(picker, Strings.Get("Tools/JoinColumn"));
        picker.SelectedIndex = IndexOf(columns, selected);
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedIndex >= 0)
            {
                changed(columns[picker.SelectedIndex]);
            }
        };
        return picker;
    }

    private Grid FilterRow(JoinFilter filter)
    {
        var grid = new Grid { ColumnSpacing = 6, RowSpacing = 6 };
        grid.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var column = ColumnPicker(filter.Column, c => ViewModel.UpdateFilter(filter, column: c));
        var op = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = Operators.Select(TableNames.Operator).ToList() };
        AutomationProperties.SetName(op, Strings.Get("Tools/JoinOperator"));
        op.SelectedIndex = Array.IndexOf(Operators, filter.Operator);
        op.SelectionChanged += (_, _) =>
        {
            if (op.SelectedIndex >= 0)
            {
                ViewModel.UpdateFilter(filter, op: Operators[op.SelectedIndex]);
            }
        };
        var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, Style = (Style)Application.Current.Resources["ToolbarButtonStyle"] };
        AutomationProperties.SetName(remove, Strings.Get("Tools/JoinRemoveFilter"));
        ToolTipService.SetToolTip(remove, Strings.Get("Tools/JoinRemoveFilter"));
        remove.Click += (_, _) => ViewModel.RemoveFilter(filter);
        Grid.SetColumn(op, 1);
        Grid.SetColumn(remove, 2);
        grid.Children.Add(column);
        grid.Children.Add(op);
        grid.Children.Add(remove);

        if (filter.Operator.TakesValue())
        {
            var between = filter.Operator == FilterOperator.Between;
            var value = new TextBox
            {
                Text = filter.Value,
                PlaceholderText = filter.Operator is FilterOperator.In or FilterOperator.NotIn ? "a, b, c" : between ? Strings.Get("Tools/JoinValueFrom") : Strings.Get("Common/Value"),
            };
            AutomationProperties.SetName(value, Strings.Get("Common/Value"));
            value.TextChanged += (_, _) => ViewModel.UpdateFilter(filter, value: value.Text);
            Grid.SetRow(value, 1);
            Grid.SetColumnSpan(value, between ? 1 : 2);
            grid.Children.Add(value);
            if (between)
            {
                var second = new TextBox { Text = filter.SecondValue, PlaceholderText = Strings.Get("Tools/JoinValueTo") };
                AutomationProperties.SetName(second, Strings.Get("Tools/JoinSecondValue"));
                second.TextChanged += (_, _) => ViewModel.UpdateFilter(filter, secondValue: second.Text);
                Grid.SetRow(second, 1);
                Grid.SetColumn(second, 1);
                grid.Children.Add(second);
            }
        }

        return grid;
    }

    private Grid SortRow(JoinSort sort)
    {
        var grid = new Grid { ColumnSpacing = 6 };
        grid.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        var column = ColumnPicker(sort.Column, c => ViewModel.UpdateSort(sort, column: c));
        var direction = new ComboBox { ItemsSource = new List<string> { Strings.Get("Tools/JoinAscending"), Strings.Get("Tools/JoinDescending") }, SelectedIndex = sort.Descending ? 1 : 0, MinWidth = 120 };
        AutomationProperties.SetName(direction, Strings.Get("Tools/JoinSortDirection"));
        direction.SelectionChanged += (_, _) => ViewModel.UpdateSort(sort, descending: direction.SelectedIndex == 1);
        var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, Style = (Style)Application.Current.Resources["ToolbarButtonStyle"] };
        AutomationProperties.SetName(remove, Strings.Get("Tools/JoinRemoveSort"));
        ToolTipService.SetToolTip(remove, Strings.Get("Tools/JoinRemoveSort"));
        remove.Click += (_, _) => ViewModel.RemoveSort(sort);
        Grid.SetColumn(direction, 1);
        Grid.SetColumn(remove, 2);
        grid.Children.Add(column);
        grid.Children.Add(direction);
        grid.Children.Add(remove);
        return grid;
    }
}
