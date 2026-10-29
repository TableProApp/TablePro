using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.Core.Interaction;

namespace TablePro.App.Controls;

/// <summary>
/// Drags the size of the grid row or column next to it. It resizes the definition it is told about, so the panes on
/// either side keep their own layout rules.
/// </summary>
public sealed partial class PaneSplitter : Grid
{
    public static readonly DependencyProperty OrientationProperty = DependencyProperty.Register(
        nameof(Orientation), typeof(Orientation), typeof(PaneSplitter), new PropertyMetadata(Orientation.Vertical, (d, _) => ((PaneSplitter)d).UpdateCursor()));

    public static readonly DependencyProperty TargetIndexProperty = DependencyProperty.Register(
        nameof(TargetIndex), typeof(int), typeof(PaneSplitter), new PropertyMetadata(-1));

    public static readonly DependencyProperty InvertProperty = DependencyProperty.Register(
        nameof(Invert), typeof(bool), typeof(PaneSplitter), new PropertyMetadata(false));

    private readonly Border _line = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, CornerRadius = new CornerRadius(1) };
    private double _start;
    private double _startSize;
    private bool _dragging;
    private uint _pointerId;

    public PaneSplitter()
    {
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        Children.Add(_line);
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += OnReleased;
        PointerCaptureLost += (_, _) => _dragging = false;
        PointerEntered += (_, _) => _line.Opacity = 1;
        PointerExited += (_, _) => _line.Opacity = _dragging ? 1 : 0.5;
        Loaded += (_, _) =>
        {
            _line.Background = (Brush)Application.Current.Resources["ControlStrongStrokeColorDefaultBrush"];
            _line.Opacity = 0.5;
            UpdateCursor();
        };
    }

    /// <summary>Vertical splits columns (drag left and right); Horizontal splits rows.</summary>
    public Orientation Orientation
    {
        get => (Orientation)GetValue(OrientationProperty);
        set => SetValue(OrientationProperty, value);
    }

    /// <summary>The row or column of the parent grid to resize.</summary>
    public int TargetIndex
    {
        get => (int)GetValue(TargetIndexProperty);
        set => SetValue(TargetIndexProperty, value);
    }

    /// <summary>Set when the target lies after the splitter, so dragging toward it shrinks it.</summary>
    public bool Invert
    {
        get => (bool)GetValue(InvertProperty);
        set => SetValue(InvertProperty, value);
    }

    public event EventHandler<double>? SizeCommitted;

    private void UpdateCursor()
    {
        var vertical = Orientation == Orientation.Vertical;
        ProtectedCursor = InputSystemCursor.Create(vertical ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.SizeNorthSouth);
        _line.Width = vertical ? 2 : 36;
        _line.Height = vertical ? 36 : 2;
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (Parent is not Grid grid)
        {
            return;
        }

        _dragging = true;
        var point = e.GetCurrentPoint(grid).Position;
        _start = Orientation == Orientation.Vertical ? point.X : point.Y;
        _startSize = Orientation == Orientation.Vertical ? grid.ColumnDefinitions[TargetIndex].ActualWidth : grid.RowDefinitions[TargetIndex].ActualHeight;
        _pointerId = e.Pointer.PointerId;
        CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || Parent is not Grid grid)
        {
            return;
        }

        // While captured the splitter also receives moves bubbled from hover changes elsewhere in the window, with
        // no button down and a position far from the pointer (a TextBlock's, at the top of the tab). Taking one of
        // those as the drag threw the results pane to its largest size, which read as the splitter moving the wrong
        // way, and the next real move snapped it back, which read as sticking. Only the pressed pointer, still
        // pressed, drags.
        var current = e.GetCurrentPoint(grid);
        if (e.Pointer.PointerId != _pointerId || !e.Pointer.IsInContact)
        {
            return;
        }

        var point = current.Position;
        var delta = (Orientation == Orientation.Vertical ? point.X : point.Y) - _start;
        var desired = _startSize + (Invert ? -delta : delta);
        if (Orientation == Orientation.Vertical)
        {
            var columns = grid.ColumnDefinitions;
            var others = columns.Where((_, i) => i != TargetIndex).Select(c => new SplitterTrack(c.ActualWidth, c.MinWidth, c.Width.IsStar));
            var target = columns[TargetIndex];
            target.Width = new GridLength(SplitterMath.Clamp(desired, grid.ActualWidth, new SplitterTrack(target.ActualWidth, target.MinWidth, false), others, starFloor: 160));
        }
        else
        {
            var rows = grid.RowDefinitions;
            var others = rows.Where((_, i) => i != TargetIndex).Select(r => new SplitterTrack(r.ActualHeight, r.MinHeight, r.Height.IsStar));
            var target = rows[TargetIndex];
            target.Height = new GridLength(SplitterMath.Clamp(desired, grid.ActualHeight, new SplitterTrack(target.ActualHeight, target.MinHeight, false), others, starFloor: 80));
        }

        e.Handled = true;
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }

        _dragging = false;
        ReleasePointerCapture(e.Pointer);
        if (Parent is Grid grid)
        {
            SizeCommitted?.Invoke(this, Orientation == Orientation.Vertical ? grid.ColumnDefinitions[TargetIndex].ActualWidth : grid.RowDefinitions[TargetIndex].ActualHeight);
        }
    }
}
