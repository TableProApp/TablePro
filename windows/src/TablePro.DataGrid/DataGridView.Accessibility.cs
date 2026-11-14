using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using TablePro.DataGrid.Automation;
using TablePro.DataGrid.Model;
using Windows.Foundation;

namespace TablePro.DataGrid;

public sealed partial class DataGridView
{
    // The rows in view, top to bottom: what the automation tree lists a row header and cells for.
    internal IEnumerable<int> VisibleRowNumbers()
    {
        var (first, last) = VisibleRows();
        for (var row = first; row <= last; row++)
        {
            yield return row;
        }
    }

    // The frozen columns, then the scrolling ones in view.
    internal IEnumerable<int> VisibleColumns()
    {
        for (var column = 0; column < _columns.FrozenCount && column < ColumnCount; column++)
        {
            yield return column;
        }
        var (first, last) = _columnWindow;
        for (var column = Math.Max(first, _columns.FrozenCount); column <= last && column < ColumnCount; column++)
        {
            yield return column;
        }
    }

    internal string ColumnName(int column) => column >= 0 && column < ColumnCount ? _names[column] : string.Empty;

    // As the row number is drawn.
    internal string RowNumberName(int row) =>
        row >= 0 && row < RowCount ? ((long)row + 1).ToString(CultureInfo.CurrentCulture) : string.Empty;

    internal bool IsRowNumberVisible(int row)
    {
        var (first, last) = VisibleRows();
        return row >= 0 && row < RowCount && row >= first && row <= last;
    }

    internal Rect RowNumberBoundsPhysical(int row)
    {
        if (!IsRowNumberVisible(row) || XamlRoot is null)
        {
            return default;
        }
        var bounds = _frozenContent.TransformToVisual(null).TransformBounds(
            new Rect(0, row * _rowHeight, _columns.RowHeaderWidth, _rowHeight));
        return PhysicalBounds(bounds);
    }

    // The header element bound to the column, while it is realized.
    internal Rect ColumnHeaderBoundsPhysical(int column)
    {
        if (column < 0 || column >= ColumnCount || HeaderCell(column) is not { Column: var bound } header
            || bound != column || XamlRoot is null)
        {
            return default;
        }
        return PhysicalBounds(header.TransformToVisual(null).TransformBounds(
            new Rect(0, 0, header.ActualWidth, header.ActualHeight)));
    }

    // A cell, or a row number in the frozen pane, under a point in physical pixels from the window's client area.
    internal AutomationPeer? ItemPeerAt(Point physical)
    {
        if (XamlRoot is null || FrameworkElementAutomationPeer.CreatePeerForElement(this) is not DataGridAutomationPeer peer)
        {
            return null;
        }
        var scale = XamlRoot.RasterizationScale;
        var point = new Point(physical.X / scale, physical.Y / scale);
        foreach (var frozen in new[] { true, false })
        {
            var pane = frozen ? (UIElement)_frozenContent : _content;
            var local = pane.TransformToVisual(null).Inverse.TransformPoint(point);
            switch (HitTest(frozen, local))
            {
                case { Column: >= 0 } hit when IsCellVisible(hit.Row, hit.Column):
                    return peer.Cell(hit.Row, hit.Column);
                case { Column: < 0 } hit when frozen && IsRowNumberVisible(hit.Row):
                    return peer.RowHeader(hit.Row);
            }
        }
        return null;
    }

    // Each column whose sort order changed says so on its header peer, which a client may hold off screen too.
    private void RaiseSortStatus(GridSort previous, GridSort current)
    {
        if (!AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged)
            || FrameworkElementAutomationPeer.FromElement(this) is not DataGridAutomationPeer peer)
        {
            return;
        }
        foreach (var column in new[] { previous.Column, current.Column }.Distinct())
        {
            var before = previous.Column == column ? previous.Direction : SortDirection.None;
            var after = current.Column == column ? current.Direction : SortDirection.None;
            if (column >= 0 && column < ColumnCount && before != after)
            {
                peer.ColumnHeader(column).RaisePropertyChangedEvent(
                    AutomationElementIdentifiers.ItemStatusProperty, SortStatus(before), SortStatus(after));
            }
        }
    }

    private Rect PhysicalBounds(Rect bounds)
    {
        var scale = XamlRoot.RasterizationScale;
        return new Rect(bounds.X * scale, bounds.Y * scale, bounds.Width * scale, bounds.Height * scale);
    }
}
