using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineTabCommandsTests
{
    private const string Initial = "select 1;\nselect 2;\n";

    private static VimSession Session() => new(Initial, caret: 3);

    private static VimExCommand? Handle(string command, int tabs = 0) => VimCommandLine.Parse(command, tabs);

    [Theory]
    [InlineData("gt", "tabnext")]
    [InlineData("3gt", "tabnext 3")]
    [InlineData("12gt", "tabnext 12")]
    [InlineData("gT", "tabprevious 1")]
    [InlineData("2gT", "tabprevious 2")]
    public void DispatchesTheTabCommand(string sequence, string command)
    {
        var s = Session();
        s.Press(sequence);
        Assert.Equal([command], s.Commands);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void GtLeavesTheBufferAlone()
    {
        var s = Session();
        s.Press("gt");
        Assert.Equal(Initial, s.Text);
        Assert.Equal((3, 0), s.Selection);
        Assert.Equal(0, s.UndoCount);
        Assert.Equal(0, s.RedoCount);
    }

    [Fact]
    public void CountIsConsumedByGt()
    {
        var s = Session();
        s.Press("3gt");
        s.Press("x");
        Assert.Equal("selct 1;\nselect 2;\n", s.Text);
    }

    [Fact]
    public void GtAfterAnOperatorCancelsBoth()
    {
        var s = Session();
        s.Press("dgt");
        Assert.Empty(s.Commands);
        Assert.Equal(Initial, s.Text);
        s.Press("x");
        Assert.Equal("selct 1;\nselect 2;\n", s.Text);
    }

    [Fact]
    public void GtInInsertModeGoesToTheTextView()
    {
        var s = Session();
        s.Press("i");
        var consumedG = s.Key("g");
        var consumedT = s.Key("t");
        Assert.False(consumedG);
        Assert.False(consumedT);
        Assert.Empty(s.Commands);
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Fact]
    public void HugeCountsBeforeGtAndGTStayBounded()
    {
        var s = Session();
        s.Press("99999999gt");
        s.Press("99999999gT");
        Assert.Equal(["tabnext 999999", "tabprevious 999999"], s.Commands);
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectTab(3), Handle(s.Commands[0], tabs: 3));
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectAdjacentTab(0), Handle(s.Commands[1], tabs: 3));
    }

    [Fact]
    public void ColonTabnextReachesTheHandler()
    {
        var s = Session();
        s.Press(":tabn 2");
        s.Key("\r");
        Assert.Equal(["tabn 2"], s.Commands);
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectTab(2), Handle(s.Commands[0]));
    }

    [Theory]
    [InlineData("tabn")]
    [InlineData("tabne")]
    [InlineData("tabnex")]
    [InlineData("tabnext")]
    [InlineData(" tabnext ")]
    public void TabnextSelectsTheNextTab(string command)
    {
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectAdjacentTab(1), Handle(command));
    }

    [Theory]
    [InlineData("tabn 4")]
    [InlineData("tabnext 4")]
    [InlineData("tabnext  4")]
    public void TabnextWithANumberSelectsThatTab(string command)
    {
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectTab(4), Handle(command));
    }

    [Theory]
    [InlineData("tabnext +2", 2)]
    [InlineData("tabn -3", -3)]
    public void TabnextWithASignMovesRelative(string command, int offset)
    {
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectAdjacentTab(offset), Handle(command));
    }

    [Theory]
    [InlineData("tabp 2")]
    [InlineData("tabpr 2")]
    [InlineData("tabprevious 2")]
    [InlineData("tabN 2")]
    [InlineData("tabNe 2")]
    [InlineData("tabNext 2")]
    public void TabpreviousWithACountMovesBack(string command)
    {
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectAdjacentTab(-2), Handle(command));
    }

    [Theory]
    [InlineData("tabp")]
    [InlineData("tabprevious")]
    [InlineData("tabN")]
    [InlineData("tabNext")]
    public void TabpreviousSelectsThePreviousTab(string command)
    {
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectAdjacentTab(-1), Handle(command));
    }

    [Theory]
    [InlineData("set")]
    [InlineData("tab")]
    [InlineData("tabnew")]
    [InlineData("tabnexts")]
    [InlineData("tabnext x")]
    [InlineData("tabnext 0")]
    [InlineData("tabp -1")]
    [InlineData("tabp +1")]
    [InlineData("tabnext 1 2")]
    [InlineData("TABN")]
    public void OtherCommandsDoNothing(string command)
    {
        Assert.Null(Handle(command));
    }

    [Theory]
    [InlineData("tabnext +9223372036854775807", 1)]
    [InlineData("tabnext -9223372036854775808", -2)]
    [InlineData("tabp 100000000000000000000", -1)]
    [InlineData("tabN 999999", 0)]
    public void HugeRelativeCountsMoveLessThanOneLap(string command, int offset)
    {
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectAdjacentTab(offset), Handle(command, tabs: 3));
    }

    [Theory]
    [InlineData("tabnext 99999999999999999999")]
    [InlineData("tabn 9223372036854775807")]
    [InlineData("tabnext 4")]
    public void AnAbsoluteCountPastTheLastTabSelectsTheLastTab(string command)
    {
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectTab(3), Handle(command, tabs: 3));
    }

    [Fact]
    public void WithoutATabCountACountStopsAtTheLimit()
    {
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectAdjacentTab(999_999), Handle("tabnext +9223372036854775807"));
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectAdjacentTab(-999_999), Handle("tabp 99999999999999999999"));
        Assert.Equal<VimExCommand?>(new VimExCommand.SelectTab(999_999), Handle("tabnext 99999999999999999999"));
    }

    [Fact]
    public void WriteAndQuitStillWork()
    {
        Assert.Equal<VimExCommand?>(new VimExCommand.RunQuery(), Handle("w"));
        Assert.Equal<VimExCommand?>(new VimExCommand.CloseTab(), Handle("q"));
    }

    [Theory]
    [InlineData(int.MaxValue)]
    [InlineData(int.MinValue)]
    [InlineData(int.MaxValue - 1)]
    [InlineData(int.MinValue + 1)]
    [InlineData(-4)]
    [InlineData(7)]
    public void AnyOffsetSelectsATabWithoutOverflow(int offset)
    {
        Assert.Equal((offset % 3 + 3) % 3, VimCommandLine.TargetTab(new VimExCommand.SelectAdjacentTab(offset), 0, 3));
    }

    [Fact]
    public void ATabNumberPastTheStripIsTheLastTab()
    {
        Assert.Equal(2, VimCommandLine.TargetTab(new VimExCommand.SelectTab(9), 0, 3));
        Assert.Equal(0, VimCommandLine.TargetTab(new VimExCommand.SelectTab(1), 2, 3));
        Assert.Null(VimCommandLine.TargetTab(new VimExCommand.CloseTab(), 0, 3));
        Assert.Null(VimCommandLine.TargetTab(new VimExCommand.SelectTab(1), 0, 0));
    }
}
