namespace TablePro.Core.Schema;

/// <summary>
/// One node of a key tree: a namespace that groups the keys sharing a prefix, or a key. A namespace's
/// <see cref="Prefix"/> ends with the separator, so <c>user:</c> holds <c>user:1</c> and <c>user:1:name</c>.
/// </summary>
public sealed record KeyNamespaceNode(string Name, string Prefix, DatabaseObject? Key, IReadOnlyList<KeyNamespaceNode> Children, int KeyCount)
{
    public bool IsNamespace => Key is null;
}

/// <summary>
/// Groups keys into namespaces at a separator, as the macOS sidebar's key tree does: <c>user:1:name</c> sits under
/// <c>user</c> then <c>1</c>. Namespaces come first, then keys, each in ordinal order.
/// </summary>
public static class KeyNamespaceTree
{
    public static IReadOnlyList<KeyNamespaceNode> Build(IEnumerable<DatabaseObject> keys, string? separator)
    {
        ArgumentNullException.ThrowIfNull(keys);
        if (string.IsNullOrEmpty(separator))
        {
            return keys.OrderBy(k => k.Name.Name, StringComparer.Ordinal).Select(k => Leaf(k.Name.Name, k)).ToArray();
        }

        var root = new Trie();
        foreach (var key in keys)
        {
            var name = key.Name.Name;
            var node = root;
            var start = 0;
            int next;
            while ((next = name.IndexOf(separator, start, StringComparison.Ordinal)) >= 0)
            {
                var segment = name[start..next];
                if (!node.Children.TryGetValue(segment, out var child))
                {
                    child = new Trie();
                    node.Children[segment] = child;
                }

                node = child;
                start = next + separator.Length;
            }

            node.Keys.Add(key);
        }

        return root.ToNodes(string.Empty, separator);
    }

    /// <summary>The rows a tree shows: each node with its depth, a namespace's children only when it is expanded.</summary>
    public static IEnumerable<(KeyNamespaceNode Node, int Depth)> Flatten(IReadOnlyList<KeyNamespaceNode> nodes, Func<KeyNamespaceNode, bool> isExpanded, int depth = 0)
    {
        ArgumentNullException.ThrowIfNull(nodes);
        ArgumentNullException.ThrowIfNull(isExpanded);
        foreach (var node in nodes)
        {
            yield return (node, depth);
            if (node.IsNamespace && isExpanded(node))
            {
                foreach (var child in Flatten(node.Children, isExpanded, depth + 1))
                {
                    yield return child;
                }
            }
        }
    }

    private static KeyNamespaceNode Leaf(string name, DatabaseObject key) => new(name, key.Name.Name, key, [], 1);

    private sealed class Trie
    {
        public Dictionary<string, Trie> Children { get; } = new(StringComparer.Ordinal);

        public List<DatabaseObject> Keys { get; } = [];

        public int Count => Keys.Count + Children.Values.Sum(c => c.Count);

        public List<KeyNamespaceNode> ToNodes(string prefix, string separator)
        {
            var nodes = new List<KeyNamespaceNode>(Children.Count + Keys.Count);
            foreach (var (segment, child) in Children.OrderBy(c => c.Key, StringComparer.Ordinal))
            {
                var childPrefix = prefix + segment + separator;
                nodes.Add(new KeyNamespaceNode(segment, childPrefix, null, child.ToNodes(childPrefix, separator), child.Count));
            }

            foreach (var key in Keys.OrderBy(k => k.Name.Name, StringComparer.Ordinal))
            {
                nodes.Add(Leaf(key.Name.Name[prefix.Length..], key));
            }

            return nodes;
        }
    }
}
