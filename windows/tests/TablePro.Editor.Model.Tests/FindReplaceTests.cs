using System.Diagnostics;

namespace TablePro.Editor.Model.Tests;

public sealed class FindReplaceTests
{
    [Fact]
    public void APatternHonorsMatchCaseAndAnchorsAtLineStarts()
    {
        var document = new TextDocument("SELECT Id FROM t; select id from u\nfrom v");
        var anyCase = new SearchQuery(@"sel\w+", UseRegex: true);

        Assert.Equal((0, 6), TextSearch.Next(document, anyCase, 0, backward: false)!.Value);
        Assert.Equal((18, 6), TextSearch.Next(document, anyCase with { MatchCase = true }, 0, backward: false)!.Value);
        Assert.Equal((35, 4), TextSearch.Next(document, new SearchQuery("^from", UseRegex: true), 0, false)!.Value);
    }

    [Fact]
    public void WholeWordAppliesAroundThePattern()
    {
        var document = new TextDocument("select id, ident, xid, id_2 from t");
        var query = new SearchQuery(@"id\w*", WholeWord: true, UseRegex: true);

        Assert.Equal<(int, int)>([(7, 2), (11, 5), (23, 4)], TextSearch.InRange(document, query, 0, document.Length));
    }

    [Fact]
    public void AnInvalidPatternFindsNothing()
    {
        var document = new TextDocument("select (a) from t");
        var broken = new SearchQuery("(a", UseRegex: true);

        Assert.False(TextSearch.IsValid(broken));
        Assert.Null(TextSearch.Next(document, broken, 0, backward: false));
        Assert.Empty(TextSearch.InRange(document, broken, 0, document.Length));
        Assert.Empty(TextSearch.Replacements(document, broken, "b"));
        Assert.Null(TextSearch.ReplacementAt(document, broken, 7, 2, "b"));
        // Wrapped for whole word it would parse, so it is checked unwrapped first.
        Assert.False(TextSearch.IsValid(new SearchQuery("a)|(b", WholeWord: true, UseRegex: true)));

        var literal = broken with { UseRegex = false };
        Assert.True(TextSearch.IsValid(literal));
        Assert.Equal((7, 2), TextSearch.Next(document, literal, 0, backward: false)!.Value);
    }

    [Fact]
    public void EmptyMatchesAreSteppedOver()
    {
        var document = new TextDocument("ab x xx");
        var stars = new SearchQuery("x*", UseRegex: true);
        var anchor = new SearchQuery("^", UseRegex: true);

        Assert.Equal<(int, int)>([(3, 1), (5, 2)], TextSearch.InRange(document, stars, 0, document.Length));
        Assert.Equal((3, 1), TextSearch.Next(document, stars, 0, backward: false)!.Value);
        Assert.Equal((5, 2), TextSearch.Next(document, stars, 7, backward: true)!.Value);
        Assert.Null(TextSearch.Next(document, anchor, 0, backward: false));
        Assert.Empty(TextSearch.InRange(document, anchor, 0, document.Length));
        Assert.Empty(TextSearch.Replacements(document, anchor, "-- "));
    }

    // Nested quantifiers over a run of one letter backtrack for far longer than the timeout.
    [Fact]
    public void APatternPastTheTimeoutFindsNothing()
    {
        var document = new TextDocument(new string('a', 64));
        var runaway = new SearchQuery("(a+)+ac", UseRegex: true);
        var watch = Stopwatch.StartNew();

        Assert.Null(TextSearch.Next(document, runaway, 0, backward: false));
        Assert.Empty(TextSearch.InRange(document, runaway, 0, document.Length));
        Assert.Empty(TextSearch.Replacements(document, runaway, "b"));

        Assert.InRange(watch.Elapsed, TimeSpan.Zero, TimeSpan.FromSeconds(30));
    }

    // The timeout belongs to the text that ran past it: another document, or this one edited, is searched again.
    [Fact]
    public void APatternThatTimedOutFindsMatchesInOtherText()
    {
        var runaway = new SearchQuery("(a+)+ac", UseRegex: true);
        var runs = new TextDocument(new string('a', 64));
        Assert.Null(TextSearch.Next(runs, runaway, 0, backward: false));

        var other = new TextDocument("xaac");

        Assert.Equal((1, 3), TextSearch.Next(other, runaway, 0, backward: false)!.Value);
    }

    [Fact]
    public void SelectedTextEscapedIntoAPatternFindsItself()
    {
        const string text = "price * (1 + rate)";
        var document = new TextDocument("select " + text + " from t");
        var query = new SearchQuery(TextSearch.EscapePattern(text), UseRegex: true);

        Assert.Equal((7, text.Length), TextSearch.Next(document, query, 0, backward: false)!.Value);
    }

    [Fact]
    public void ReplaceTakesTheSelectedMatchAndFindsTheNextAfterIt()
    {
        var model = Carets.Model("select a, b, a from t");
        var query = new SearchQuery("a", WholeWord: true);
        model.SetSelection(7, 8);

        var replacement = TextSearch.ReplacementAt(model.Document, query, 7, 1, "x");
        model.ReplaceRange(7, 8, replacement!);
        var next = TextSearch.Next(model.Document, query, model.Primary.End, backward: false);

        Assert.Equal("select x|, b, a from t", Carets.Show(model));
        Assert.Equal((13, 1), next!.Value);
        Assert.Null(TextSearch.ReplacementAt(model.Document, query, 10, 1, "x"));
    }

    [Fact]
    public void ReplaceWithAPatternExpandsItsGroups()
    {
        var document = new TextDocument("select first_name from t");
        var query = new SearchQuery(@"(\w+)_name", UseRegex: true);

        Assert.Equal("firstName", TextSearch.ReplacementAt(document, query, 7, 10, "$1Name"));
        Assert.Null(TextSearch.ReplacementAt(document, query, 7, 5, "$1Name"));
    }

    [Fact]
    public void ReplaceAllExpandsGroupsAndTheCaretStaysWithItsText()
    {
        var model = Carets.Model("select first_name, last_name |from people");
        var query = new SearchQuery(@"(?<word>\w+)_name", UseRegex: true);

        model.ReplaceRanges(TextSearch.Replacements(model.Document, query, "${word}Name"));

        Assert.Equal("select firstName, lastName |from people", Carets.Show(model));
        Assert.Equal<(int, int, string)>(
            [(0, 2, "1a$"), (3, 2, "2b$")],
            TextSearch.Replacements(new TextDocument("a1 b2"), new SearchQuery(@"(\w)(\d)", UseRegex: true), "$2$1$$"));
    }

    [Fact]
    public void ALiteralReplacementKeepsItsDollarSigns()
    {
        var document = new TextDocument("a b a");

        Assert.Equal<(int, int, string)>(
            [(0, 1, "$1$$"), (4, 1, "$1$$")], TextSearch.Replacements(document, new SearchQuery("a"), "$1$$"));
    }

    [Fact]
    public void ReplaceAllIsOneUndoStepAndReportsEachChange()
    {
        var model = Carets.Model("select id, name from t where id = 1|");
        var changes = 0;
        model.Document.Changed += (_, _) => changes++;

        model.ReplaceRanges(
            TextSearch.Replacements(model.Document, new SearchQuery("id", WholeWord: true), "user_id"));

        Assert.Equal("select user_id, name from t where user_id = 1|", Carets.Show(model));
        Assert.Equal(2, changes);
        Assert.Equal(1, model.Document.Undo.UndoCount);
        model.Undo();
        Assert.Equal("select id, name from t where id = 1|", Carets.Show(model));
        model.Redo();
        Assert.Equal("select user_id, name from t where user_id = 1|", Carets.Show(model));
    }
}
