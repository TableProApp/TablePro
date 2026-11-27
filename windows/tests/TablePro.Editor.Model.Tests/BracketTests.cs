namespace TablePro.Editor.Model.Tests;

public sealed class BracketTests
{
    private static (int Open, int Close)? Find(string text, int caret, bool plain = false)
    {
        var document = new TextDocument(text);
        var spans = new SyntaxSpan[Math.Max(1, text.Length)];
        var count = new FakeLexer().Tokenize(text, spans);
        return plain
            ? BracketMatch.Find(document, caret, [], null)
            : BracketMatch.Find(document, caret, spans.Take(count).ToList(), FakeStructure.FakeRoles);
    }

    [Fact]
    public void TheBracketBeforeTheCaretPairsFirst()
    {
        Assert.Equal((5, 10), Find("count(f(x))", 6));
        Assert.Equal((5, 10), Find("count(f(x))", 11));
        Assert.Equal((7, 9), Find("count(f(x))", 10));
    }

    [Fact]
    public void TheBracketAfterTheCaretPairsWhenNoneIsBefore()
    {
        Assert.Equal((5, 10), Find("count(f(x))", 5));
    }

    [Fact]
    public void BracketsInsideStringsAndCommentsAreSkipped()
    {
        Assert.Equal((0, 14), Find("(')' /* ) */ 1)", 1));
        Assert.Null(Find("')'", 2));
    }

    [Fact]
    public void AnUnpairedBracketHasNoMatch()
    {
        Assert.Null(Find("select (1", 8));
        Assert.Null(Find("select 1", 3));
    }

    [Fact]
    public void ATextWithoutTokensPairsPlainCharacters()
    {
        Assert.Equal((10, 15), Find("db.t.find({a: 1})", 11, plain: true));
        Assert.Equal((9, 16), Find("db.t.find({a: 1})", 17, plain: true));
    }

    [Fact]
    public void EverySchemeHasAnIdANameAndOpaqueText()
    {
        Assert.Equal(14, ColorSchemes.All.Count);
        Assert.Equal(ColorSchemes.All.Count, ColorSchemes.All.Select(scheme => scheme.Id).Distinct().Count());
        Assert.All(ColorSchemes.All, scheme =>
        {
            Assert.False(string.IsNullOrWhiteSpace(scheme.Name));
            Assert.Equal(0xFFu, scheme.Text >> 24);
            Assert.Equal(0xFFu, scheme.Background >> 24);
        });
        Assert.Equal("Dracula", ColorSchemes.Find("tablepro.dracula")?.Name);
        Assert.True(ColorSchemes.Find("tablepro.dracula")?.IsDark);
        Assert.Null(ColorSchemes.Find("tablepro.missing"));
        Assert.Null(ColorSchemes.Find(null));
    }
}
