namespace TablePro.App.Model.Tests;

public sealed class CopyNameTests
{
    private const string Pattern = "{0} (Copy)";
    private const string Numbered = "{0} (Copy {1})";

    [Fact]
    public void ACopyTakesTheSuffixThenTheSmallestFreeNumber()
    {
        List<string> names = ["Prod"];
        foreach (var expected in new[] { "Prod (Copy)", "Prod (Copy 2)", "Prod (Copy 3)" })
        {
            var name = CopyName.For("Prod", names, Pattern, Numbered);
            Assert.Equal(expected, name);
            names.Add(name);
        }

        Assert.Equal("db (Copy 2)", CopyName.For("db", ["db", "db (Copy)", "db (Copy 3)"], Pattern, Numbered));
    }

    [Fact]
    public void ACopyOfACopyCountsOnFromTheOriginal()
    {
        string[] names = ["Prod", "Prod (Copy)", "Prod (Copy 2)"];

        Assert.Equal("Prod (Copy 3)", CopyName.For("Prod (Copy)", names, Pattern, Numbered));
        Assert.Equal("Prod (Copy 3)", CopyName.For("Prod (Copy 2)", names, Pattern, Numbered));
    }

    [Fact]
    public void ANameThatOnlyLooksNumberedKeepsItsText()
    {
        string[] names = ["Release (Copy 1)", "(Copy)"];

        Assert.Equal("Release (Copy 1) (Copy)", CopyName.For("Release (Copy 1)", names, Pattern, Numbered));
        Assert.Equal("(Copy) (Copy)", CopyName.For("(Copy)", names, Pattern, Numbered));
    }

    [Fact]
    public void ATranslationThatPutsTheWordFirstStillStripsIt()
    {
        string[] names = ["Prod", "Copie de Prod"];

        Assert.Equal("Copie 2 de Prod", CopyName.For("Copie de Prod", names, "Copie de {0}", "Copie {1} de {0}"));
    }
}
