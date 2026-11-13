using TablePro.Interop;

namespace TablePro.DataGrid.Model.Tests;

// The core holds a masked column's masked text, so the grid, a copy and the header read only that.
[Trait("Needs", "Core")]
public sealed class MaskedDataTests
{
    private const string Values = "SELECT 1 AS id, 'ann@example.com' AS email UNION ALL SELECT 2, 'bob@example.com'";

    [Fact]
    public async Task AMaskedColumnIsMarkedAndItsCellsAndCopiesHoldTheMaskedText()
    {
        await using var database = await CoreDatabase.CreateAsync([new MaskingRule(null, "email", MaskTarget.Column, MaskStyle.Email)]);
        using var data = await database.QueryAsync(Values);
        var edited = new EditedGridData(data.Data, GridEdits.None);
        using var cache = new CellCache(data.Data.OpenReader());
        using var reader = data.Data.OpenReader();

        var tsv = GridCopy.Tsv(reader, new CellRange(0, 0, 1, 1), TestContext.Current.CancellationToken);

        Assert.False(data.Data.IsColumnMasked(0));
        Assert.True(data.Data.IsColumnMasked(1));
        Assert.True(edited.IsColumnMasked(1));
        Assert.Equal("a•••@example.com", cache.Get(0, 1, 64).Text.ToString());
        Assert.Equal(["1\ta•••@example.com", "2\tb•••@example.com", ""], tsv.Split("\r\n"));
    }

    [Fact]
    public async Task ARemaskTakesTheColumnsReadAgain()
    {
        await using var database = await CoreDatabase.CreateAsync();
        using var data = await database.QueryAsync(Values);

        data.Data.Remasked([new ResultColumn("id", "", ValueKind.Integer), new ResultColumn("email", "", ValueKind.Text) { Masked = MaskStyle.Full }]);

        Assert.False(data.Data.IsColumnMasked(0));
        Assert.True(data.Data.IsColumnMasked(1));
        Assert.False(((IGridData)new FakeGridData(1, 1)).IsColumnMasked(0));
    }
}
