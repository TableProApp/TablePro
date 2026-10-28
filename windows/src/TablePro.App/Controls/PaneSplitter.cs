using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

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

    public PaneSplitter()
    {
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        Children.Add(_line);
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += OnReleased;
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
        CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || Parent is not Grid grid)
        {
            return;
        }

        var point = e.GetCurrentPoint(grid).Position;
        var delta = (Orientation == Orientation.Vertical ? point.X : point.Y) - _start;
        var size = Math.Max(48, _startSize + (Invert ? -delta : delta));
        if (Orientation == Orientation.Vertical)
        {
            var column = grid.ColumnDefinitions[TargetIndex];
            column.Width = new GridLength(Math.Min(size, Math.Max(48, grid.ActualWidth - 160)));
        }
        else
        {
            var row = grid.RowDefinitions[TargetIndex];
            row.Height = new GridLength(Math.Min(size, Math.Max(48, grid.ActualHeight - 80)));
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
