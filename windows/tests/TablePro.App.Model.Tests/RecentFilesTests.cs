using System.Globalization;

namespace TablePro.App.Model.Tests;

public sealed class RecentFilesTests
{
    [Fact]
    public void TheNewestFileComesFirst()
    {
        var recent = new RecentFiles();

        recent.Add(@"C:\sql\a.sql");
        recent.Add(@"C:\sql\b.sql");

        Assert.Equal<string>([@"C:\sql\b.sql", @"C:\sql\a.sql"], recent.Paths);
    }

    [Fact]
    public void AFileOpenedAgainMovesUpWhateverTheCaseOfItsPath()
    {
        var recent = new RecentFiles();
        recent.Add(@"C:\sql\a.sql");
        recent.Add(@"C:\sql\b.sql");

        recent.Add(@"c:\SQL\A.sql");

        Assert.Equal<string>([@"c:\SQL\A.sql", @"C:\sql\b.sql"], recent.Paths);
    }

    [Fact]
    public void TheListKeepsTheTenNewest()
    {
        var recent = new RecentFiles();

        for (var index = 1; index <= 12; index++)
        {
            recent.Add(Name(index));
        }

        Assert.Equal(RecentFiles.Limit, recent.Paths.Count);
        Assert.Equal(Name(12), recent.Paths[0]);
        Assert.Equal(Name(3), recent.Paths[^1]);
    }

    [Fact]
    public void ASavedListIsReadBackWithoutBlanksOrRepeatsAndAtMostTen()
    {
        var recent = new RecentFiles(
            [@"C:\a.sql", " ", @"c:\A.SQL", .. Enumerable.Range(1, 12).Select(Name)]);

        Assert.Equal(RecentFiles.Limit, recent.Paths.Count);
        Assert.Equal(@"C:\a.sql", recent.Paths[0]);
        Assert.Equal(Name(9), recent.Paths[^1]);
    }

    [Fact]
    public void RemoveAndClearTakeFilesOff()
    {
        var recent = new RecentFiles([@"C:\a.sql", @"C:\b.sql"]);

        Assert.True(recent.Remove(@"c:\B.SQL"));
        Assert.False(recent.Remove(@"C:\b.sql"));
        Assert.Equal<string>([@"C:\a.sql"], recent.Paths);

        recent.Clear();
        Assert.Empty(recent.Paths);
    }

    [Fact]
    public void PathsWhoseFilesAreGoneAreDroppedWhenAsked()
    {
        var recent = new RecentFiles([@"C:\here.sql", @"C:\gone.sql", @"C:\also-here.sql"]);

        Assert.True(recent.RemoveMissing(path => !path.Contains("gone", StringComparison.Ordinal)));
        Assert.False(recent.RemoveMissing(_ => true));

        Assert.Equal<string>([@"C:\here.sql", @"C:\also-here.sql"], recent.Paths);
    }

    [Fact]
    public void ByDefaultAFileIsGoneWhenItIsNotOnDisk()
    {
        var directory = Directory.CreateTempSubdirectory("tablepro-recent-").FullName;
        try
        {
            var kept = Path.Combine(directory, "kept.sql");
            File.WriteAllText(kept, "select 1;");
            var recent = new RecentFiles([kept, Path.Combine(directory, "gone.sql")]);

            recent.RemoveMissing();

            Assert.Equal<string>([kept], recent.Paths);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void TheListGivenOutDoesNotChangeWithIt()
    {
        var recent = new RecentFiles([@"C:\a.sql"]);
        var saved = recent.Paths;

        recent.Add(@"C:\b.sql");

        Assert.Equal<string>([@"C:\a.sql"], saved);
    }

    private static string Name(int index) => string.Create(CultureInfo.InvariantCulture, $@"C:\sql\{index}.sql");
}
