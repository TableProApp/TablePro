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

    // Segoe Fluent Icons' Hide, the eye with a slash the macOS sheet marks a masked column with.
    private const string MaskedGlyph = "\uED1A";

    // Sideways DIPs before a press on a header becomes a drag to move its column.
    private const double MoveThreshold = 4;

    private readonly DataGridView _grid;
    private readonly TextBlock _title;
    private readonly FontIcon _sort;
    private readonly FontIcon _masked;
    private readonly ResizeGrip _grip;
    private bool _hover;
    private bool _pressed;
    private double _dragStartX;
    private double _dragStartWidth;
    private bool _dragging;
    private uint? _pressPointer;
    private double _pressX;
    private bool _moving;
    private bool _moved;

    public HeaderCell(DataGridView grid)
    {
        _grid = grid;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
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
        _masked = new FontIcon
        {
            Glyph = MaskedGlyph,
            FontSize = 12,
            Margin = new Thickness(0, 0, 8, 0),
            Visibility = Visibility.Collapsed,
        };
        SetColumn(_masked, 1);
        _sort = new FontIcon { FontSize = 10, Margin = new Thickness(0, 0, 10, 0), Visibility = Visibility.Collapsed };
        SetColumn(_sort, 2);
        _grip = new ResizeGrip { Width = 8, HorizontalAlignment = HorizontalAlignment.Right };
        SetColumnSpan(_grip, 3);
        AutomationProperties.SetAccessibilityView(_title, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_sort, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_masked, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_grip, AccessibilityView.Raw);
        Children.Add(_title);
        Children.Add(_masked);
        Children.Add(_sort);
        Children.Add(_grip);

        PointerEntered += (_, _) => SetVisual(hover: true, _pressed);
        PointerExited += (_, _) => SetVisual(hover: false, pressed: false);
        PointerPressed += (_, _) => SetVisual(_hover, pressed: true);
        PointerReleased += (_, _) => SetVisual(_hover, pressed: false);
        PointerCaptureLost += (_, _) => SetVisual(_hover, pressed: false);
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += OnReleased;
        PointerCaptureLost += OnMoveLost;
        PointerCanceled += OnMoveLost;
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

    public DataGridView Owner => _grid;

    public string Title => _title.Text;

    public SortDirection SortDirection { get; private set; }

    public void Bind(int column, string title, SortDirection direction)
    {
        var (previousColumn, previousDirection) = (Column, SortDirection);
        Column = column;
        if (!string.Equals(_title.Text, title, StringComparison.Ordinal))
        {
            _title.Text = title;
        }
        SortDirection = direction;
        if (column == previousColumn && direction != previousDirection
            && AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged)
            && FrameworkElementAutomationPeer.FromElement(this) is { } peer)
        {
            peer.RaisePropertyChangedEvent(AutomationElementIdentifiers.ItemStatusProperty,
                _grid.SortStatus(previousDirection), _grid.SortStatus(direction));
        }
        _sort.Visibility = direction == SortDirection.None ? Visibility.Collapsed : Visibility.Visible;
        _sort.Glyph = direction == SortDirection.Descending ? DescendingGlyph : AscendingGlyph;
        _grip.Visibility = column < 0 ? Visibility.Collapsed : Visibility.Visible;
        var masked = _grid.MaskNote(column);
        _masked.Visibility = masked is null ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(_masked, masked);
        AutomationProperties.SetName(this, title);
        AutomationProperties.SetHelpText(this, masked ?? string.Empty);
        ApplyBrushes();
    }

    public void ApplyBrushes()
    {
        var brushes = _grid.Brushes;
        Background = _pressed ? brushes.HeaderPressed : _hover ? brushes.HeaderHover : brushes.HeaderBackground;
        BorderBrush = brushes.Divider;
        _title.Foreground = brushes.HeaderText;
        _sort.Foreground = brushes.HeaderText;
        _masked.Foreground = brushes.HeaderText;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new HeaderAutomationPeer(this, _grid);

    private void SetVisual(bool hover, bool pressed)
    {
        _hover = hover;
        _pressed = pressed;
        ApplyBrushes();
    }

    // The grid ended a move this cell started, on Escape or new data: the release that follows is no click.
    public void StopMove()
    {
        _pressPointer = null;
        if (!_moving)
        {
            return;
        }
        _moving = false;
        _moved = true;
        ReleasePointerCaptures();
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        _moved = false;
        _pressPointer = null;
        if (Column < 0 || !_grid.CanReorderColumns || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            return;
        }
        _pressPointer = e.Pointer.PointerId;
        _pressX = e.GetCurrentPoint(_grid.Scroller).Position.X;
    }

    // Captured only once it is a drag, so a press and release without one is still a Tapped that sorts.
    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_pressPointer != e.Pointer.PointerId)
        {
            return;
        }
        var point = e.GetCurrentPoint(_grid.Scroller).Position;
        if (!_moving)
        {
            if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
            {
                _pressPointer = null;
                return;
            }
            if (Math.Abs(point.X - _pressX) < MoveThreshold || !CapturePointer(e.Pointer))
            {
                return;
            }
            _moving = true;
            if (!_grid.BeginColumnMove(this, Column, point))
            {
                StopMove();
                return;
            }
        }
        else
        {
            _grid.DragColumnMove(point);
        }
        e.Handled = true;
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_pressPointer != e.Pointer.PointerId)
        {
            return;
        }
        _pressPointer = null;
        if (!_moving)
        {
            return;
        }
        _moving = false;
        _moved = true;
        var point = e.GetCurrentPoint(_grid.Scroller).Position;
        ReleasePointerCapture(e.Pointer);
        _grid.EndColumnMove(point);
        e.Handled = true;
    }

    private void OnMoveLost(object sender, PointerRoutedEventArgs e)
    {
        _pressPointer = null;
        if (!_moving)
        {
            return;
        }
        _moving = false;
        _moved = true;
        _grid.CancelColumnMove();
    }

    private void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        e.Handled = true;
        // A drag that moved, or was cancelled, ends with a release Windows may still call a tap.
        if (_moved)
        {
            _moved = false;
            return;
        }
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
