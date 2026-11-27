namespace TablePro.Interop.Tests;

public sealed class AppLinkTests
{
    private static readonly Guid Id = Guid.Parse("9f1f0c3e-2e3d-4b14-9c3a-1d2f4ad1f6f1");

    [Fact]
    public void AConnectLinkNamesItsConnectionAndWhatToOpen()
    {
        Assert.Equal(new AppLink.OpenConnection(Id), AppLink.Parse($"tablepro://connect/{Id}"));
        Assert.Equal(
            new AppLink.OpenTable(Id, "app", "reporting", "daily events"),
            AppLink.Parse($"tablepro://connect/{Id.ToString().ToUpperInvariant()}/database/app/schema/reporting/table/daily%20events"));
        Assert.Equal(
            new AppLink.OpenQuery(Id, "SELECT * FROM users"),
            AppLink.Parse($"tablepro://connect/{Id}/query?sql=SELECT%20*%20FROM%20users"));
        Assert.Equal(new AppLink.OpenSettings("notifications"), AppLink.Parse("tablepro://settings/notifications"));
    }

    [Fact]
    public void AStartMcpLinkStartsTheServer() =>
        Assert.Equal(new AppLink.StartMcpServer(), AppLink.Parse("tablepro://integrations/start-mcp"));

    [Theory]
    [InlineData("tablepro://connect/production", "link.invalid_id")]
    [InlineData("tablepro://import?name=Staging", "link.unknown_host")]
    [InlineData("tablepro://integrations/pair?client=Raycast&challenge=c&redirect=raycast%3A%2F%2Fx", "link.malformed_path")]
    [InlineData("postgresql://db.example.com/shop", "link.invalid")]
    public void ALinkTheAppDoesNotReadThrowsItsCode(string link, string code) =>
        Assert.Equal(code, Assert.Throws<TableProException>(() => AppLink.Parse(link)).Code);
}
