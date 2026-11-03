using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ObjectFoldersTests
{
    private static ObjectEntry Entry(string name, ObjectKind kind = ObjectKind.Table, string? schema = null) =>
        new(schema, name, kind, null);

    [Fact]
    public void ObjectsGoIntoOneFolderPerKindInTheFixedOrderSortedByName()
    {
        var folders = ObjectFolders.Group(
        [
            Entry("zeta"), Entry("v_people", ObjectKind.View), Entry("alpha"), Entry("parts", ObjectKind.PartitionedTable),
            Entry("next_id", ObjectKind.Sequence),
        ]);

        Assert.Equal([FolderKind.Tables, FolderKind.Views, FolderKind.Sequences], folders.Select(folder => folder.Kind));
        Assert.Equal(["alpha", "parts", "zeta"], folders[0].Objects.Select(entry => entry.Name));
    }

    [Fact]
    public void AFilterRanksNamesThatStartWithTheTextFirst()
    {
        var matches = ObjectFolders.Filter(
            [Entry("user_roles"), Entry("audit_users"), Entry("Users"), Entry("orders")],
            "USER");

        Assert.Equal(["user_roles", "Users", "audit_users"], matches.Select(entry => entry.Name));
    }

    [Fact]
    public void AnEmptyFilterMatchesNothing()
    {
        Assert.Empty(ObjectFolders.Filter([Entry("a")], "  "));
    }

    [Fact]
    public void OnlyTablesAndViewsHaveRowsToShow()
    {
        Assert.True(ObjectFolders.HasRows(ObjectKind.Table));
        Assert.True(ObjectFolders.HasRows(ObjectKind.MaterializedView));
        Assert.False(ObjectFolders.HasRows(ObjectKind.Function));
        Assert.False(ObjectFolders.HasRows(ObjectKind.Key));
    }
}
