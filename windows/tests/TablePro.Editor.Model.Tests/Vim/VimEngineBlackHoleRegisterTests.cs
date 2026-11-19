namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineBlackHoleRegisterTests
{
    private const string Initial = "one\ntwo\nthree\n";

    [Theory]
    [InlineData("\"_dd")]
    [InlineData("\"_2dd")]
    [InlineData("\"_x")]
    [InlineData("\"_dw")]
    [InlineData("\"_yy")]
    [InlineData("\"_yw")]
    [InlineData("l\"_X")]
    [InlineData("\"_s")]
    [InlineData("\"_cc")]
    public void WritesNoRegisterAndNoClipboard(string sequence)
    {
        var s = new VimSession(Initial);
        s.Press("yyj");
        var numbered = s.Engine.NumberedRegisters.Select(r => r.Text).ToArray();

        s.Press(sequence);

        Assert.Equal("one\n", s.Engine.Register.Text);
        Assert.True(s.Engine.Register.IsLinewise);
        Assert.Equal(numbered, s.Engine.NumberedRegisters.Select(r => r.Text).ToArray());
        Assert.Empty(s.Engine.NamedRegisters);
        Assert.Equal(["one\n"], s.Clipboard);
    }

    [Fact]
    public void PasteAfterABlackHoleDeletePastesTheEarlierYank()
    {
        var s = new VimSession(Initial);
        s.Press("yyj\"_ddp");
        Assert.Equal("one\nthree\none\n", s.Text);
    }

    [Fact]
    public void TheBlackHoleAppliesToOneCommandOnly()
    {
        var s = new VimSession(Initial);
        s.Press("yyj\"_dddd");
        Assert.Equal("one\n", s.Text);
        Assert.Equal("three\n", s.Engine.Register.Text);
        Assert.Equal(["one\n", "three\n"], s.Clipboard);
    }
}
