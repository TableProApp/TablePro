using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.DataGrid.Automation;
using TablePro.DataGrid.Model;

namespace TablePro.DataGrid;

// Column -1 is the corner over the row numbers, whose click selects every cell.
internal sealed partial class HeaderCell : Microsoft.UI.Xaml.Controls.Grid
{
    private const string AscendingGlyph = "";
    private const string DescendingGlyph = "";

    private readonly DataGridView _grid;
    private readonly TextBlock _title;
    private readonly FontIcon _sort;
    private readonly ResizeGrip _grip;
    private bool _hover;
    private bool _pressed;
    private double _dragStartX;
    private double _dragStartWidth;
    private bool _dragging;

    public HeaderCell(DataGridView grid)
    {
        _grid = grid;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        BorderThickness = new Thickness(0, 0, 1, 1);
        _title = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(CellPainter.Padding, 0, 4, 0),
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            FontWeight = FontWeights.SemiBold,
        };
        _sort = new FontIcon { FontSize = 10, Margin = new Thickness(0, 0, 10, 0), Visibility = Visibility.Collapsed };
        SetColumn(_sort, 1);
        _grip = new ResizeGrip { Width = 8, HorizontalAlignment = HorizontalAlignment.Right };
        SetColumnSpan(_grip, 2);
        AutomationProperties.SetAccessibilityView(_title, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_sort, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_grip, AccessibilityView.Raw);
        Children.Add(_title);
        Children.Add(_sort);
        Children.Add(_grip);

        PointerEntered += (_, _) => SetVisual(hover: true, _pressed);
        PointerExited += (_, _) => SetVisual(hover: false, pressed: false);
        PointerPressed += (_, _) => SetVisual(_hover, pressed: true);
        PointerReleased += (_, _) => SetVisual(_hover, pressed: false);
        PointerCaptureLost += (_, _) => SetVisual(_hover, pressed: false);
        Tapped += OnTapped;
        _grip.PointerPressed += OnGripPressed;
        _grip.PointerMoved += OnGripMoved;
        _grip.PointerReleased += OnGripReleased;
        _grip.PointerCaptureLost += (_, _) => _dragging = false;
        _grip.Tapped += (_, e) => e.Handled = true;
        _grip.DoubleTapped += OnGripDoubleTapped;
        Instances++;
    }

    public static int Instances { get; private set; }

    public int Column { get; private set; } = -2;

    public string Title => _title.Text;

    public SortDirection SortDirection { get; private set; }

    public void Bind(int column, string title, SortDirection direction)
    {
        Column = column;
        if (!string.Equals(_title.Text, title, StringComparison.Ordinal))
        {
            _title.Text = title;
        }
        SortDirection = direction;
        _sort.Visibility = direction == SortDirection.None ? Visibility.Collapsed : Visibility.Visible;
        _sort.Glyph = direction == SortDirection.Descending ? DescendingGlyph : AscendingGlyph;
        _grip.Visibility = column < 0 ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(this, title);
        ApplyBrushes();
    }

    public void ApplyBrushes()
    {
        var brushes = _grid.Brushes;
        Background = _pressed ? brushes.HeaderPressed : _hover ? brushes.HeaderHover : brushes.HeaderBackground;
        BorderBrush = brushes.Divider;
        _title.Foreground = brushes.HeaderText;
        _sort.Foreground = brushes.HeaderText;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new HeaderAutomationPeer(this, _grid);

    private void SetVisual(bool hover, bool pressed)
    {
        _hover = hover;
        _pressed = pressed;
        ApplyBrushes();
    }

    private void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        e.Handled = true;
        if (Column < 0)
        {
            _grid.SelectAll();
        }
        else
        {
            _grid.SortBy(Column);
        }
    }

    private void OnGripPressed(object sender, PointerRoutedEventArgs e)
    {
        if (Column < 0)
        {
            return;
        }
        _dragging = _grip.CapturePointer(e.Pointer);
        _dragStartX = e.GetCurrentPoint(_grid).Position.X;
        _dragStartWidth = _grid.Columns.Width(Column);
        e.Handled = true;
    }

    private void OnGripMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }
        _grid.ResizeColumn(Column, _dragStartWidth + e.GetCurrentPoint(_grid).Position.X - _dragStartX);
        e.Handled = true;
    }

    private void OnGripReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging)
        {
            _grip.ReleasePointerCapture(e.Pointer);
            _dragging = false;
            e.Handled = true;
        }
    }

    private void OnGripDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (Column >= 0)
        {
            _grid.FitColumn(Column);
        }
        e.Handled = true;
    }
}

// The resize handle on a header's right edge, with the cursor Windows shows over a column divider.
internal sealed partial class ResizeGrip : Microsoft.UI.Xaml.Controls.Grid
{
    public ResizeGrip()
    {
        // Transparent, not null, so the grip takes the pointer.
        Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
    }
}
