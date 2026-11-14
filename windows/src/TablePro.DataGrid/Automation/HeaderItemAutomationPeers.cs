using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using TablePro.DataGrid.Model;
using Windows.Foundation;

namespace TablePro.DataGrid.Automation;

// A column's HeaderItem: Invoke sorts, Transform resizes, ItemStatus names the sort order, as the header element's
// peer does. A column the data no longer has reads as empty and off screen, as a cell does.
internal sealed partial class ColumnHeaderAutomationPeer(DataGridView grid, int column)
    : AutomationPeer, IInvokeProvider, ITransformProvider, IScrollItemProvider
{
    public int Column => column;

    public bool CanMove => false;

    public bool CanResize => Exists;

    public bool CanRotate => false;

    private bool Exists => column >= 0 && column < grid.ColumnCount;

    public void Invoke()
    {
        if (Exists)
        {
            grid.SortBy(column);
            RaiseAutomationEvent(AutomationEvents.InvokePatternOnInvoked);
        }
    }

    public void Move(double x, double y) => throw new InvalidOperationException("A column header does not move.");

    // UIA sizes in physical pixels, as the bounding rectangle reports them.
    public void Resize(double width, double height)
    {
        if (Exists)
        {
            grid.ResizeColumn(column, width / (grid.XamlRoot?.RasterizationScale ?? 1));
        }
    }

    public void Rotate(double degrees) => throw new InvalidOperationException("A column header does not rotate.");

    public void ScrollIntoView()
    {
        if (Exists && grid.RowCount > 0)
        {
            grid.ScrollIntoView(grid.FocusedRow, column);
        }
    }

    protected override string GetClassNameCore() => "DataGridColumnHeader";

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.HeaderItem;

    protected override string GetNameCore() => grid.ColumnName(column);

    protected override string GetItemStatusCore() =>
        grid.SortStatus(Exists && grid.Sort.Column == column ? grid.Sort.Direction : SortDirection.None);

    protected override string GetHelpTextCore() => (Exists ? grid.MaskNote(column) : null) ?? string.Empty;

    protected override bool IsContentElementCore() => false;

    protected override bool IsControlElementCore() => true;

    protected override bool IsEnabledCore() => Exists;

    protected override bool IsKeyboardFocusableCore() => false;

    protected override bool HasKeyboardFocusCore() => false;

    protected override int GetPositionInSetCore() => Exists ? column + 1 : 0;

    protected override int GetSizeOfSetCore() => grid.ColumnCount;

    protected override bool IsOffscreenCore() => GetBoundingRectangleCore().Width <= 0;

    protected override Rect GetBoundingRectangleCore() => grid.ColumnHeaderBoundsPhysical(column);

    protected override Point GetClickablePointCore()
    {
        var bounds = GetBoundingRectangleCore();
        return new Point(bounds.X + (bounds.Width / 2), bounds.Y + (bounds.Height / 2));
    }

    protected override IList<AutomationPeer>? GetChildrenCore() => null;

    protected override object? GetPatternCore(PatternInterface patternInterface) => patternInterface switch
    {
        PatternInterface.Invoke or PatternInterface.Transform or PatternInterface.ScrollItem => this,
        _ => base.GetPatternCore(patternInterface),
    };
}

// A row number's HeaderItem. Invoke selects the row, as a click on its number does.
internal sealed partial class RowHeaderAutomationPeer(DataGridView grid, int row)
    : AutomationPeer, IInvokeProvider, IScrollItemProvider
{
    public int Row => row;

    private bool Exists => row >= 0 && row < grid.RowCount && grid.ColumnCount > 0;

    public void Invoke()
    {
        if (Exists)
        {
            grid.SelectRows(row, extend: false);
            RaiseAutomationEvent(AutomationEvents.InvokePatternOnInvoked);
        }
    }

    public void ScrollIntoView()
    {
        if (Exists)
        {
            grid.ScrollIntoView(row, grid.FocusedColumn);
        }
    }

    protected override string GetClassNameCore() => "DataGridRowHeader";

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.HeaderItem;

    protected override string GetNameCore() => grid.RowNumberName(row);

    protected override bool IsContentElementCore() => false;

    protected override bool IsControlElementCore() => true;

    protected override bool IsEnabledCore() => Exists;

    protected override bool IsKeyboardFocusableCore() => false;

    protected override bool HasKeyboardFocusCore() => false;

    protected override int GetPositionInSetCore() => Exists ? row + 1 : 0;

    protected override int GetSizeOfSetCore() => grid.RowCount;

    protected override bool IsOffscreenCore() => !grid.IsRowNumberVisible(row);

    protected override Rect GetBoundingRectangleCore() => grid.RowNumberBoundsPhysical(row);

    protected override Point GetClickablePointCore()
    {
        var bounds = GetBoundingRectangleCore();
        return new Point(bounds.X + (bounds.Width / 2), bounds.Y + (bounds.Height / 2));
    }

    protected override IList<AutomationPeer>? GetChildrenCore() => null;

    protected override object? GetPatternCore(PatternInterface patternInterface) => patternInterface switch
    {
        PatternInterface.Invoke or PatternInterface.ScrollItem => this,
        _ => base.GetPatternCore(patternInterface),
    };
}
