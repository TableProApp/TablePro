using TablePro.Core.Debugging;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Debugging;

public sealed class DebugStartFormTests
{
    private static readonly DebugEntryPoint WithDefaults = new(
        "1",
        "run(p_n integer, p_rate numeric DEFAULT 0.1, p_total numeric OUT)",
        [
            new DebugParameter("p_n", "integer", DebugParameterMode.Input, false),
            new DebugParameter("p_rate", "numeric", DebugParameterMode.Input, true),
            new DebugParameter("p_total", "numeric", DebugParameterMode.Output, false),
        ]);

    private static readonly DebugEntryPoint NoArguments = new("2", "run()", []);

    private static RoutineDebugPlan Plan(params DebugEntryPoint[] entryPoints) =>
        new(new RoutineDebugTarget(string.Empty, new ObjectName("public", "run"), "run", "Function"), entryPoints, true);

    [Fact]
    public void ADefaultedParameterStartsAtItsDefaultAndAnOutputTakesNoValue()
    {
        var form = new DebugStartForm(Plan(WithDefaults));

        Assert.False(form.Arguments[0].UsesDefault);
        Assert.True(form.Arguments[1].UsesDefault);
        Assert.False(form.Arguments[2].TakesValue);
        Assert.False(form.Arguments[2].CanUseDefault);

        form.Arguments[0].Text = "5";
        var choice = form.ToChoice()!;
        Assert.Equal(["p_n", "p_rate"], choice.Arguments.Select(a => a.ParameterName));
        Assert.Equal(DebugArgumentValue.FromText("5"), choice.Arguments[0].Value);
        Assert.Equal(DebugArgumentValue.Default, choice.Arguments[1].Value);
    }

    [Fact]
    public void NullAndDefaultExcludeEachOther()
    {
        var rate = new DebugStartForm(Plan(WithDefaults)).Arguments[1];

        rate.IsNull = true;
        Assert.False(rate.UsesDefault);
        Assert.Equal(DebugArgumentValue.Null, rate.Value);

        rate.UsesDefault = true;
        Assert.False(rate.IsNull);
        Assert.Equal(DebugArgumentValue.Default, rate.Value);
    }

    [Fact]
    public void AParameterWithoutADefaultCannotUseOne()
    {
        var count = new DebugStartForm(Plan(WithDefaults)).Arguments[0];

        count.UsesDefault = true;

        Assert.False(count.UsesDefault);
        Assert.Equal(DebugArgumentValue.FromText(string.Empty), count.Value);
    }

    [Fact]
    public void ChoosingAnotherEntryPointStartsItsArgumentsOver()
    {
        var form = new DebugStartForm(Plan(WithDefaults, NoArguments));
        form.Arguments[0].Text = "5";

        Assert.True(form.SelectEntryPoint(1));
        Assert.Empty(form.Arguments);
        Assert.Equal("2", form.ToChoice()!.EntryPoint.Identity);
        Assert.False(form.SelectEntryPoint(1));
        Assert.False(form.SelectEntryPoint(5));
    }

    [Fact]
    public void APlanWithoutEntryPointsHasNoChoice() => Assert.Null(new DebugStartForm(Plan()).ToChoice());

    [Theory]
    [InlineData("", new string[0])]
    [InlineData("a", new[] { "a" })]
    [InlineData("a\nb\n", new[] { "a", "b" })]
    [InlineData("\nBEGIN\r\n  x := 1;\rEND;", new[] { "", "BEGIN", "  x := 1;", "END;" })]
    [InlineData("a\n\nb", new[] { "a", "", "b" })]
    public void SourceLinesMatchTheEnginesCount(string source, string[] expected) => Assert.Equal(expected, DebugSourceText.Lines(source));
}
