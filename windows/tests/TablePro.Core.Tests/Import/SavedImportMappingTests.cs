using TablePro.Core.Import;

namespace TablePro.Core.Tests.Import;

public sealed class SavedImportMappingTests
{
    private static ImportField Field(string name) => new(name, null, ImportFieldType.Text);

    private static ImportTargetColumn Column(string name) => new(name, "text", typeof(string));

    private static Dictionary<string, ImportMappingOverride> Saved(params (string Field, string? Column)[] entries) =>
        entries.ToDictionary(e => e.Field, e => new ImportMappingOverride(e.Column), StringComparer.Ordinal);

    [Fact]
    public void RemembersOnlyDeparturesFromTheNameMatch()
    {
        string[] fields = ["id", "mail", "notes"];
        string[] columns = ["id", "email", "notes"];
        ImportFieldChoice[] choices = [new(true, "id"), new(true, "email"), ImportFieldChoice.Skipped];

        var overrides = ImportColumnMatcher.Overrides(fields, columns, choices);

        Assert.Equal(2, overrides.Count);
        Assert.Equal("email", overrides["mail"].Column);
        Assert.Equal(ImportMappingOverride.Skip, overrides["notes"]);
    }

    [Fact]
    public void ApplyingPutsRememberedChoicesAheadOfTheNameMatch()
    {
        var choices = ImportColumnMatcher.Applying(Saved(("mail", "email"), ("notes", null)), ["id", "mail", "notes"], ["id", "email", "notes"]);

        Assert.Equal([new ImportFieldChoice(true, "id"), new ImportFieldChoice(true, "email"), ImportFieldChoice.Skipped], choices);
    }

    [Fact]
    public void MergingKeepsOtherLayoutsAndLetsAHeaderRespelledByCaseTakeOver()
    {
        var saved = Saved(("Mail", "email"), ("legacy_code", "code"), ("notes", null));

        var merged = ImportColumnMatcher.Merging(Saved(("mail", "contact")), ["mail", "notes"], saved);

        Assert.False(merged.ContainsKey("Mail"));
        Assert.Equal("contact", merged["mail"].Column);
        Assert.Equal("code", merged["legacy_code"].Column);
        Assert.False(merged.ContainsKey("notes"));
    }

    [Fact]
    public void MappingOpensOnTheSavedChoicesAndSaysSo()
    {
        var mapping = new ImportMapping([Field("id"), Field("mail")], [Column("id"), Column("email")], Saved(("mail", "email")));

        Assert.Equal("email", mapping[1].MappedColumn);
        Assert.True(mapping.ShowsSavedMapping);
        Assert.False(mapping.CanUseSavedMapping);

        mapping.MatchByName();
        Assert.Null(mapping[1].MappedColumn);
        Assert.False(mapping.ShowsSavedMapping);
        Assert.True(mapping.CanUseSavedMapping);

        mapping.UseSavedMapping();
        Assert.Equal("email", mapping[1].MappedColumn);
        Assert.True(mapping.ShowsSavedMapping);
    }

    [Fact]
    public void ASavedMappingForFieldsThisFileLacksIsNotAnnounced()
    {
        var mapping = new ImportMapping([Field("id")], [Column("id"), Column("email")], Saved(("mail", "email")));

        Assert.False(mapping.ShowsSavedMapping);
        Assert.False(mapping.CanUseSavedMapping);
    }

    [Fact]
    public void ARereadKeepsTheSessionsChoicesThenTheSavedOnes()
    {
        var mapping = new ImportMapping([Field("id"), Field("mail")], [Column("id"), Column("email"), Column("alt")], Saved(("mail", "email"), ("other", "alt")));
        mapping[0] = ImportFieldChoice.Skipped;

        mapping.Reload([Field("id"), Field("mail"), Field("other")]);

        Assert.Equal(ImportFieldChoice.Skipped, mapping[0]);
        Assert.Equal("email", mapping[1].MappedColumn);
        Assert.Equal("alt", mapping[2].MappedColumn);
    }

    [Fact]
    public void OverridesOfTheCurrentMappingAreWhatTheStoreRemembers()
    {
        var mapping = new ImportMapping([Field("id"), Field("mail")], [Column("id"), Column("email")]);
        mapping[1] = new ImportFieldChoice(true, "email");

        var overrides = mapping.Overrides();

        Assert.Equal(["mail"], overrides.Keys);
        Assert.Equal("email", overrides["mail"].Column);
    }
}
