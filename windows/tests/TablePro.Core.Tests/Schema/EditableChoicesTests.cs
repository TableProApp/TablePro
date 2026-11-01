using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Schema;

public sealed class EditableChoicesTests
{
    private static readonly string[] SqliteTypes = ["INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC"];

    [Fact]
    public void ATypeOutsideTheSuggestionsIsAddedFirstAndSelected()
    {
        var (items, selected) = EditableChoices.Build(SqliteTypes, "VARCHAR(20)");

        Assert.Equal("VARCHAR(20)", items[selected]);
        Assert.Equal(0, selected);
        Assert.Equal(SqliteTypes.Length + 1, items.Count);
    }

    [Fact]
    public void ASuggestedTypeIsSelectedWhereItStands()
    {
        var (items, selected) = EditableChoices.Build(SqliteTypes, "TEXT");

        Assert.Equal(1, selected);
        Assert.Equal(SqliteTypes, items);
    }

    [Fact]
    public void ATypeThatDiffersOnlyInCaseKeepsTheDatabaseSpelling()
    {
        var (items, selected) = EditableChoices.Build(SqliteTypes, "text");

        Assert.Equal("text", items[selected]);
    }

    [Fact]
    public void ANewColumnStartsOnTheFirstSuggestionOrTheFallback()
    {
        Assert.Equal(0, EditableChoices.Build(SqliteTypes, null).SelectedIndex);
        var (items, selected) = EditableChoices.Build([], null, "text");
        Assert.Equal("text", items[selected]);
        Assert.Equal(-1, EditableChoices.Build([], "  ").SelectedIndex);
    }
}
