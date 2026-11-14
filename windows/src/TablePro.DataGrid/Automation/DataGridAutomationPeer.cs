using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using TablePro.DataGrid.Model;

namespace TablePro.DataGrid.Automation;

// Peer shapes follow WinUI.TableView's table and cell peers (MIT, https://github.com/w-ahmad/WinUI.TableView v1.5.1).
internal sealed partial class DataGridAutomationPeer(DataGridView owner) : FrameworkElementAutomationPeer(owner),
    IGridProvider, ITableProvider, ISelectionProvider
{
    // A client reading a selection larger than this gets its first cells; the selection itself has no limit.
    public const int MaxSelectionPeers = 10_000;

    private readonly Dictionary<long, CellAutomationPeer> _cells = [];
    private readonly Dictionary<int, RowHeaderAutomationPeer> _rowHeaders = [];
    private readonly Dictionary<int, ColumnHeaderAutomationPeer> _columnHeaders = [];

    public int RowCount => owner.RowCount;

    public int ColumnCount => owner.ColumnCount;

    public RowOrColumnMajor RowOrColumnMajor => RowOrColumnMajor.RowMajor;

    public bool CanSelectMultiple => true;

    public bool IsSelectionRequired => false;

    public int CachedCells => _cells.Count;

    public CellAutomationPeer Cell(int row, int column)
    {
        var key = ((long)row << 20) | (uint)column;
        if (!_cells.TryGetValue(key, out var peer))
        {
            if (_cells.Count >= 8192)
            {
                Prune();
            }
            peer = new CellAutomationPeer(owner, this, row, column);
            peer.SetParent(this);
            _cells[key] = peer;
        }
        return peer;
    }

    // One per row in use, as for cells, so the tree and a cell's TableItem hand a client the same provider.
    public RowHeaderAutomationPeer RowHeader(int row)
    {
        if (!_rowHeaders.TryGetValue(row, out var peer))
        {
            if (_rowHeaders.Count >= 8192)
            {
                Prune();
            }
            peer = new RowHeaderAutomationPeer(owner, row);
            peer.SetParent(this);
            _rowHeaders[row] = peer;
        }
        return peer;
    }

    // One per column, not the header element: ItemsRepeater hands an element to another column as it scrolls.
    public ColumnHeaderAutomationPeer ColumnHeader(int column)
    {
        if (!_columnHeaders.TryGetValue(column, out var peer))
        {
            peer = new ColumnHeaderAutomationPeer(owner, column);
            peer.SetParent(this);
            _columnHeaders[column] = peer;
        }
        return peer;
    }

    public IRawElementProviderSimple Provider(AutomationPeer peer) => ProviderFromPeer(peer);

    public AutomationPeer? Peer(IRawElementProviderSimple provider) => PeerFromProvider(provider);

    // After the edits or the data changed; each held cell whose ItemStatus moved raises the change.
    public void RefreshStatuses(bool raise)
    {
        foreach (var cell in _cells.Values)
        {
            cell.RefreshStatus(raise);
        }
    }

    // Any cell, on screen or not. ScrollItem on the cell brings it into view.
    public IRawElementProviderSimple? GetItem(int row, int column) =>
        row < 0 || row >= RowCount || column < 0 || column >= ColumnCount ? null : ProviderFromPeer(Cell(row, column));

    // Clients read none back on Windows App SDK 2.6.4, a WinUI bug fixed after it (microsoft-ui-xaml#11820); each
    // cell's TableItem gives its column header, on screen or not.
    public IRawElementProviderSimple[] GetColumnHeaders()
    {
        var headers = new IRawElementProviderSimple[ColumnCount];
        for (var column = 0; column < headers.Length; column++)
        {
            headers[column] = ProviderFromPeer(ColumnHeader(column));
        }
        return headers;
    }

    // The rows in view: a million row headers would not fit one call. A cell's TableItem reaches any row's.
    public IRawElementProviderSimple[] GetRowHeaders() =>
        [.. owner.VisibleRowNumbers().Select(row => ProviderFromPeer(RowHeader(row)))];

    public IRawElementProviderSimple[] GetSelection()
    {
        var range = owner.SelectionRange;
        if (range.IsEmpty)
        {
            return [];
        }
        var count = (int)Math.Min(range.CellCount, MaxSelectionPeers);
        var providers = new IRawElementProviderSimple[count];
        var index = 0;
        for (var row = range.FirstRow; row <= range.LastRow && index < count; row++)
        {
            for (var column = range.FirstColumn; column <= range.LastColumn && index < count; column++)
            {
                providers[index++] = ProviderFromPeer(Cell(row, column));
            }
        }
        return providers;
    }

    protected override string GetClassNameCore() => "DataGridView";

    // A client asking for the focus gets the focused cell, as with a grid of elements.
    protected override object? GetFocusedElementCore() =>
        owner.FocusState != Microsoft.UI.Xaml.FocusState.Unfocused && owner.RowCount > 0 && owner.ColumnCount > 0
            ? Cell(owner.FocusedRow, owner.FocusedColumn)
            : base.GetFocusedElementCore();

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.DataGrid;

    protected override object? GetPatternCore(PatternInterface patternInterface) => patternInterface switch
    {
        PatternInterface.Grid or PatternInterface.Table or PatternInterface.Selection => this,
        _ => base.GetPatternCore(patternInterface),
    };

    // The column headers in view, then each row in view as its row header and its cells.
    protected override IList<AutomationPeer> GetChildrenCore()
    {
        var children = new List<AutomationPeer>(base.GetChildrenCore() ?? []);
        foreach (var column in owner.VisibleColumns())
        {
            children.Add(ColumnHeader(column));
        }
        var row = -1;
        foreach (var (cellRow, column) in owner.VisibleCells())
        {
            if (cellRow != row)
            {
                row = cellRow;
                children.Add(RowHeader(row));
            }
            children.Add(Cell(cellRow, column));
        }
        return children;
    }

    private void Prune()
    {
        List<long>? gone = null;
        foreach (var (key, peer) in _cells)
        {
            if (!owner.IsCellVisible(peer.Row, peer.Column))
            {
                (gone ??= []).Add(key);
            }
        }
        foreach (var key in gone ?? [])
        {
            _cells.Remove(key);
        }
        foreach (var row in _rowHeaders.Keys.Where(row => !owner.IsRowNumberVisible(row)).ToList())
        {
            _rowHeaders.Remove(row);
        }
    }
}

internal sealed partial class CellAutomationPeer(DataGridView grid, DataGridAutomationPeer gridPeer, int row, int column)
    : AutomationPeer, IGridItemProvider, ITableItemProvider, ISelectionItemProvider, IScrollItemProvider
{
    private string _status = grid.CellStatus(row, column);

    public int Row => row;

    public int Column => column;

    public int RowSpan => 1;

    public int ColumnSpan => 1;

    public IRawElementProviderSimple ContainingGrid => gridPeer.Provider(gridPeer);

    public bool IsSelected => grid.SelectionRange.Contains(row, column);

    public IRawElementProviderSimple SelectionContainer => ContainingGrid;

    public IRawElementProviderSimple[] GetColumnHeaderItems() =>
        grid.Contains(row, column) ? [gridPeer.Provider(gridPeer.ColumnHeader(column))] : [];

    public IRawElementProviderSimple[] GetRowHeaderItems() =>
        grid.Contains(row, column) ? [gridPeer.Provider(gridPeer.RowHeader(row))] : [];

    // A cell the data no longer holds takes no selection, which the grid would clamp onto another cell.
    public void Select()
    {
        if (grid.Contains(row, column))
        {
            grid.SelectCell(row, column, extend: false);
        }
    }

    public void AddToSelection()
    {
        if (grid.Contains(row, column))
        {
            grid.SelectCell(row, column, extend: true);
        }
    }

    public void RemoveFromSelection()
    {
    }

    public void ScrollIntoView()
    {
        if (grid.Contains(row, column))
        {
            grid.ScrollIntoView(row, column);
        }
    }

    public void RefreshStatus(bool raise)
    {
        var status = grid.CellStatus(row, column);
        if (string.Equals(status, _status, StringComparison.Ordinal))
        {
            return;
        }
        var previous = _status;
        _status = status;
        if (raise)
        {
            RaisePropertyChangedEvent(AutomationElementIdentifiers.ItemStatusProperty, previous, status);
        }
    }

    protected override string GetClassNameCore() => "DataGridCell";

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.DataItem;

    protected override string GetNameCore() => grid.CellName(row, column);

    // The pending change, as the macOS grid's VoiceOver suffixes; the name stays the value.
    protected override string GetItemStatusCore() => _status = grid.CellStatus(row, column);

    protected override bool IsContentElementCore() => true;

    protected override bool IsControlElementCore() => true;

    protected override bool IsEnabledCore() => true;

    protected override bool IsKeyboardFocusableCore() => true;

    protected override bool HasKeyboardFocusCore() => grid.HasFocusedCell(row, column);

    protected override bool IsOffscreenCore() => !grid.IsCellVisible(row, column);

    protected override Windows.Foundation.Rect GetBoundingRectangleCore() => grid.CellBoundsPhysical(row, column);

    protected override Windows.Foundation.Point GetClickablePointCore()
    {
        var bounds = GetBoundingRectangleCore();
        return new Windows.Foundation.Point(bounds.X + (bounds.Width / 2), bounds.Y + (bounds.Height / 2));
    }

    protected override IList<AutomationPeer>? GetChildrenCore() => null;

    protected override void SetFocusCore()
    {
        grid.Focus(Microsoft.UI.Xaml.FocusState.Programmatic);
        Select();
    }

    protected override object? GetPatternCore(PatternInterface patternInterface) => patternInterface switch
    {
        PatternInterface.GridItem or PatternInterface.TableItem or PatternInterface.SelectionItem or PatternInterface.ScrollItem
            => this,
        _ => base.GetPatternCore(patternInterface),
    };
}

// The HeaderItem control type: Invoke sorts, Transform resizes, ItemStatus names the sort order.
internal sealed partial class HeaderAutomationPeer(HeaderCell owner, DataGridView grid) : FrameworkElementAutomationPeer(owner),
    IInvokeProvider, ITransformProvider
{
    public bool CanMove => false;

    public bool CanResize => owner.Column >= 0;

    public bool CanRotate => false;

    public void Invoke()
    {
        if (owner.Column >= 0)
        {
            grid.SortBy(owner.Column);
        }
        else
        {
            grid.SelectAll();
        }
        RaiseAutomationEvent(AutomationEvents.InvokePatternOnInvoked);
    }

    public void Move(double x, double y) => throw new InvalidOperationException("A column header does not move.");

    // UIA sizes in physical pixels, as the bounding rectangle reports them.
    public void Resize(double width, double height)
    {
        if (owner.Column < 0)
        {
            throw new InvalidOperationException("The corner header does not resize.");
        }
        grid.ResizeColumn(owner.Column, width / (owner.XamlRoot?.RasterizationScale ?? 1));
    }

    public void Rotate(double degrees) => throw new InvalidOperationException("A column header does not rotate.");

    protected override string GetClassNameCore() => "DataGridColumnHeader";

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.HeaderItem;

    protected override string GetNameCore() => owner.Title;

    protected override string GetItemStatusCore() => grid.SortStatus(owner.SortDirection);

    // A column's header is its column peer in the control view; the element serves whichever column is in view.
    protected override bool IsControlElementCore() => owner.Column < 0;

    protected override bool IsContentElementCore() => false;

    protected override object? GetElementFromPointCore(Windows.Foundation.Point pointInWindowCoordinates) =>
        owner.Column >= 0 && CreatePeerForElement(grid) is DataGridAutomationPeer peer ? peer.ColumnHeader(owner.Column) : this;

    protected override object? GetPatternCore(PatternInterface patternInterface) => patternInterface switch
    {
        PatternInterface.Invoke or PatternInterface.Transform => this,
        _ => base.GetPatternCore(patternInterface),
    };

    protected override IList<AutomationPeer>? GetChildrenCore() => null;
}

// A pane's canvas. Drawn cells have no element to hit, so UIA's point queries come here and get the cell's peer.
internal sealed partial class PaneAutomationPeer(PaneContent owner, DataGridView grid) : FrameworkElementAutomationPeer(owner)
{
    protected override string GetClassNameCore() => "DataGridPane";

    protected override bool IsControlElementCore() => false;

    protected override bool IsContentElementCore() => false;

    // The grid's peer lists the cells; a pane holds only an open editor.
    protected override IList<AutomationPeer>? GetChildrenCore() =>
        grid.EditorIn(owner.IsFrozen) is { } editor && CreatePeerForElement(editor) is { } peer
            ? new List<AutomationPeer> { peer }
            : null;

    // XAML passes physical pixels from the window's client area here (ElementProviderFromPointImpl, UIAWindow.cpp).
    protected override object? GetElementFromPointCore(Windows.Foundation.Point pointInWindowCoordinates) =>
        grid.ItemPeerAt(pointInWindowCoordinates) ?? base.GetElementFromPointCore(pointInWindowCoordinates);
}
