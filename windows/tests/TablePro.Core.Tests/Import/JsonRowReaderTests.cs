using System.Text;
using TablePro.Core.Import;

namespace TablePro.Core.Tests.Import;

public sealed class JsonRowReaderTests
{
    private static async Task<List<IReadOnlyDictionary<string, object?>>> Read(string json)
    {
        using var stream = new MemoryStream(Encoding.UTF8.GetBytes(json));
        var rows = new List<IReadOnlyDictionary<string, object?>>();
        await foreach (var row in JsonRowReader.ReadAsync(stream, TestContext.Current.CancellationToken))
        {
            rows.Add(row);
        }

        return rows;
    }

    [Fact]
    public async Task ReadsAnArrayOfObjectsWithTypedValues()
    {
        var rows = await Read("  [ {\"id\": 1, \"price\": 9.5, \"name\": \"Ana\", \"ok\": true, \"tags\": [\"a\"], \"gone\": null}, {\"id\": 2} ]");

        Assert.Equal(2, rows.Count);
        Assert.Equal(1L, rows[0]["id"]);
        Assert.Equal(9.5m, rows[0]["price"]);
        Assert.Equal("Ana", rows[0]["name"]);
        Assert.Equal(true, rows[0]["ok"]);
        Assert.Equal("[\"a\"]", rows[0]["tags"]);
        Assert.Null(rows[0]["gone"]);
        Assert.Single(rows[1]);
    }

    [Fact]
    public async Task ReadsNewlineDelimitedJson()
    {
        var rows = await Read("{\"id\": 1}\n\n{\"id\": 2, \"name\": \"Binh\"}\n");

        Assert.Equal(["1", "2"], rows.Select(r => r["id"]!.ToString()));
        Assert.Equal("Binh", rows[1]["name"]);
    }

    [Fact]
    public async Task ReadsAnArrayAfterAByteOrderMark()
    {
        var rows = await Read("﻿[{\"id\": 3}]");

        Assert.Equal(3L, Assert.Single(rows)["id"]);
    }
}
