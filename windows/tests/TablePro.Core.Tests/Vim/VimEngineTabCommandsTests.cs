using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>gt and gT, which the engine turns into :tabnext and :tabprevious commands.</summary>
public sealed class VimEngineTabCommandsTests
{
    private const string Text = "select 1;\nselect 2;\n";

    private readonly VimHarness _h = new(Text, 3);
    private readonly List<string> _dispatched = [];

    public VimEngineTabCommandsTests() => _h.Engine.CommandEntered += (_, command) => _dispatched.Add(command);

    [Theory]
    [InlineData("gt", "tabnext")]
    [InlineData("3gt", "tabnext 3")]
    [InlineData("12gt", "tabnext 12")]
    [InlineData("gT", "tabprevious 1")]
    [InlineData("2gT", "tabprevious 2")]
    public void DispatchesTheTabCommand(string sequence, string command)
    {
        _h.Keys(sequence);
        Assert.Equal([command], _dispatched);
        Assert.Equal(VimMode.Normal, _h.Mode);
    }

    [Fact]
    public void GtLeavesTheBufferAlone()
    {
        _h.Keys("gt");
        Assert.Equal(Text, _h.Text);
        Assert.Equal((3, 0), (_h.Buffer.SelectionStart, _h.Buffer.SelectionLength));
        Assert.Equal(0, _h.Buffer.UndoCount);
    }

    [Fact]
    public void CountIsConsumedByGt()
    {
        _h.Keys("3gt");
        _h.Keys("x");
        Assert.Equal("selct 1;\nselect 2;\n", _h.Text);
    }

    [Fact]
    public void GtAfterAnOperatorCancelsBoth()
    {
        _h.Keys("dgt");
        Assert.Empty(_dispatched);
        Assert.Equal(Text, _h.Text);
        _h.Keys("x");
        Assert.Equal("selct 1;\nselect 2;\n", _h.Text);
    }

    [Fact]
    public void GtInInsertModeGoesToTheTextView()
    {
        _h.Keys("i");
        Assert.False(_h.Key('g'));
        Assert.False(_h.Key('t'));
        Assert.Empty(_dispatched);
        Assert.Equal(VimMode.Insert, _h.Mode);
    }

    [Fact]
    public void HugeCountsBeforeGtAndGTStayBounded()
    {
        var selected = new List<int>();
        var offsets = new List<int>();
        var handler = new VimCommandLineHandler { TabCount = () => 3 };
        handler.TabSelected += (_, tab) => selected.Add(tab);
        handler.AdjacentTabSelected += (_, offset) => offsets.Add(offset);
        _h.Engine.CommandEntered += (_, command) => handler.Handle(command);
        _h.Keys("99999999gt");
        _h.Keys("99999999gT");
        Assert.Equal(["tabnext 999999", "tabprevious 999999"], _dispatched);
        Assert.Equal([3], selected);
        Assert.Equal([0], offsets);
    }

    [Fact]
    public void ColonTabnextReachesTheHandler()
    {
        var selected = new List<int>();
        var handler = new VimCommandLineHandler();
        handler.TabSelected += (_, tab) => selected.Add(tab);
        _h.Engine.CommandEntered += (_, command) => handler.Handle(command);
        _h.Keys(":tabn 2");
        _h.Key('\r');
        Assert.Equal([2], selected);
    }
}

/// <summary>The tab commands <see cref="VimCommandLineHandler"/> accepts, with Vim's abbreviations and count rules.</summary>
public sealed class VimCommandLineHandlerTabTests
{
    private static Recorder Handle(string command, int? tabs = null)
    {
        var recorder = new Recorder();
        var handler = new VimCommandLineHandler { TabCount = tabs is { } count ? () => count : null };
        handler.TabSelected += (_, tab) => recorder.TabNumbers.Add(tab);
        handler.AdjacentTabSelected += (_, offset) => recorder.Offsets.Add(offset);
        handler.QuitRequested += (_, _) => recorder.Closed++;
        handler.WriteRequested += (_, _) => recorder.Executed++;
        handler.Handle(command);
        return recorder;
    }

    [Theory]
    [InlineData("tabn")]
    [InlineData("tabne")]
    [InlineData("tabnex")]
    [InlineData("tabnext")]
    [InlineData(" tabnext ")]
    public void TabnextSelectsTheNextTab(string command)
    {
        var recorder = Handle(command);
        Assert.Equal([1], recorder.Offsets);
        Assert.Empty(recorder.TabNumbers);
    }

    [Theory]
    [InlineData("tabn 4")]
    [InlineData("tabnext 4")]
    [InlineData("tabnext  4")]
    public void TabnextWithANumberSelectsThatTab(string command)
    {
        var recorder = Handle(command);
        Assert.Equal([4], recorder.TabNumbers);
        Assert.Empty(recorder.Offsets);
    }

    [Theory]
    [InlineData("tabnext +2", 2)]
    [InlineData("tabn -3", -3)]
    public void TabnextWithASignMovesRelative(string command, int offset) =>
        Assert.Equal([offset], Handle(command).Offsets);

    [Theory]
    [InlineData("tabp 2")]
    [InlineData("tabpr 2")]
    [InlineData("tabprevious 2")]
    [InlineData("tabN 2")]
    [InlineData("tabNe 2")]
    [InlineData("tabNext 2")]
    public void TabpreviousWithACountMovesBack(string command)
    {
        var recorder = Handle(command);
        Assert.Equal([-2], recorder.Offsets);
        Assert.Empty(recorder.TabNumbers);
    }

    [Theory]
    [InlineData("tabp")]
    [InlineData("tabprevious")]
    [InlineData("tabN")]
    [InlineData("tabNext")]
    public void TabpreviousSelectsThePreviousTab(string command) => Assert.Equal([-1], Handle(command).Offsets);

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
        var recorder = Handle(command);
        Assert.Empty(recorder.TabNumbers);
        Assert.Empty(recorder.Offsets);
        Assert.Equal(0, recorder.Closed);
        Assert.Equal(0, recorder.Executed);
    }

    [Theory]
    [InlineData("tabnext +9223372036854775807", 1)]
    [InlineData("tabnext -9223372036854775808", -2)]
    [InlineData("tabp 100000000000000000000", -1)]
    [InlineData("tabN 999999", 0)]
    public void HugeRelativeCountsMoveLessThanOneLap(string command, int offset) =>
        Assert.Equal([offset], Handle(command, tabs: 3).Offsets);

    [Theory]
    [InlineData("tabnext 99999999999999999999")]
    [InlineData("tabn 9223372036854775807")]
    [InlineData("tabnext 4")]
    public void AnAbsoluteCountPastTheLastTabSelectsTheLastTab(string command) =>
        Assert.Equal([3], Handle(command, tabs: 3).TabNumbers);

    [Fact]
    public void WithoutATabCountACountStopsAtTheLimit()
    {
        Assert.Equal([999_999], Handle("tabnext +9223372036854775807").Offsets);
        Assert.Equal([-999_999], Handle("tabp 99999999999999999999").Offsets);
        Assert.Equal([999_999], Handle("tabnext 99999999999999999999").TabNumbers);
    }

    [Fact]
    public void WriteAndQuitStillWork()
    {
        Assert.Equal(1, Handle("w").Executed);
        Assert.Equal(1, Handle("q").Closed);
    }

    private sealed class Recorder
    {
        public List<int> TabNumbers { get; } = [];

        public List<int> Offsets { get; } = [];

        public int Closed { get; set; }

        public int Executed { get; set; }
    }
}
