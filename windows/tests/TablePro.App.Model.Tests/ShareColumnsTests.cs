using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ShareColumnsTests
{
    private static readonly MaskSuggestion EmailName = new(MaskStyle.Email, new MaskReason.ColumnName("email"));

    private static ShareColumns Columns() => ShareColumns.From(
    [
        new ShareColumnMasking("id", null, null),
        new ShareColumnMasking("email", null, EmailName),
        new ShareColumnMasking("ssn", MaskStyle.LastFour, null),
    ]);

    [Fact]
    public void ARuleMasksWithItsStyleADetectionWithItsSuggestionAndTheRestIsKept()
    {
        var columns = Columns();

        Assert.Equal(
            [ShareColumnAction.Keep, ShareColumnAction.Mask, ShareColumnAction.Mask],
            columns.Columns.Select(column => column.Action));
        Assert.Equal(
            [ShareColumnChoice.Keep.Instance, new ShareColumnChoice.Mask(MaskStyle.Email), new ShareColumnChoice.Mask(MaskStyle.LastFour)],
            columns.Choices);
        Assert.Equal((2, 0, 3), (columns.Masked, columns.Removed, columns.Kept));
        Assert.True(columns.HasDetections);
        Assert.False(columns.RemovesEveryColumn);
    }

    [Fact]
    public void ARuledColumnIsNeverKeptAndTakesOnlyAStyleThatHidesAsMuch()
    {
        var ruled = Columns().Columns[2];

        Assert.False(ruled.AllowsKeep);
        Assert.False(ruled.Choose(ShareColumnAction.Keep));
        Assert.Equal([MaskStyle.Full, MaskStyle.LastFour, MaskStyle.Null], ruled.AllowedStyles);
        Assert.False(ruled.Choose(MaskStyle.Email));
        Assert.Equal(MaskStyle.LastFour, ruled.Style);
        Assert.True(ruled.Choose(ShareColumnAction.Remove));
        Assert.Equal(ShareColumnChoice.Remove.Instance, ruled.Choice);

        var nulled = ShareColumns.From([new ShareColumnMasking("x", MaskStyle.Null, null)]).Columns[0];
        var full = ShareColumns.From([new ShareColumnMasking("x", MaskStyle.Full, null)]).Columns[0];
        Assert.Equal([MaskStyle.Null], nulled.AllowedStyles);
        Assert.Equal([MaskStyle.Full, MaskStyle.Null], full.AllowedStyles);
    }

    [Fact]
    public void ADetectedColumnCanBeKeptAndAKeptColumnMaskedWithAnyStyle()
    {
        var columns = Columns();
        var email = columns.Columns[1];
        var id = columns.Columns[0];

        Assert.True(email.Choose(ShareColumnAction.Keep));
        Assert.True(id.Choose(ShareColumnAction.Mask));
        Assert.True(id.Choose(MaskStyle.Hash));

        Assert.Equal(ShareColumnChoice.Keep.Instance, email.Choice);
        Assert.Equal(new ShareColumnChoice.Mask(MaskStyle.Hash), id.Choice);
        Assert.Equal(5, id.AllowedStyles.Count);
        // The style stays for a return to Mask.
        Assert.True(email.Choose(ShareColumnAction.Mask));
        Assert.Equal(new ShareColumnChoice.Mask(MaskStyle.Email), email.Choice);
    }

    [Fact]
    public void RemovingEveryColumnLeavesNothingToShare()
    {
        var columns = Columns();

        foreach (var column in columns.Columns)
        {
            Assert.True(column.Choose(ShareColumnAction.Remove));
        }

        Assert.True(columns.RemovesEveryColumn);
        Assert.Equal((0, 3, 0), (columns.Masked, columns.Removed, columns.Kept));
        Assert.False(ShareColumns.None.RemovesEveryColumn);
    }

    [Fact]
    public void ARuleWinsOverASuggestionSoTheColumnSaysOnlyThatItIsRuled()
    {
        var column = ShareColumns.From([new ShareColumnMasking("email", MaskStyle.Hash, EmailName)]).Columns[0];

        Assert.Null(column.Suggestion);
        Assert.Equal(new ShareColumnChoice.Mask(MaskStyle.Hash), column.Choice);
        Assert.False(ShareColumns.From([new ShareColumnMasking("email", MaskStyle.Hash, EmailName)]).HasDetections);
    }

    [Fact]
    public void AnUntracedColumnIsMaskedAsARuledOneIsAndSaysWhy()
    {
        var untraced = ShareColumns.From([new ShareColumnMasking("tag", MaskStyle.Full, null) { Untraced = true }]).Columns[0];
        var ruled = Columns().Columns[2];

        Assert.True(untraced.Untraced);
        Assert.False(ruled.Untraced);
        Assert.False(untraced.AllowsKeep);
        Assert.Equal(new ShareColumnChoice.Mask(MaskStyle.Full), untraced.Choice);
        Assert.False(ShareColumns.From([new ShareColumnMasking("x", null, null) { Untraced = true }]).Columns[0].Untraced);
    }

    [Fact]
    public void EachReasonHasItsWords()
    {
        Assert.Equal("SensitiveName_Secret", SensitiveWords.KeyFor(new MaskReason.ColumnName("apikey")));
        Assert.Equal("SensitiveName_IpAddress", SensitiveWords.KeyFor(new MaskReason.ColumnName("ipv4")));
        Assert.Equal("SensitiveName_PersonName", SensitiveWords.KeyFor(new MaskReason.ColumnName("firstname")));
        Assert.Null(SensitiveWords.KeyFor(new MaskReason.ColumnName("added_later")));
        Assert.Equal("SensitiveValue_Card", SensitiveWords.KeyFor(new MaskReason.Values(SensitiveKind.Card)));
        Assert.Equal("SensitiveValue_Jwt", SensitiveWords.KeyFor(SensitiveKind.Jwt));
    }
}
