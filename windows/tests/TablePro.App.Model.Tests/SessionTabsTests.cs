namespace TablePro.App.Model.Tests;

public sealed class SessionTabsTests
{
    private static readonly SessionTab Query = new() { Kind = TabKind.Query, Title = "Query 1", Sql = "select 1" };

    private static readonly SessionTab Table = new() { Kind = TabKind.Table, Title = "Artist", Table = "Artist" };

    private static readonly SessionTab Definition = new()
    {
        Kind = TabKind.Definition,
        Title = "Track_Audit",
        Table = "Track_Audit",
        ObjectKind = "Trigger",
    };

    [Fact]
    public void DefinitionTabsAreLeftOutAndTheSelectedTabStaysSelected()
    {
        var (tabs, selected) = SessionTabs.Persisted([Query, Definition, Table, Definition], 2);

        Assert.Equal<SessionTab>([Query, Table], tabs);
        Assert.Equal(1, selected);
    }

    [Fact]
    public void KeyTabsAreLeftOutAsDefinitionTabsAre()
    {
        var key = new SessionTab { Kind = TabKind.Key, Title = "session:42", Table = "session:42" };

        var (tabs, selected) = SessionTabs.Persisted([Query, key, Table], 2);

        Assert.Equal<SessionTab>([Query, Table], tabs);
        Assert.Equal(1, selected);
    }

    [Fact]
    public void ASelectedDefinitionTabHandsTheSelectionToTheNearestKeptTabBeforeIt()
    {
        var (tabs, selected) = SessionTabs.Persisted([Query, Table, Definition, Definition], 3);

        Assert.Equal<SessionTab>([Query, Table], tabs);
        Assert.Equal(1, selected);
    }

    [Fact]
    public void WithNoKeptTabBeforeTheSelectedOneTheFirstIsSelected()
    {
        Assert.Equal(0, SessionTabs.Persisted([Definition, Table, Query], 0).Selected);
        Assert.Equal(0, SessionTabs.Persisted([Query], -1).Selected);

        var (tabs, selected) = SessionTabs.Persisted([Definition], 0);

        Assert.Empty(tabs);
        Assert.Equal(0, selected);
    }

    [Fact]
    public void TabsWithNoDefinitionAreKeptAsTheyAre()
    {
        var (tabs, selected) = SessionTabs.Persisted([Query, Table], 1);

        Assert.Equal<SessionTab>([Query, Table], tabs);
        Assert.Equal(1, selected);
    }
}
