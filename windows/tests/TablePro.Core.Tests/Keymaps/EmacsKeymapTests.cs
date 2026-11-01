using TablePro.Core.Keymaps;

namespace TablePro.Core.Tests.Keymaps;

public sealed class EmacsKeymapTests
{
    private static EmacsCommand? Resolve(char key, bool control = false, bool alt = false, bool shift = false, bool markActive = false) =>
        EmacsKeymap.Resolve(new EmacsKeystroke(EmacsKey.Character, key, control, alt, shift), markActive);

    private static EmacsCommand? Resolve(EmacsKey key, bool control = false, bool alt = false, bool shift = false, bool markActive = false) =>
        EmacsKeymap.Resolve(new EmacsKeystroke(key, '\0', control, alt, shift), markActive);

    [Theory]
    [InlineData('a', EmacsCommandKind.Move, EmacsMotion.BeginningOfLine)]
    [InlineData('e', EmacsCommandKind.Move, EmacsMotion.EndOfLine)]
    [InlineData('f', EmacsCommandKind.Move, EmacsMotion.ForwardChar)]
    [InlineData('b', EmacsCommandKind.Move, EmacsMotion.BackwardChar)]
    [InlineData('n', EmacsCommandKind.Move, EmacsMotion.NextLine)]
    [InlineData('p', EmacsCommandKind.Move, EmacsMotion.PreviousLine)]
    [InlineData('k', EmacsCommandKind.KillLine, default(EmacsMotion))]
    [InlineData('y', EmacsCommandKind.Yank, default(EmacsMotion))]
    [InlineData('w', EmacsCommandKind.KillRegion, default(EmacsMotion))]
    [InlineData('g', EmacsCommandKind.Quit, default(EmacsMotion))]
    public void ControlKeysAreBound(char key, EmacsCommandKind kind, EmacsMotion motion) =>
        Assert.Equal(new EmacsCommand(kind, motion), Resolve(key, control: true));

    [Theory]
    [InlineData('f', EmacsCommandKind.Move, EmacsMotion.ForwardWord)]
    [InlineData('b', EmacsCommandKind.Move, EmacsMotion.BackwardWord)]
    [InlineData('d', EmacsCommandKind.KillWord, default(EmacsMotion))]
    [InlineData('y', EmacsCommandKind.YankPop, default(EmacsMotion))]
    [InlineData('w', EmacsCommandKind.CopyRegion, default(EmacsMotion))]
    public void AltIsMetaForTheBoundKeys(char key, EmacsCommandKind kind, EmacsMotion motion) =>
        Assert.Equal(new EmacsCommand(kind, motion), Resolve(key, alt: true));

    [Fact]
    public void AltBackspaceKillsTheWordBeforeTheCaret() =>
        Assert.Equal(EmacsCommand.Of(EmacsCommandKind.BackwardKillWord), Resolve(EmacsKey.Backspace, alt: true));

    [Fact]
    public void CtrlSpaceAndCtrlAtSetTheMark()
    {
        var setMark = EmacsCommand.Of(EmacsCommandKind.SetMark);
        Assert.Equal(setMark, Resolve(EmacsKey.Space, control: true));
        Assert.Equal(setMark, Resolve(' ', control: true));
        Assert.Equal(setMark, Resolve('@', control: true, shift: true));
        Assert.Equal(setMark, Resolve('2', control: true, shift: true));
    }

    [Fact]
    public void AltOnAnUnboundKeyStaysWithTheEditor()
    {
        Assert.Null(Resolve('l', alt: true));
        Assert.Null(Resolve('5', alt: true));
        Assert.Null(Resolve('e', alt: true));
    }

    [Fact]
    public void ShiftedAltGrAndUnboundControlChordsPassThrough()
    {
        Assert.Null(Resolve('f', control: true, alt: true));
        Assert.Null(Resolve('F', control: true, shift: true));
        Assert.Null(Resolve('F', alt: true, shift: true));
        Assert.Null(Resolve('t', control: true));
        Assert.Null(Resolve('d', control: true));
        Assert.Null(Resolve('c', control: true));
        Assert.Null(Resolve('v', control: true));
        Assert.Null(Resolve('z', control: true));
        Assert.Null(Resolve('f'));
    }

    [Fact]
    public void CapsLockDoesNotChangeAChord() =>
        Assert.Equal(EmacsCommand.Move(EmacsMotion.ForwardChar), Resolve('F', control: true));

    [Fact]
    public void TheArrowsExtendAnActiveRegionAndAreLeftAloneOtherwise()
    {
        Assert.Equal(EmacsCommand.Move(EmacsMotion.BackwardChar), Resolve(EmacsKey.Left, markActive: true));
        Assert.Equal(EmacsCommand.Move(EmacsMotion.ForwardChar), Resolve(EmacsKey.Right, markActive: true));
        Assert.Equal(EmacsCommand.Move(EmacsMotion.PreviousLine), Resolve(EmacsKey.Up, markActive: true));
        Assert.Equal(EmacsCommand.Move(EmacsMotion.NextLine), Resolve(EmacsKey.Down, markActive: true));
        Assert.Null(Resolve(EmacsKey.Left));
        Assert.Null(Resolve(EmacsKey.Left, shift: true, markActive: true));
        Assert.Null(Resolve(EmacsKey.Other, markActive: true));
    }
}
