using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace TablePro.App.Controls.DataGrid;

/// <summary>A column header: name, sort glyph and a resize grip on its right edge.</summary>
internal sealed partial class HeaderCell : Grid
{
    private readonly TextBlock _name;
    private readonly FontIcon _sortGlyph;
    private readonly ResizeGrip _grip;
    private readonly int _column;
    private double _dragStartX;
    private double _dragStartWidth;
    private bool _resizing;

    public HeaderCell(int column, string name, string tooltip, bool numeric)
    {
        _column = column;
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });

        _name = new TextBlock
        {
            Text = name,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 4, 0),
            TextAlignment = numeric ? TextAlignment.Right : TextAlignment.Left,
            IsTextScaleFactorEnabled = false,
        };
        Children.Add(_name);

        _sortGlyph = new FontIcon { FontSize = 10, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 4, 0) };
        SetColumn(_sortGlyph, 1);
        Children.Add(_sortGlyph);

        _grip = new ResizeGrip();
        SetColumn(_grip, 2);
        _grip.PointerPressed += OnGripPressed;
        _grip.PointerMoved += OnGripMoved;
        _grip.PointerReleased += OnGripReleased;
        _grip.DoubleTapped += (_, e) =>
        {
            AutoFitRequested?.Invoke(this, _column);
            e.Handled = true;
        };
        Children.Add(_grip);

        ToolTipService.SetToolTip(this, tooltip);
        Tapped += OnTapped;
    }

    public event EventHandler<SortRequestedEventArgs>? Clicked;

    public event EventHandler<(int Column, double Width)>? Resized;

    public event EventHandler<int>? AutoFitRequested;

    public void ApplyTheme(Brush text, Brush secondary)
    {
        _name.Foreground = text;
        _sortGlyph.Foreground = secondary;
    }

    public void SetSort(bool? descending)
    {
        _sortGlyph.Visibility = descending is null ? Visibility.Collapsed : Visibility.Visible;
        _sortGlyph.Glyph = descending == true ? "" : "";
    }

    private void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        if (_resizing || ReferenceEquals(e.OriginalSource, _grip))
        {
            return;
        }

        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        Clicked?.Invoke(this, new SortRequestedEventArgs(_column, shift));
    }

    private void OnGripPressed(object sender, PointerRoutedEventArgs e)
    {
        _resizing = true;
        _dragStartX = e.GetCurrentPoint(null).Position.X;
        _dragStartWidth = ActualWidth;
        _grip.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnGripMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_resizing)
        {
            return;
        }

        var delta = e.GetCurrentPoint(null).Position.X - _dragStartX;
        Resized?.Invoke(this, (_column, _dragStartWidth + delta));
        e.Handled = true;
    }

    private void OnGripReleased(object sender, PointerRoutedEventArgs e)
    {
        _grip.ReleasePointerCapture(e.Pointer);
        e.Handled = true;

        // The tap that ends a drag must not also sort, so the flag clears after the tap is dispatched.
        DispatcherQueue.TryEnqueue(() => _resizing = false);
    }

    /// <summary>The resize cursor is only settable from a subclass through ProtectedCursor.</summary>
    private sealed partial class ResizeGrip : Grid
    {
        public ResizeGrip()
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        }
    }
}
