using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using TablePro.Core.Editing;
using Windows.Foundation;

namespace TablePro.App.Controls.DataGrid;

/// <summary>
/// What a screen reader sees of <see cref="DataGridView"/>. The grid draws pooled text slots on a canvas, which on their
/// own read as loose text with no row or column, so this peer stands in a table of cells: the Grid, Table and Selection
/// patterns on the grid, and a <see cref="DataGridCellAutomationPeer"/> per cell with GridItem, TableItem, Value,
/// SelectionItem and ScrollItem. Cell peers exist only once a client asks for them, and only the visible ones are
/// kept, so a million-row result costs nothing until Narrator looks and then only what is on screen.
/// </summary>
internal sealed partial class DataGridAutomationPeer : FrameworkElementAutomationPeer, IGridProvider, ITableProvider, ISelectionProvider
{
    // A selection can span every row of a large result; a client asking for it gets the cells on screen plus the
    // active one, which is what can be read out anyway.
    private const int MaxSelectionItems = 500;

    private readonly DataGridView _grid;
    private readonly Dictionary<(int Row, int Column), DataGridCellAutomationPeer> _cells = [];
    private int _announcedRows;
    private int _announcedColumns;

    public DataGridAutomationPeer(DataGridView owner)
        : base(owner)
    {
        _grid = owner;
        (_announcedRows, _announcedColumns) = (RowCount, ColumnCount);
    }

    public int RowCount => _grid.Source?.RowCount ?? 0;

    public int ColumnCount => _grid.Source?.Columns.Count ?? 0;

    public RowOrColumnMajor RowOrColumnMajor => RowOrColumnMajor.RowMajor;

    public bool CanSelectMultiple => true;

    public bool IsSelectionRequired => false;

    public IRawElementProviderSimple GetItem(int row, int column)
    {
        if (row < 0 || row >= RowCount || column < 0 || column >= ColumnCount)
        {
            throw new ArgumentOutOfRangeException(nameof(row), "The cell is outside the grid.");
        }

        return ProviderFromPeer(Cell(row, column));
    }

    public IRawElementProviderSimple[] GetColumnHeaders()
    {
        var headers = new IRawElementProviderSimple[_grid.HeaderElements.Count];
        for (var i = 0; i < headers.Length; i++)
        {
            headers[i] = ProviderFromPeer(CreatePeerForElement(_grid.HeaderElements[i]));
        }

        return headers;
    }

    // Row numbers are drawn, not elements, and each cell's name already says its row.
    public IRawElementProviderSimple[] GetRowHeaders() => [];

    public IRawElementProviderSimple[] GetSelection()
    {
        if (_grid.ActiveCell is not { } active)
        {
            return [];
        }

        var (firstRow, lastRow, firstColumn, lastColumn) = _grid.SelectionBounds;
        var (visibleFirstRow, visibleLastRow, visibleFirstColumn, visibleLastColumn) = _grid.VisibleCellRange();
        var items = new List<IRawElementProviderSimple> { ProviderFromPeer(Cell(active.Row, active.Column)) };
        for (var r = Math.Max(firstRow, visibleFirstRow); r <= Math.Min(lastRow, visibleLastRow) && items.Count < MaxSelectionItems; r++)
        {
            for (var c = Math.Max(firstColumn, visibleFirstColumn); c <= Math.Min(lastColumn, visibleLastColumn) && items.Count < MaxSelectionItems; c++)
            {
                if (r != active.Row || c != active.Column)
                {
                    items.Add(ProviderFromPeer(Cell(r, c)));
                }
            }
        }

        return [.. items];
    }

    /// <summary>The peer of a cell: the kept one when it is on screen, otherwise a fresh one nobody holds on to.</summary>
    internal DataGridCellAutomationPeer Cell(int row, int column)
    {
        if (_cells.TryGetValue((row, column), out var cached))
        {
            return cached;
        }

        var peer = new DataGridCellAutomationPeer(this, _grid, row, column);
        if (_grid.IsCellVisible(row, column) || _grid.ActiveCell is { } active && active.Row == row && active.Column == column)
        {
            _cells[(row, column)] = peer;
        }

        return peer;
    }

    internal IRawElementProviderSimple Provider(AutomationPeer peer) => ProviderFromPeer(peer);

    internal IRawElementProviderSimple? HeaderProvider(int column) =>
        column >= 0 && column < _grid.HeaderElements.Count ? ProviderFromPeer(CreatePeerForElement(_grid.HeaderElements[column])) : null;

    /// <summary>Drops the kept peers that scrolled away. Called after every viewport change, so it stays allocation-free when nothing went.</summary>
    internal void Prune()
    {
        if (_cells.Count == 0)
        {
            return;
        }

        List<(int, int)>? gone = null;
        var active = _grid.ActiveCell;
        foreach (var key in _cells.Keys)
        {
            var isActive = active is not null && active.Row == key.Row && active.Column == key.Column;
            if (!isActive && !_grid.IsCellVisible(key.Row, key.Column))
            {
                (gone ??= []).Add(key);
            }
        }

        if (gone is null)
        {
            return;
        }

        foreach (var key in gone)
        {
            _cells.Remove(key);
        }

        if (ListenerExists(AutomationEvents.StructureChanged))
        {
            RaiseAutomationEvent(AutomationEvents.StructureChanged);
        }
    }

    /// <summary>The source or its rows changed under the peers; every kept cell may now describe something else.</summary>
    internal void Invalidate()
    {
        _cells.Clear();
        var (rows, columns) = (RowCount, ColumnCount);
        if (ListenerExists(AutomationEvents.PropertyChanged))
        {
            if (rows != _announcedRows)
            {
                RaisePropertyChangedEvent(GridPatternIdentifiers.RowCountProperty, _announcedRows, rows);
            }

            if (columns != _announcedColumns)
            {
                RaisePropertyChangedEvent(GridPatternIdentifiers.ColumnCountProperty, _announcedColumns, columns);
            }
        }

        (_announcedRows, _announcedColumns) = (rows, columns);
        if (ListenerExists(AutomationEvents.StructureChanged))
        {
            RaiseAutomationEvent(AutomationEvents.StructureChanged);
        }
    }

    /// <summary>Keyboard focus came to the grid; the screen reader should land on the active cell, not the grid as a whole.</summary>
    internal void FocusEntered()
    {
        if (_grid.ActiveCell is { } active && ListenerExists(AutomationEvents.AutomationFocusChanged))
        {
            Cell(active.Row, active.Column).RaiseAutomationEvent(AutomationEvents.AutomationFocusChanged);
        }
    }

    /// <summary>
    /// Tells the screen reader where the active cell went, which makes Narrator read its column, row and value. A
    /// single cell is selected outright; an extended range invalidates the selection rather than naming every cell.
    /// </summary>
    internal void ActiveCellMoved(bool extended)
    {
        if (_grid.ActiveCell is not { } active)
        {
            return;
        }

        var cell = Cell(active.Row, active.Column);
        if (_grid.FocusState != FocusState.Unfocused && ListenerExists(AutomationEvents.AutomationFocusChanged))
        {
            cell.RaiseAutomationEvent(AutomationEvents.AutomationFocusChanged);
        }

        if (extended)
        {
            if (ListenerExists(AutomationEvents.SelectionPatternOnInvalidated))
            {
                RaiseAutomationEvent(AutomationEvents.SelectionPatternOnInvalidated);
            }
        }
        else if (ListenerExists(AutomationEvents.SelectionItemPatternOnElementSelected))
        {
            cell.RaiseAutomationEvent(AutomationEvents.SelectionItemPatternOnElementSelected);
        }
    }

    /// <summary>The active cell's text changed, by an edit or an undo.</summary>
    internal void ActiveValueChanged(string oldValue, string newValue)
    {
        if (_grid.ActiveCell is { } active && ListenerExists(AutomationEvents.PropertyChanged))
        {
            Cell(active.Row, active.Column).RaisePropertyChangedEvent(ValuePatternIdentifiers.ValueProperty, oldValue, newValue);
        }
    }

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.DataGrid;

    protected override string GetClassNameCore() => nameof(DataGridView);

    protected override string GetNameCore()
    {
        var name = base.GetNameCore();
        return string.IsNullOrEmpty(name) ? Strings.Get("Grid/DefaultName") : name;
    }

    protected override string GetItemStatusCore() =>
        _grid.Source is { } source
            ? Strings.Format("Grid/RowsAndColumns", Strings.Plural("Grid/RowCount", source.RowCount), Strings.Plural("Grid/ColumnCount", source.Columns.Count))
            : string.Empty;

    protected override object? GetPatternCore(PatternInterface patternInterface) => patternInterface switch
    {
        PatternInterface.Grid or PatternInterface.Table or PatternInterface.Selection => this,

        // Scrolling belongs to the scroll viewer inside; its pattern is lent rather than reimplemented.
        PatternInterface.Scroll => CreatePeerForElement(_grid.Scroller)?.GetPattern(PatternInterface.Scroll),
        _ => base.GetPatternCore(patternInterface),
    };

    protected override IList<AutomationPeer> GetChildrenCore()
    {
        var children = new List<AutomationPeer>();
        foreach (var header in _grid.HeaderElements)
        {
            children.Add(CreatePeerForElement(header));
        }

        var (firstRow, lastRow, firstColumn, lastColumn) = _grid.VisibleCellRange();
        for (var r = firstRow; r <= lastRow; r++)
        {
            for (var c = firstColumn; c <= lastColumn; c++)
            {
                children.Add(Cell(r, c));
            }
        }

        if (_grid.EditorElement is { Visibility: Visibility.Visible } editor)
        {
            children.Add(CreatePeerForElement(editor));
        }

        return children;
    }

    protected override object? GetFocusedElementCore()
    {
        // While the in-place editor is open it holds focus itself; otherwise the grid's focus is the active cell's.
        if (_grid.EditorElement is { Visibility: Visibility.Visible })
        {
            return base.GetFocusedElementCore();
        }

        return _grid.ActiveCell is { } active ? Cell(active.Row, active.Column) : base.GetFocusedElementCore();
    }

    protected override object? GetElementFromPointCore(Point pointInWindowCoordinates) =>
        _grid.CellAt(pointInWindowCoordinates) is { } cell ? Cell(cell.Row, cell.Column) : base.GetElementFromPointCore(pointInWindowCoordinates);

    /// <summary>The kept cells in the order <see cref="GetChildrenCore"/> lists them, for sibling navigation.</summary>
    internal AutomationPeer? Sibling(DataGridCellAutomationPeer cell, int step)
    {
        var (firstRow, lastRow, firstColumn, lastColumn) = _grid.VisibleCellRange();
        if (cell.Row < firstRow || cell.Row > lastRow || cell.Column < firstColumn || cell.Column > lastColumn)
        {
            return null;
        }

        var width = lastColumn - firstColumn + 1;
        var index = ((cell.Row - firstRow) * width) + (cell.Column - firstColumn) + step;
        if (index < 0)
        {
            // Before the first cell come the column headers.
            return _grid.HeaderElements is { Count: > 0 } headers ? CreatePeerForElement(headers[^1]) : null;
        }

        if (index >= (lastRow - firstRow + 1) * width)
        {
            return null;
        }

        return Cell(firstRow + (index / width), firstColumn + (index % width));
    }
}

/// <summary>
/// One cell, built on demand. Its name is the column and the row ("email, row 12") and its value the text the cell
/// shows, so Narrator reads "email, row 12, alice@example.com", the way Windows Forms grid cells read.
/// </summary>
internal sealed partial class DataGridCellAutomationPeer : AutomationPeer, IGridItemProvider, ITableItemProvider, IValueProvider, ISelectionItemProvider, IScrollItemProvider
{
    private readonly DataGridAutomationPeer _owner;
    private readonly DataGridView _grid;

    public DataGridCellAutomationPeer(DataGridAutomationPeer owner, DataGridView grid, int row, int column)
    {
        _owner = owner;
        _grid = grid;
        Row = row;
        Column = column;
    }

    public int Row { get; }

    public int Column { get; }

    public int RowSpan => 1;

    public int ColumnSpan => 1;

    public IRawElementProviderSimple ContainingGrid => _owner.Provider(_owner);

    public bool IsReadOnly => _grid.Source is not { IsEditable: true } source || Row >= source.RowCount || source.GetRowState(Row) == RowEditState.Deleted;

    public string Value => _grid.CellText(Row, Column);

    public bool IsSelected
    {
        get
        {
            var (firstRow, lastRow, firstColumn, lastColumn) = _grid.SelectionBounds;
            return Row >= firstRow && Row <= lastRow && Column >= firstColumn && Column <= lastColumn;
        }
    }

    public IRawElementProviderSimple SelectionContainer => _owner.Provider(_owner);

    public IRawElementProviderSimple[] GetColumnHeaderItems() => _owner.HeaderProvider(Column) is { } header ? [header] : [];

    public IRawElementProviderSimple[] GetRowHeaderItems() => [];

    public void SetValue(string value)
    {
        if (IsReadOnly)
        {
            throw new InvalidOperationException("This cell is read-only.");
        }

        if (!_grid.Source!.TrySetValue(Row, Column, value, out var error))
        {
            throw new ArgumentException(error ?? Strings.Get("Grid/ValueNotAccepted"), nameof(value));
        }
    }

    public void Select() => _grid.SelectCell(Row, Column);

    public void AddToSelection() => _grid.SelectCell(Row, Column, extend: true);

    // The selection is one rectangle, which cannot have a hole; taking a cell out is not something it can do.
    public void RemoveFromSelection()
    {
    }

    public void ScrollIntoView() => _grid.ScrollIntoView(Row, Column);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.DataItem;

    protected override string GetLocalizedControlTypeCore() => Strings.Get("Grid/CellControlType");

    protected override string GetClassNameCore() => "DataGridCell";

    protected override string GetNameCore() => Strings.Format("Grid/CellName", _grid.ColumnName(Column), Row + 1);

    protected override string GetAutomationIdCore() => $"Cell_{Row}_{Column}";

    protected override string GetItemStatusCore() => _grid.CellStatus(Row, Column);

    protected override string GetHelpTextCore() => _grid.ColumnType(Column);

    protected override Rect GetBoundingRectangleCore() => _grid.CellBoundsForAutomation(Row, Column);

    protected override bool IsOffscreenCore() => !_grid.IsCellVisible(Row, Column);

    protected override bool IsContentElementCore() => true;

    protected override bool IsControlElementCore() => true;

    protected override bool IsEnabledCore() => true;

    protected override bool IsKeyboardFocusableCore() => true;

    protected override bool HasKeyboardFocusCore() =>
        _grid.FocusState != FocusState.Unfocused && _grid.ActiveCell is { } active && active.Row == Row && active.Column == Column;

    protected override void SetFocusCore()
    {
        _grid.SelectCell(Row, Column);
        _grid.Focus(FocusState.Programmatic);
    }

    protected override Point GetClickablePointCore()
    {
        var bounds = GetBoundingRectangleCore();
        return new Point(bounds.X + (bounds.Width / 2), bounds.Y + (bounds.Height / 2));
    }

    protected override object? GetPatternCore(PatternInterface patternInterface) => patternInterface switch
    {
        PatternInterface.GridItem or PatternInterface.TableItem or PatternInterface.Value
            or PatternInterface.SelectionItem or PatternInterface.ScrollItem => this,
        _ => null,
    };

    protected override IList<AutomationPeer>? GetChildrenCore() => null;

    // Built outside the visual tree, so the framework cannot work out where the cell sits; the grid peer can.
    protected override object? NavigateCore(AutomationNavigationDirection direction) => direction switch
    {
        AutomationNavigationDirection.Parent => _owner,
        AutomationNavigationDirection.NextSibling => _owner.Sibling(this, 1),
        AutomationNavigationDirection.PreviousSibling => _owner.Sibling(this, -1),
        _ => null,
    };
}
