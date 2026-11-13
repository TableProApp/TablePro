using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ShareColumnsTests
{
    private static readonly MaskSuggestion EmailName = new(MaskStyle.Email, new MaskReason.ColumnName("email"));
    private static readonly MaskSuggestion CardValues = new(MaskStyle.LastFour, new MaskReason.Values(SensitiveKind.Card));

    private static ShareColumns Columns() => ShareColumns.From(
    [
        new ShareColumnMasking("id", null),
        new ShareColumnMasking("email", EmailName),
        new ShareColumnMasking("card", CardValues),
    ]);

    [Fact]
    public void ADetectedColumnStartsMaskedWithItsSuggestionAndTheRestIsKept()
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
    public void ADetectedColumnCanBeKeptAndAnyColumnMaskedWithAnyStyle()
    {
        var columns = Columns();
        var email = columns.Columns[1];
        var id = columns.Columns[0];

        email.Choose(ShareColumnAction.Keep);
        id.Choose(ShareColumnAction.Mask);
        id.Choose(MaskStyle.Hash);

        Assert.Equal(ShareColumnChoice.Keep.Instance, email.Choice);
        Assert.Equal(new ShareColumnChoice.Mask(MaskStyle.Hash), id.Choice);
        Assert.Equal(5, ShareColumn.Styles.Count);
        // The style stays for a return to Mask.
        email.Choose(ShareColumnAction.Mask);
        Assert.Equal(new ShareColumnChoice.Mask(MaskStyle.Email), email.Choice);
    }

    [Fact]
    public void RemovingEveryColumnLeavesNothingToShare()
    {
        var columns = Columns();

        foreach (var column in columns.Columns)
        {
            column.Choose(ShareColumnAction.Remove);
        }

        Assert.True(columns.RemovesEveryColumn);
        Assert.Equal((0, 3, 0), (columns.Masked, columns.Removed, columns.Kept));
        Assert.Equal(ShareColumnChoice.Remove.Instance, columns.Columns[1].Choice);
        Assert.False(ShareColumns.None.RemovesEveryColumn);
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
