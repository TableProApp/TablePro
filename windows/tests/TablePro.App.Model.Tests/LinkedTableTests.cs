using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class LinkedTableTests
{
    [Fact]
    public void AnotherDatabaseOfAServerWithSchemasOpensThereFirst()
    {
        Assert.Equal(new LinkedTablePlace("app", "reporting"), LinkedTable.Place(DatabaseLayout.WithSchemas, "postgres", "app", "reporting"));
        Assert.Equal(new LinkedTablePlace(null, "reporting"), LinkedTable.Place(DatabaseLayout.WithSchemas, "app", "app", "reporting"));
        Assert.Equal(new LinkedTablePlace(null, null), LinkedTable.Place(DatabaseLayout.WithSchemas, "app", null, null));
    }

    [Fact]
    public void ADatabaseIsTheSchemaWhereDatabasesAreSchemas() =>
        Assert.Equal(new LinkedTablePlace(null, "analytics"), LinkedTable.Place(DatabaseLayout.AsSchemas, "shop", "analytics", "ignored"));

    [Fact]
    public void OneDatabaseDropsTheDatabaseSegment() =>
        Assert.Equal(new LinkedTablePlace(null, "main"), LinkedTable.Place(DatabaseLayout.OneDatabase, null, "other", "main"));

    [Theory]
    [InlineData("C:\\data\\app.sqlite", true)]
    [InlineData("d:/data/app.duckdb", true)]
    [InlineData("\\\\server\\share\\app.sqlite", false)]
    [InlineData("//server/share/app.sqlite", false)]
    [InlineData("\\\\?\\UNC\\server\\share\\app.sqlite", false)]
    [InlineData("\\\\.\\pipe\\x", false)]
    [InlineData("C:app.sqlite", false)]
    [InlineData("/home/app.sqlite", false)]
    public void OnlyAFileOnALetteredDriveOpensFromALink(string path, bool opens) =>
        Assert.Equal(opens, LinkedFile.IsOnDrive(path));
}
