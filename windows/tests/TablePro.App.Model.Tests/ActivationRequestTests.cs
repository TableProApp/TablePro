namespace TablePro.App.Model.Tests;

public sealed class ActivationRequestTests
{
    private const string Share = "tablepro://share?token=Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK";

    [Fact]
    public void LinksAndFilesAreToldApartAndOptionsAreLeftOut()
    {
        var request = ActivationRequest.FromArguments(
            ["--flag", $"\"{Share}\"", "postgresql://app@db.example.com/shop", Path.Combine("data", "app.sqlite"), "  "]);

        Assert.Equal([Share, "postgresql://app@db.example.com/shop"], request.Links);
        Assert.Equal([Path.GetFullPath(Path.Combine("data", "app.sqlite"))], request.Files);
    }

    [Theory]
    [InlineData("TablePro://connect/x", true)]
    [InlineData("mongodb+srv://cluster.example.com", true)]
    [InlineData("jdbc:postgresql://db.example.com/shop", true)]
    [InlineData("sqlite:/C:/data/app.db", true)]
    [InlineData("DuckDB:/C:/data/app.duckdb", true)]
    [InlineData("C://data/app.sqlite", false)]
    [InlineData("C:\\data\\app.sqlite", false)]
    [InlineData("schema.sql", false)]
    public void AUrlSchemeMakesALink(string text, bool link) => Assert.Equal(link, ActivationRequest.IsLink(text));

    [Fact]
    public void AFileUriOpensItsFile()
    {
        var path = Path.GetFullPath("report.sql");

        var request = ActivationRequest.FromArguments([new Uri(path).AbsoluteUri]);

        Assert.Empty(request.Links);
        Assert.Equal([path], request.Files);
    }

    [Fact]
    public void ALaunchLineDropsTheProgramAndKeepsQuotedPathsWhole()
    {
        var request = ActivationRequest.FromCommandLine(
            "\"C:\\Program Files\\TablePro\\TablePro.exe\" \"My Scripts\\a b.sql\" tablepro://settings");

        Assert.Equal(["tablepro://settings"], request.Links);
        Assert.Equal([Path.GetFullPath("My Scripts\\a b.sql")], request.Files);
    }

    [Fact]
    public void ARelativePathIsMadeWholeAgainstTheLaunchsFolderAndTheRestIsKept()
    {
        var folder = Path.GetFullPath("scripts");
        var absolute = Path.GetFullPath("app.sqlite");

        var whole = ActivationRequest.WholePaths(["--flag", "report.sql", absolute, "tablepro://settings"], folder);

        Assert.Equal(["--flag", Path.Combine(folder, "report.sql"), absolute, "tablepro://settings"], whole);
        Assert.Null(ActivationRequest.WholePaths([absolute, "postgresql://db/shop", "-x"], folder));
    }

    [Fact]
    public void TheSameFileNamedTwiceOpensOnce()
    {
        var path = Path.GetFullPath("app.duckdb");

        var request = ActivationRequest.FromFiles([path, path.ToUpperInvariant(), null, " "]);

        Assert.Equal([path], request.Files);
        Assert.False(request.IsEmpty);
        Assert.True(ActivationRequest.None.IsEmpty);
    }

    [Theory]
    [InlineData("a b", new[] { "a", "b" })]
    [InlineData("\"a b\" c", new[] { "a b", "c" })]
    [InlineData("a\\\\\"b c\"", new[] { "a\\b c" })]
    [InlineData("a\\\"b", new[] { "a\"b" })]
    [InlineData("a\\b\\\\c", new[] { "a\\b\\\\c" })]
    [InlineData("\"a \"\"b\"\" c\"", new[] { "a \"b\" c" })]
    [InlineData("\"\" x", new[] { "", "x" })]
    public void ALineSplitsAsWindowsSplitsIt(string line, string[] words) =>
        Assert.Equal(words, ActivationRequest.SplitCommandLine(line));

    [Fact]
    public void ABlankLineHasNoWords() => Assert.Empty(ActivationRequest.SplitCommandLine(" \t "));

    [Fact]
    public void LinksOpenOneAtATimeInOrderAndOneAlreadyWaitingIsKeptOnce()
    {
        var queue = new PendingLinks();

        var starts = queue.Offer("a");
        var opening = queue.TakeNext();
        var whileOpening = (queue.Offer("b"), queue.Offer("a"), queue.Offer("b"), queue.Offer("c"));

        Assert.True(starts);
        Assert.Equal("a", opening);
        Assert.Equal((false, false, false, false), whileOpening);
        Assert.Equal("b", queue.TakeNext());
        Assert.Equal("c", queue.TakeNext());
        Assert.Null(queue.TakeNext());
        Assert.True(queue.Offer("a"));
    }

}
