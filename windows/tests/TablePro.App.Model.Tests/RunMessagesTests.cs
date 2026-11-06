using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class RunMessagesTests
{
    private const string CutShort = "The output was cut short.";

    [Fact]
    public void EachNoticeIsALineWithItsSeverity()
    {
        var messages = new RunMessages(CutShort);

        messages.Add(new QueryEvent.Notice("NOTICE", "step 1 done", "00000"));
        messages.Add(new QueryEvent.CommandCompleted(null));
        messages.Add(new QueryEvent.Notice("WARNING", "w", "01000"));

        Assert.Equal("NOTICE: step 1 done\nWARNING: w", messages.Text);
    }

    [Fact]
    public void TheNoticeLimitSaysTheOutputWasCutShort()
    {
        var messages = new RunMessages(CutShort);

        messages.Add(new QueryEvent.Notice("NOTICE", "row 1", null));
        messages.Add(new QueryEvent.NoticeLimitReached(1));

        Assert.Equal("NOTICE: row 1\nThe output was cut short.", messages.Text);
    }

    [Fact]
    public void ANewRunStartsEmpty()
    {
        var messages = new RunMessages(CutShort);
        messages.Add(new QueryEvent.Notice("NOTICE", "earlier", null));

        messages.Reset();

        Assert.True(messages.IsEmpty);
        Assert.Equal(string.Empty, messages.Text);
    }

    [Fact]
    public void ARunWithNoRowsOpensOnWhatItPrinted()
    {
        var messages = new RunMessages(CutShort);
        messages.Add(new QueryEvent.Notice("NOTICE", "hi", null));

        Assert.Equal(ResultsView.Messages, messages.ViewAtEnd(hasRows: false, picked: null));
        Assert.Equal(ResultsView.Results, messages.ViewAtEnd(hasRows: true, picked: null));
        Assert.Equal(ResultsView.Results, messages.ViewAtEnd(hasRows: false, picked: ResultsView.Results));
        Assert.Equal(ResultsView.Messages, messages.ViewAtEnd(hasRows: true, picked: ResultsView.Messages));
    }

    [Fact]
    public void ARunThatPrintedNothingShowsItsResults()
    {
        var messages = new RunMessages(CutShort);

        Assert.Equal(ResultsView.Results, messages.ViewAtEnd(hasRows: false, picked: null));
        Assert.Equal(ResultsView.Results, messages.ViewAtEnd(hasRows: false, picked: ResultsView.Messages));
    }
}
