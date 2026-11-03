namespace TablePro.Editor.Model;

// Each node caches its length and its count of '\n', so an edit and a line lookup walk one root-to-leaf path.
internal sealed class Rope
{
    internal const int MaxLeaf = 2048;

    // New leaves start three quarters full, so typing into one rarely has to split it.
    private const int BuildLeaf = MaxLeaf * 3 / 4;

    private Node _root = Node.Empty();

    public int Length => _root.Length;

    public int LineBreaks => _root.Breaks;

    internal int Height => _root.Height;

    public void SetText(ReadOnlySpan<char> text) => _root = Build(text);

    public char CharAt(int offset)
    {
        if ((uint)offset >= (uint)_root.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }
        var node = _root;
        while (!node.IsLeaf)
        {
            if (offset < node.Left!.Length)
            {
                node = node.Left;
            }
            else
            {
                offset -= node.Left.Length;
                node = node.Right!;
            }
        }
        return node.Chars![offset];
    }

    public void CopyTo(int offset, Span<char> destination)
    {
        if (offset < 0 || offset + destination.Length > _root.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }
        var written = 0;
        foreach (var chunk in Chunks(offset, destination.Length))
        {
            chunk.Span.CopyTo(destination[written..]);
            written += chunk.Length;
        }
    }

    public string GetText(int offset, int length)
    {
        if (length == 0)
        {
            return string.Empty;
        }
        return string.Create(length, (this, offset), static (span, state) => state.Item1.CopyTo(state.offset, span));
    }

    // Valid only until the next edit.
    public IEnumerable<ReadOnlyMemory<char>> Chunks(int offset, int length)
    {
        if (length <= 0)
        {
            yield break;
        }
        var stack = new Stack<Node>();
        var node = _root;
        var skip = offset;
        while (!node.IsLeaf)
        {
            if (skip < node.Left!.Length)
            {
                stack.Push(node.Right!);
                node = node.Left;
            }
            else
            {
                skip -= node.Left.Length;
                node = node.Right!;
            }
        }
        var remaining = length;
        while (true)
        {
            var take = Math.Min(node.Length - skip, remaining);
            if (take > 0)
            {
                yield return new ReadOnlyMemory<char>(node.Chars, skip, take);
                remaining -= take;
            }
            if (remaining == 0 || stack.Count == 0)
            {
                yield break;
            }
            skip = 0;
            node = stack.Pop();
            while (!node.IsLeaf)
            {
                stack.Push(node.Right!);
                node = node.Left!;
            }
        }
    }

    public int LineStart(int line)
    {
        if (line == 0)
        {
            return 0;
        }
        if (line < 0 || line > _root.Breaks)
        {
            throw new ArgumentOutOfRangeException(nameof(line));
        }
        var node = _root;
        var offset = 0;
        var wanted = line;
        while (!node.IsLeaf)
        {
            if (wanted <= node.Left!.Breaks)
            {
                node = node.Left;
            }
            else
            {
                wanted -= node.Left.Breaks;
                offset += node.Left.Length;
                node = node.Right!;
            }
        }
        var chars = node.Chars.AsSpan(0, node.Length);
        var index = -1;
        for (var i = 0; i < wanted; i++)
        {
            index += 1 + chars[(index + 1)..].IndexOf('\n');
        }
        return offset + index + 1;
    }

    public int LineOf(int offset)
    {
        if (offset < 0 || offset > _root.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }
        var node = _root;
        var breaks = 0;
        while (!node.IsLeaf)
        {
            if (offset < node.Left!.Length)
            {
                node = node.Left;
            }
            else
            {
                breaks += node.Left.Breaks;
                offset -= node.Left.Length;
                node = node.Right!;
            }
        }
        return breaks + node.Chars.AsSpan(0, offset).Count('\n');
    }

    public void Insert(int offset, ReadOnlySpan<char> text)
    {
        if (offset < 0 || offset > _root.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }
        if (text.IsEmpty)
        {
            return;
        }
        if (text.Length <= MaxLeaf && InsertInLeaf(_root, offset, text, text.Count('\n')))
        {
            return;
        }
        var (left, right) = Split(_root, offset);
        _root = Join(Join(left, Build(text)), right);
    }

    public void Remove(int offset, int length)
    {
        if (offset < 0 || length < 0 || offset + length > _root.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }
        if (length == 0)
        {
            return;
        }
        if (RemoveInLeaf(_root, offset, length))
        {
            return;
        }
        var (left, rest) = Split(_root, offset);
        var (_, right) = Split(rest, length);
        _root = Join(left, right);
    }

    private static bool InsertInLeaf(Node node, int offset, ReadOnlySpan<char> text, int breaks)
    {
        if (node.IsLeaf)
        {
            if (node.Length + text.Length > MaxLeaf)
            {
                return false;
            }
            var chars = node.Chars!;
            if (chars.Length < node.Length + text.Length)
            {
                Array.Resize(ref chars, MaxLeaf);
                node.Chars = chars;
            }
            Array.Copy(chars, offset, chars, offset + text.Length, node.Length - offset);
            text.CopyTo(chars.AsSpan(offset));
            node.Length += text.Length;
            node.Breaks += breaks;
            return true;
        }
        // An offset on the seam goes to the left leaf, so typing at the end of a leaf extends it.
        var inserted = offset <= node.Left!.Length
            ? InsertInLeaf(node.Left, offset, text, breaks)
            : InsertInLeaf(node.Right!, offset - node.Left.Length, text, breaks);
        if (inserted)
        {
            node.Length += text.Length;
            node.Breaks += breaks;
        }
        return inserted;
    }

    private static bool RemoveInLeaf(Node node, int offset, int length)
    {
        if (node.IsLeaf)
        {
            if (length >= node.Length)
            {
                return false;
            }
            var chars = node.Chars!;
            var removedBreaks = chars.AsSpan(offset, length).Count('\n');
            Array.Copy(chars, offset + length, chars, offset, node.Length - offset - length);
            node.Length -= length;
            node.Breaks -= removedBreaks;
            return true;
        }
        var left = node.Left!;
        int before;
        bool removed;
        if (offset + length <= left.Length)
        {
            before = left.Breaks;
            removed = RemoveInLeaf(left, offset, length);
            if (removed)
            {
                node.Breaks -= before - left.Breaks;
            }
        }
        else if (offset >= left.Length)
        {
            var right = node.Right!;
            before = right.Breaks;
            removed = RemoveInLeaf(right, offset - left.Length, length);
            if (removed)
            {
                node.Breaks -= before - right.Breaks;
            }
        }
        else
        {
            return false;
        }
        if (removed)
        {
            node.Length -= length;
        }
        return removed;
    }

    private static Node Build(ReadOnlySpan<char> text)
    {
        if (text.IsEmpty)
        {
            return Node.Empty();
        }
        var leaves = new List<Node>((text.Length + BuildLeaf - 1) / BuildLeaf);
        for (var start = 0; start < text.Length; start += BuildLeaf)
        {
            leaves.Add(Node.Leaf(text.Slice(start, Math.Min(BuildLeaf, text.Length - start))));
        }
        return BuildBalanced(leaves, 0, leaves.Count);
    }

    private static Node BuildBalanced(List<Node> leaves, int start, int count)
    {
        if (count == 1)
        {
            return leaves[start];
        }
        var half = count / 2;
        return Node.Branch(BuildBalanced(leaves, start, half), BuildBalanced(leaves, start + half, count - half));
    }

    private static (Node Left, Node Right) Split(Node node, int offset)
    {
        if (offset <= 0)
        {
            return (Node.Empty(), node);
        }
        if (offset >= node.Length)
        {
            return (node, Node.Empty());
        }
        if (node.IsLeaf)
        {
            var span = node.Chars.AsSpan(0, node.Length);
            return (Node.Leaf(span[..offset]), Node.Leaf(span[offset..]));
        }
        if (offset <= node.Left!.Length)
        {
            var (a, b) = Split(node.Left, offset);
            return (a, Join(b, node.Right!));
        }
        var (c, d) = Split(node.Right!, offset - node.Left.Length);
        return (Join(node.Left, c), d);
    }

    // AVL join: down the taller tree's inner spine to the other's height, rebalancing on the way back up.
    private static Node Join(Node left, Node right)
    {
        if (left.Length == 0)
        {
            return right;
        }
        if (right.Length == 0)
        {
            return left;
        }
        if (left.IsLeaf && right.IsLeaf && left.Length + right.Length <= BuildLeaf)
        {
            var merged = new char[MaxLeaf];
            left.Chars.AsSpan(0, left.Length).CopyTo(merged);
            right.Chars.AsSpan(0, right.Length).CopyTo(merged.AsSpan(left.Length));
            return Node.LeafOf(merged, left.Length + right.Length, left.Breaks + right.Breaks);
        }
        if (left.Height > right.Height + 1)
        {
            left.Right = Join(left.Right!, right);
            left.Update();
            return Balance(left);
        }
        if (right.Height > left.Height + 1)
        {
            right.Left = Join(left, right.Left!);
            right.Update();
            return Balance(right);
        }
        return Node.Branch(left, right);
    }

    private static Node Balance(Node node)
    {
        var factor = node.Left!.Height - node.Right!.Height;
        if (factor > 1)
        {
            if (node.Left.Left!.Height < node.Left.Right!.Height)
            {
                node.Left = RotateLeft(node.Left);
            }
            return RotateRight(node);
        }
        if (factor < -1)
        {
            if (node.Right.Right!.Height < node.Right.Left!.Height)
            {
                node.Right = RotateRight(node.Right);
            }
            return RotateLeft(node);
        }
        return node;
    }

    private static Node RotateRight(Node node)
    {
        var pivot = node.Left!;
        node.Left = pivot.Right;
        node.Update();
        pivot.Right = node;
        pivot.Update();
        return pivot;
    }

    private static Node RotateLeft(Node node)
    {
        var pivot = node.Right!;
        node.Right = pivot.Left;
        node.Update();
        pivot.Left = node;
        pivot.Update();
        return pivot;
    }

    internal void CheckInvariants()
    {
        Check(_root);

        static void Check(Node node)
        {
            if (node.IsLeaf)
            {
                if (node.Breaks != node.Chars.AsSpan(0, node.Length).Count('\n') || node.Height != 0)
                {
                    throw new InvalidOperationException("leaf cache is stale");
                }
                return;
            }
            Check(node.Left!);
            Check(node.Right!);
            if (node.Length != node.Left!.Length + node.Right!.Length
                || node.Breaks != node.Left.Breaks + node.Right.Breaks
                || node.Height != 1 + Math.Max(node.Left.Height, node.Right.Height)
                || Math.Abs(node.Left.Height - node.Right.Height) > 1)
            {
                throw new InvalidOperationException("branch is stale or unbalanced");
            }
        }
    }

    private sealed class Node
    {
        public Node? Left;
        public Node? Right;
        public char[]? Chars;
        public int Length;
        public int Breaks;
        public int Height;

        public bool IsLeaf => Chars is not null;

        public static Node Empty() => new() { Chars = new char[MaxLeaf] };

        public static Node Leaf(ReadOnlySpan<char> text)
        {
            var chars = new char[MaxLeaf];
            text.CopyTo(chars);
            return LeafOf(chars, text.Length, text.Count('\n'));
        }

        public static Node LeafOf(char[] chars, int length, int breaks) =>
            new() { Chars = chars, Length = length, Breaks = breaks };

        public static Node Branch(Node left, Node right)
        {
            var node = new Node { Left = left, Right = right };
            node.Update();
            return node;
        }

        public void Update()
        {
            Length = Left!.Length + Right!.Length;
            Breaks = Left.Breaks + Right.Breaks;
            Height = 1 + Math.Max(Left.Height, Right.Height);
        }
    }
}
