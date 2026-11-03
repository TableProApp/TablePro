namespace TablePro.Editor.Model;

// Scintilla's SplitVector: an edit near the last one moves only the items between them, not the whole list.
internal sealed class GapList<T>
{
    private T[] _items;
    private int _gapStart;
    private int _gapLength;

    public GapList(int capacity = 16)
    {
        _items = new T[Math.Max(16, capacity)];
        _gapLength = _items.Length;
    }

    public int Count => _items.Length - _gapLength;

    public T this[int index]
    {
        get
        {
            if ((uint)index >= (uint)Count)
            {
                throw new ArgumentOutOfRangeException(nameof(index));
            }
            return _items[index < _gapStart ? index : index + _gapLength];
        }
        set
        {
            if ((uint)index >= (uint)Count)
            {
                throw new ArgumentOutOfRangeException(nameof(index));
            }
            _items[index < _gapStart ? index : index + _gapLength] = value;
        }
    }

    public void Clear()
    {
        _gapStart = 0;
        _gapLength = _items.Length;
    }

    public void InsertRange(int index, int count, T value)
    {
        if (index < 0 || index > Count)
        {
            throw new ArgumentOutOfRangeException(nameof(index));
        }
        if (count <= 0)
        {
            return;
        }
        if (_gapLength < count)
        {
            Grow(count);
        }
        MoveGap(index);
        _items.AsSpan(_gapStart, count).Fill(value);
        _gapStart += count;
        _gapLength -= count;
    }

    public void RemoveRange(int index, int count)
    {
        if (index < 0 || count < 0 || index + count > Count)
        {
            throw new ArgumentOutOfRangeException(nameof(index));
        }
        if (count == 0)
        {
            return;
        }
        MoveGap(index);
        _gapLength += count;
    }

    private void MoveGap(int index)
    {
        if (index < _gapStart)
        {
            var moving = _gapStart - index;
            Array.Copy(_items, index, _items, index + _gapLength, moving);
        }
        else if (index > _gapStart)
        {
            var moving = index - _gapStart;
            Array.Copy(_items, _gapStart + _gapLength, _items, _gapStart, moving);
        }
        _gapStart = index;
    }

    private void Grow(int needed)
    {
        var count = Count;
        var capacity = Math.Max(_items.Length * 2, count + needed + 16);
        var items = new T[capacity];
        Array.Copy(_items, 0, items, 0, _gapStart);
        var after = count - _gapStart;
        Array.Copy(_items, _gapStart + _gapLength, items, capacity - after, after);
        _items = items;
        _gapLength = capacity - count;
    }
}
