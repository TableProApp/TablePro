using System.Collections;
using System.Collections.Specialized;
using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace TablePro.DataGrid;

// What the layouts ask the grid for. The grid computes its windows from its own scroll state (see RowsLayout).
internal interface IGridWindow
{
    // Rows to realize, as (First, Last); Last < First when none.
    (int First, int Last) RowWindow { get; }

    // Scrolling columns to show, as (First, Last); Last < First when none.
    (int First, int Last) ColumnWindow { get; }

    double RowHeight { get; }

    // Rows are arranged against this y, a multiple of 4,096 px, so arrange coordinates stay small in a 32M px grid.
    double OriginY { get; }

    double PaneWidth(bool frozen);

    double TotalHeight { get; }

    double HeaderHeight { get; }

    double ColumnX(int column);

    double ColumnWidth(int column);

    void PrepareRow(UIElement row, int index);

    void PrepareHeader(UIElement header, int column);
}

internal sealed class LayoutCounters
{
    public long Measures;
    public long ElementsRequested;
    public double MeasureMilliseconds;
    public double GetElementMilliseconds;

    public void Reset() => (Measures, ElementsRequested, MeasureMilliseconds, GetElementMilliseconds) = (0, 0, 0, 0);
}

// Not context.RealizationRect: ItemsRepeater takes a viewport past x and y 10,000 as cleared (ViewportManager.cpp).
internal sealed partial class RowsLayout(IGridWindow grid, bool frozen, LayoutCounters counters) : VirtualizingLayout
{
    private readonly Dictionary<int, UIElement> _realized = [];
    private readonly List<int> _leaving = [];

    public Dictionary<int, UIElement> Realized => _realized;

    // After the data was replaced: the repeater recycles every element itself.
    public void Forget() => _realized.Clear();

    protected override Size MeasureOverride(VirtualizingLayoutContext context, Size availableSize)
    {
        counters.Measures++;
        var started = Stopwatch.GetTimestamp();
        var (first, last) = grid.RowWindow;
        last = Math.Min(last, context.ItemCount - 1);
        _leaving.Clear();
        foreach (var (row, element) in _realized)
        {
            if (row < first || row > last)
            {
                context.RecycleElement(element);
                _leaving.Add(row);
            }
        }
        foreach (var row in _leaving)
        {
            _realized.Remove(row);
        }
        for (var row = first; row <= last; row++)
        {
            if (_realized.ContainsKey(row))
            {
                continue;
            }
            var requested = Stopwatch.GetTimestamp();
            // Without the flag ItemsRepeater recycles what this pass did not ask for, and one element served two rows.
            var element = context.GetOrCreateElementAt(row, ElementRealizationOptions.SuppressAutoRecycle);
            counters.GetElementMilliseconds += Stopwatch.GetElapsedTime(requested).TotalMilliseconds;
            counters.ElementsRequested++;
            grid.PrepareRow(element, row);
            _realized[row] = element;
        }
        var size = new Size(grid.PaneWidth(frozen), grid.RowHeight);
        foreach (var element in _realized.Values)
        {
            element.Measure(size);
        }
        counters.MeasureMilliseconds += Stopwatch.GetElapsedTime(started).TotalMilliseconds;
        return new Size(grid.PaneWidth(frozen), Math.Max(0, grid.TotalHeight - grid.OriginY));
    }

    protected override Size ArrangeOverride(VirtualizingLayoutContext context, Size finalSize)
    {
        var width = grid.PaneWidth(frozen);
        foreach (var (row, element) in _realized)
        {
            element.Arrange(new Rect(0, (row * grid.RowHeight) - grid.OriginY, width, grid.RowHeight));
        }
        return finalSize;
    }
}

// The header cells of the scrolling columns in the grid's column window. Item indices are column numbers.
internal sealed partial class HeaderLayout(IGridWindow grid) : VirtualizingLayout
{
    private readonly Dictionary<int, UIElement> _realized = [];
    private readonly List<int> _leaving = [];

    public Dictionary<int, UIElement> Realized => _realized;

    public void Forget() => _realized.Clear();

    protected override Size MeasureOverride(VirtualizingLayoutContext context, Size availableSize)
    {
        var (first, last) = grid.ColumnWindow;
        last = Math.Min(last, context.ItemCount - 1);
        _leaving.Clear();
        foreach (var (column, element) in _realized)
        {
            if (column < first || column > last)
            {
                context.RecycleElement(element);
                _leaving.Add(column);
            }
        }
        foreach (var column in _leaving)
        {
            _realized.Remove(column);
        }
        for (var column = Math.Max(0, first); column <= last; column++)
        {
            if (!_realized.ContainsKey(column))
            {
                var element = context.GetOrCreateElementAt(column, ElementRealizationOptions.SuppressAutoRecycle);
                grid.PrepareHeader(element, column);
                _realized[column] = element;
            }
        }
        var rowHeight = grid.HeaderHeight;
        foreach (var (column, element) in _realized)
        {
            element.Measure(new Size(grid.ColumnWidth(column), rowHeight));
        }
        return new Size(grid.PaneWidth(frozen: false), rowHeight);
    }

    protected override Size ArrangeOverride(VirtualizingLayoutContext context, Size finalSize)
    {
        var rowHeight = grid.HeaderHeight;
        foreach (var (column, element) in _realized)
        {
            element.Arrange(new Rect(grid.ColumnX(column), 0, grid.ColumnWidth(column), rowHeight));
        }
        return finalSize;
    }
}

// A second recycle of one element means two layouts held it, the auto-recycle trap.
internal sealed partial class ElementPool(Func<UIElement> create) : IElementFactory
{
    private readonly Stack<UIElement> _pool = new();
    private readonly HashSet<UIElement> _pooled = new(ReferenceEqualityComparer.Instance);

    public int Created { get; private set; }

    public int DuplicateRecycles { get; private set; }

    public IEnumerable<UIElement> Pooled => _pool;

    public UIElement GetElement(ElementFactoryGetArgs args)
    {
        if (_pool.TryPop(out var element))
        {
            _pooled.Remove(element);
            return element;
        }
        Created++;
        return create();
    }

    public void RecycleElement(ElementFactoryRecycleArgs args)
    {
        ArgumentNullException.ThrowIfNull(args);
        var element = args.Element;
        if (_pooled.Add(element))
        {
            _pool.Push(element);
        }
        else
        {
            DuplicateRecycles++;
        }
    }
}

// A repeater's items: only their count. Rows that arrive are announced as one Add at the end, so realized rows stay.
internal sealed partial class IndexList(int count) : IList, INotifyCollectionChanged
{
    public event NotifyCollectionChangedEventHandler? CollectionChanged;

    public int Count { get; private set; } = count;

    public bool IsFixedSize => false;

    public bool IsReadOnly => true;

    public bool IsSynchronized => false;

    public object SyncRoot => this;

    // Null keeps ItemsRepeater from setting a DataContext on each element.
    public object? this[int index]
    {
        get => null;
        set => throw new NotSupportedException();
    }

    public void Grow(int count)
    {
        if (count <= Count)
        {
            return;
        }
        var start = Count;
        var added = count - start;
        Count = count;
        CollectionChanged?.Invoke(this, new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Add, new IndexList(added), start));
    }

    public int Add(object? value) => throw new NotSupportedException();

    public void Clear() => throw new NotSupportedException();

    public bool Contains(object? value) => false;

    public int IndexOf(object? value) => -1;

    public void Insert(int index, object? value) => throw new NotSupportedException();

    public void Remove(object? value) => throw new NotSupportedException();

    public void RemoveAt(int index) => throw new NotSupportedException();

    public void CopyTo(Array array, int index)
    {
        ArgumentNullException.ThrowIfNull(array);
        for (var i = 0; i < Count; i++)
        {
            array.SetValue(null, index + i);
        }
    }

    public IEnumerator GetEnumerator()
    {
        for (var i = 0; i < Count; i++)
        {
            yield return null;
        }
    }
}

// Takes no anchor candidates: recycled rows as anchors moved the ScrollViewer's offset in 350 of 600 spike steps.
internal sealed partial class RowWindow : Canvas, IScrollAnchorProvider
{
    public UIElement? CurrentAnchor => null;

    public void RegisterAnchorCandidate(UIElement element)
    {
    }

    public void UnregisterAnchorCandidate(UIElement element)
    {
    }
}

// The header row's holder, so its recycled cells are no anchor candidates of the ScrollViewer either.
internal sealed partial class HeaderRow : Microsoft.UI.Xaml.Controls.Grid, IScrollAnchorProvider
{
    public UIElement? CurrentAnchor => null;

    public void RegisterAnchorCandidate(UIElement element)
    {
    }

    public void UnregisterAnchorCandidate(UIElement element)
    {
    }
}
