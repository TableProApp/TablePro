namespace TablePro.Core.Tests.Vim;

/// <summary>The "_ register discards what a command deletes or yanks, for that one command.</summary>
public sealed class VimEngineBlackHoleRegisterTests
{
    private const string Sample = "one\ntwo\nthree\n";

    // RegisterWritten is the clipboard hook, so recording it stands in for the macOS recording clipboard.
    private static (VimHarness Harness, List<string> ClipboardWrites) Make()
    {
        var h = new VimHarness(Sample, 0);
        var writes = new List<string>();
        h.Engine.RegisterWritten += (_, register) => writes.Add(register.Text);
        return (h, writes);
    }

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
        var (h, writes) = Make();
        h.Keys("yyj");
        var numbered = h.Engine.NumberedRegisters.Select(r => r.Text).ToArray();

        h.Keys(sequence);

        Assert.Equal("one\n", h.Engine.Register.Text);
        Assert.True(h.Engine.Register.IsLinewise);
        Assert.Equal(numbered, h.Engine.NumberedRegisters.Select(r => r.Text).ToArray());
        Assert.Empty(h.Engine.NamedRegisters);
        Assert.Equal(["one\n"], writes);
    }

    [Fact]
    public void PasteAfterABlackHoleDeletePastesTheEarlierYank()
    {
        var (h, _) = Make();
        h.Keys("yyj\"_ddp");
        Assert.Equal("one\nthree\none\n", h.Text);
    }

    [Fact]
    public void TheBlackHoleAppliesToOneCommandOnly()
    {
        var (h, writes) = Make();
        h.Keys("yyj\"_dddd");
        Assert.Equal("one\n", h.Text);
        Assert.Equal("three\n", h.Engine.Register.Text);
        Assert.Equal(["one\n", "three\n"], writes);
    }
}
