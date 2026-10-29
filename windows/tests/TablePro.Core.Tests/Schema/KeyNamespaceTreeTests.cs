using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Schema;

public sealed class KeyNamespaceTreeTests
{
    private static DatabaseObject Key(string name) => new(new ObjectName("db0", name), ObjectKind.Key);

    private static IReadOnlyList<KeyNamespaceNode> Tree(string? separator, params string[] keys) => KeyNamespaceTree.Build(keys.Select(Key), separator);

    [Fact]
    public void KeysGroupIntoNamespacesAtTheSeparator()
    {
        var tree = Tree(":", "user:1:name", "user:1:email", "user:2", "session", "cache:x");

        Assert.Equal(["cache", "user", "session"], tree.Select(n => n.Name));
        var user = tree[1];
        Assert.True(user.IsNamespace);
        Assert.Equal("user:", user.Prefix);
        Assert.Equal(3, user.KeyCount);
        Assert.Equal(["1", "2"], user.Children.Select(n => n.Name));
        var one = user.Children[0];
        Assert.Equal("user:1:", one.Prefix);
        Assert.Equal(["email", "name"], one.Children.Select(n => n.Name));
        Assert.Equal("user:1:email", one.Children[0].Key!.Name.Name);
        Assert.False(tree[2].IsNamespace);
        Assert.Equal("session", tree[2].Key!.Name.Name);
    }

    [Fact]
    public void ANamespaceCanAlsoBeAKey()
    {
        var tree = Tree(":", "user", "user:1");

        Assert.Equal(2, tree.Count);
        Assert.True(tree[0].IsNamespace);
        Assert.Equal("user", tree[1].Name);
        Assert.False(tree[1].IsNamespace);
    }

    [Fact]
    public void ALongerSeparatorAndAnEmptyOne()
    {
        Assert.Equal(["a", "b"], Tree("::", "a::x", "b").Select(n => n.Name));
        Assert.Equal(["a:x", "b"], Tree(string.Empty, "b", "a:x").Select(n => n.Name));
        Assert.All(Tree(null, "a:x", "b"), n => Assert.False(n.IsNamespace));
    }

    [Fact]
    public void FlattenShowsOnlyTheExpandedNamespacesChildren()
    {
        var tree = Tree(":", "user:1:name", "user:2", "other");

        Assert.Equal([("user", 0), ("other", 0)], KeyNamespaceTree.Flatten(tree, _ => false).Select(r => (r.Node.Name, r.Depth)));
        Assert.Equal(
            [("user", 0), ("1", 1), ("2", 1), ("other", 0)],
            KeyNamespaceTree.Flatten(tree, n => n.Prefix == "user:").Select(r => (r.Node.Name, r.Depth)));
        Assert.Equal(5, KeyNamespaceTree.Flatten(tree, _ => true).Count());
    }

    [Fact]
    public void ANamespaceBrowsesWithAnEscapedPrefixPattern()
    {
        Assert.Equal("user:*", KeyBrowseInfo.NamespacePattern("user:"));
        Assert.Equal("a\\*b\\[1\\]:*", KeyBrowseInfo.NamespacePattern("a*b[1]:"));
    }

    [Fact]
    public void KeyBrowseRulesLeaveOutBlanks()
    {
        var info = new KeyBrowseInfo("Key", "Type", ["string"]);

        Assert.Empty(info.Rules(" ", null));
        Assert.Equal(
            [new FilterRule("Key", FilterOperator.Equals, "user:*"), new FilterRule("Type", FilterOperator.Equals, "hash")],
            info.Rules(" user:* ", "hash"));
    }
}
