using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineComposedCharacterTests
{
    internal const string ThumbsUp = "\U0001F44D";
    internal const string Family = "\U0001F468\u200D\U0001F469\u200D\U0001F467";
    internal const string Accented = "e\u0301";

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void XDeletesTheWholeCharacter(string character)
    {
        var s = new VimSession($"a{character}b\n", caret: 1);
        s.Press("x");
        Assert.Equal("ab\n", s.Text);
        Assert.Equal(1, s.Caret);
        Assert.Equal(character, s.Engine.Register.Text);
    }

    [Fact]
    public void XOnAnEmojiInAStatement()
    {
        var s = new VimSession($"INSERT INTO notes VALUES ('ok {ThumbsUp}')\n", caret: 30);
        s.Press("x");
        Assert.Equal("INSERT INTO notes VALUES ('ok ')\n", s.Text);
        Assert.Equal(30, s.Caret);
    }

    [Fact]
    public void CountedXDeletesWholeCharactersOfEachKind()
    {
        var s = new VimSession($"a{ThumbsUp}{Family}{Accented}z\n", caret: 1);
        s.Press("3x");
        Assert.Equal("az\n", s.Text);
        Assert.Equal(1, s.Caret);
        Assert.Equal(ThumbsUp + Family + Accented, s.Engine.Register.Text);
    }

    [Fact]
    public void XOnTheLastCharacterLandsOnTheStartOfTheNewLastOne()
    {
        var s = new VimSession($"a{ThumbsUp}{ThumbsUp}\n", caret: 3);
        s.Press("x");
        Assert.Equal($"a{ThumbsUp}\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void CapitalXDeletesTheWholeCharacterBeforeTheCaret(string character)
    {
        var s = new VimSession($"a{character}b\n", caret: 1 + character.Length);
        s.Press("X");
        Assert.Equal("ab\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void CountedCapitalXDeletesWholeCharacters()
    {
        var s = new VimSession($"a{Family}{Accented}b\n", caret: 1 + Family.Length + Accented.Length);
        s.Press("2X");
        Assert.Equal("ab\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void SSubstitutesTheWholeCharacter(string character)
    {
        var s = new VimSession($"a{character}b\n", caret: 1);
        s.Press("s");
        Assert.Equal("ab\n", s.Text);
        Assert.Equal(1, s.Caret);
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void RReplacesTheWholeCharacter(string character)
    {
        var s = new VimSession($"a{character}b\n", caret: 1);
        s.Press("r-");
        Assert.Equal("a-b\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void CountedRReplacesEmojiByCharacter()
    {
        var s = new VimSession($"{ThumbsUp}{ThumbsUp}z\n", caret: 0);
        s.Press("2r*");
        Assert.Equal("**z\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void RWithAnEmojiLeavesTheCaretOnTheLastOneWritten()
    {
        var s = new VimSession("abcd\n", caret: 0);
        s.Press($"3r{ThumbsUp}");
        Assert.Equal($"{ThumbsUp}{ThumbsUp}{ThumbsUp}d\n", s.Text);
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void RCountsCharactersLeftOnTheLine()
    {
        // Two characters remain, so 3r is refused.
        var refused = new VimSession($"a{ThumbsUp}\n", caret: 0);
        refused.Press("3rx");
        Assert.Equal($"a{ThumbsUp}\n", refused.Text);
        Assert.Equal(0, refused.Caret);

        var replaced = new VimSession($"a{ThumbsUp}\n", caret: 0);
        replaced.Press("2rx");
        Assert.Equal("xx\n", replaced.Text);
        Assert.Equal(1, replaced.Caret);
    }

    [Fact]
    public void TildeTogglesAcrossAnEmoji()
    {
        var s = new VimSession($"a{ThumbsUp}b\n", caret: 0);
        s.Press("3~");
        Assert.Equal($"A{ThumbsUp}B\n", s.Text);
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void TildeKeepsTheMarkOnItsLetter()
    {
        var s = new VimSession($"{Accented}x\n", caret: 0);
        s.Press("~");
        Assert.Equal("E\u0301x\n", s.Text);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void TildeLandsAfterACaseChangeThatGrowsTheText()
    {
        var s = new VimSession("\u00DFa\n", caret: 0);
        s.Press("~");
        Assert.Equal("SSa\n", s.Text);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void HAndLStepOneCharacterAtATime()
    {
        // a 0, thumbs up 1, b 3, family 4, c 12, space 13, accented e 14, x 16
        var s = new VimSession($"a{ThumbsUp}b{Family}c {Accented}x\n", caret: 0);
        var forward = new List<int>();
        for (var i = 0; i < 8; i++)
        {
            s.Press("l");
            forward.Add(s.Caret);
        }
        Assert.Equal([1, 3, 4, 12, 13, 14, 16, 16], forward);
        var backward = new List<int>();
        for (var i = 0; i < 8; i++)
        {
            s.Press("h");
            backward.Add(s.Caret);
        }
        Assert.Equal([14, 13, 12, 4, 3, 1, 0, 0], backward);
    }

    [Fact]
    public void CountedLAndHCrossSeveralCharacters()
    {
        var s = new VimSession($"a{ThumbsUp}b{Family}c {Accented}x\n", caret: 0);
        s.Press("3l");
        Assert.Equal(4, s.Caret);
        s.Press("$");
        s.Press("3h");
        Assert.Equal(12, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void DollarLandsOnTheStartOfAFinalCharacter(string character)
    {
        var s = new VimSession($"ok {character}\nnext\n", caret: 0);
        s.Press("$");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void JLandsOnACharacterStart()
    {
        // Column 2 on the second line is the second half of the emoji.
        var s = new VimSession($"abcdef\nx{ThumbsUp}yz\n", caret: 2);
        s.Press("j");
        Assert.Equal(8, s.Caret);
        s.Press("k");
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void ELandsOnTheStartOfAnEmojiWord()
    {
        var s = new VimSession($"ab {ThumbsUp} cd\n", caret: 0);
        s.Press("ee");
        Assert.Equal(3, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void AAppendsAfterTheWholeCharacter(string character)
    {
        var s = new VimSession($"x{character}\n", caret: 1);
        s.Press("a");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(1 + character.Length, s.Caret);
        s.Type("!");
        Assert.Equal($"x{character}!\n", s.Text);
        s.Escape();
        Assert.Equal(1 + character.Length, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void EscapeFromInsertStepsBackOverTheWholeCharacter(string character)
    {
        var s = new VimSession($"ab{character}\n", caret: 2 + character.Length);
        s.Press("i");
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void PPastesAfterTheEmojiUnderTheCaret()
    {
        var s = new VimSession($"a{ThumbsUp}b\n", caret: 3);
        s.Press("x");
        Assert.Equal($"a{ThumbsUp}\n", s.Text);
        Assert.Equal(1, s.Caret);
        s.Press("p");
        Assert.Equal($"a{ThumbsUp}b\n", s.Text);
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void PLeavesTheCaretOnTheStartOfAPastedEmoji()
    {
        var s = new VimSession($"{ThumbsUp}ab\n", caret: 0);
        s.Press("x");
        s.Press("p");
        Assert.Equal($"a{ThumbsUp}b\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void DeDeletesThroughAnEmojiWord()
    {
        var s = new VimSession($"say {ThumbsUp} now\n", caret: 3);
        s.Press("de");
        Assert.Equal("say now\n", s.Text);
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void DeDeletesThroughALetterAndItsMark()
    {
        var s = new VimSession($"caf{Accented} ok\n", caret: 0);
        s.Press("de");
        Assert.Equal(" ok\n", s.Text);
        Assert.Equal(0, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void DfDeletesThroughTheTargetCharacter(string character)
    {
        var s = new VimSession($"go {character} now\n", caret: 0);
        s.Press($"df{character}");
        Assert.Equal(" now\n", s.Text);
        Assert.Equal(0, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    [InlineData("q")]
    public void DlDeletesTheCharacterUnderTheCaret(string character)
    {
        var s = new VimSession($"a{character}b\n", caret: 1);
        s.Press("dl");
        Assert.Equal("ab\n", s.Text);
        Assert.Equal(1, s.Caret);
        Assert.Equal(character, s.Engine.Register.Text);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    [InlineData("q")]
    public void DlOnTheLastCharacterDeletesItAndStaysOnTheLine(string character)
    {
        var s = new VimSession($"a{character}\nnext\n", caret: 1);
        s.Press("dl");
        Assert.Equal("a\nnext\n", s.Text);
        Assert.Equal(0, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    [InlineData("q")]
    public void DhDeletesTheCharacterBeforeTheCaret(string character)
    {
        var s = new VimSession($"a{character}b\n", caret: 1 + character.Length);
        s.Press("dh");
        Assert.Equal("ab\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void CountedDlStopsAtTheLineEnd()
    {
        var s = new VimSession($"a{ThumbsUp}{Family}\nnext\n", caret: 1);
        s.Press("5dl");
        Assert.Equal("a\nnext\n", s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void ClChangesTheWholeCharacter()
    {
        var s = new VimSession($"a{Family}b\n", caret: 1);
        s.Press("cl");
        Assert.Equal("ab\n", s.Text);
        Assert.Equal(1, s.Caret);
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Fact]
    public void DDollarLeavesTheCaretOnTheNewLastCharacter()
    {
        var s = new VimSession($"ab{ThumbsUp}cd\nnext\n", caret: 4);
        s.Press("d$");
        Assert.Equal($"ab{ThumbsUp}\nnext\n", s.Text);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void FFindsAnEmojiAndRepeats()
    {
        // thumbs up at 3 and 10
        var s = new VimSession($"go {ThumbsUp} now {ThumbsUp}!\n", caret: 0);
        s.Press($"f{ThumbsUp}");
        Assert.Equal(3, s.Caret);
        s.Press(";");
        Assert.Equal(10, s.Caret);
        s.Press(",");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void CountedFFindsTheSecondEmoji()
    {
        var s = new VimSession($"go {ThumbsUp} now {ThumbsUp}!\n", caret: 0);
        s.Press($"2f{ThumbsUp}");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void FFindsAFamilyAsOneCharacter()
    {
        var s = new VimSession($"a{ThumbsUp} {Family}b\n", caret: 0);
        s.Press($"f{Family}");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void FWithAPrecomposedLetterFindsTheDecomposedOne()
    {
        var s = new VimSession($"caf{Accented}!\n", caret: 0);
        s.Press("f\u00E9");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void TStopsOnTheCharacterBeforeAnEmoji()
    {
        var s = new VimSession($"go {ThumbsUp} now\n", caret: 0);
        s.Press($"t{ThumbsUp}");
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void TLandsOnAnEmojiBeforeTheTarget()
    {
        var s = new VimSession($"a{ThumbsUp}x\n", caret: 0);
        s.Press("tx");
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void CapitalFAndTFindAnEmojiBackward()
    {
        // thumbs up 3, space 5, w 8
        var find = new VimSession($"go {ThumbsUp} now\n", caret: 8);
        find.Press($"F{ThumbsUp}");
        Assert.Equal(3, find.Caret);

        var till = new VimSession($"go {ThumbsUp} now\n", caret: 8);
        till.Press($"T{ThumbsUp}");
        Assert.Equal(5, till.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void ReplaceModeOverwritesTheWholeCharacterAndBackspaceRestoresIt(string character)
    {
        var s = new VimSession($"a{character}b\n", caret: 1);
        s.Press("R");
        s.Press("x");
        Assert.Equal("axb\n", s.Text);
        Assert.Equal(2, s.Caret);
        s.Backspace();
        Assert.Equal($"a{character}b\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void ReplaceModeTypesACharacterAndBackspaceRestoresTheLetter(string character)
    {
        var s = new VimSession("abc\n", caret: 1);
        s.Press("R");
        s.Press(character);
        Assert.Equal($"a{character}c\n", s.Text);
        Assert.Equal(1 + character.Length, s.Caret);
        s.Backspace();
        Assert.Equal("abc\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void ReplaceModeBackspaceRemovesAnAppendedEmoji()
    {
        var s = new VimSession("ab\n", caret: 2);
        s.Press("R");
        s.Press(ThumbsUp);
        Assert.Equal($"ab{ThumbsUp}\n", s.Text);
        Assert.Equal(4, s.Caret);
        s.Backspace();
        Assert.Equal("ab\n", s.Text);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void EscapeFromReplaceModeStepsBackOverAnEmoji()
    {
        var s = new VimSession("abc\n", caret: 1);
        s.Press("R");
        s.Press(ThumbsUp);
        s.Escape();
        Assert.Equal($"a{ThumbsUp}c\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Theory]
    [InlineData(ThumbsUp)]
    [InlineData(Family)]
    [InlineData(Accented)]
    public void VSelectsTheWholeCharacter(string character)
    {
        var s = new VimSession($"a{character}b\n", caret: 1);
        s.Press("v");
        Assert.Equal((1, character.Length), s.Selection);
    }

    [Fact]
    public void VisualLExtendsOverAnEmojiAndDeletes()
    {
        var s = new VimSession($"a{ThumbsUp}b\n", caret: 0);
        s.Press("vl");
        Assert.Equal((0, 3), s.Selection);
        s.Press("l");
        Assert.Equal((0, 4), s.Selection);
        s.Press("d");
        Assert.Equal("\n", s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void VisualHExtendsBackOverAnEmoji()
    {
        var s = new VimSession($"a{ThumbsUp}b\n", caret: 3);
        s.Press("vh");
        Assert.Equal((1, 3), s.Selection);
        s.Press("h");
        Assert.Equal((0, 4), s.Selection);
    }

    [Fact]
    public void VisualDeleteOfAnEmoji()
    {
        var s = new VimSession($"a{Family}b\n", caret: 1);
        s.Press("vd");
        Assert.Equal("ab\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void VisualReplaceWritesOneCharacterPerCharacter()
    {
        var s = new VimSession($"a{ThumbsUp}b\n", caret: 0);
        s.Press("vllr-");
        Assert.Equal("---\n", s.Text);
    }

    [Fact]
    public void VisualSwapKeepsTheEmojiWhole()
    {
        var s = new VimSession($"a{ThumbsUp}b\n", caret: 0);
        s.Press("vlo");
        Assert.Equal((0, 3), s.Selection);
        s.Press("l");
        Assert.Equal((1, 2), s.Selection);
    }

    // The macOS adapter over the text view is VimTextBuffer over the editor model here.
    [Fact]
    public void AdapterCharacterRangeIsTheComposedSequence()
    {
        var s = new VimSession($"a{ThumbsUp}b");
        var buffer = s.Engine.Buffer;
        Assert.Equal(new VimRange(1, 2), buffer.CharacterRange(2));
        Assert.Equal(new VimRange(3, 1), buffer.CharacterRange(3));
        Assert.Equal(new VimRange(4, 0), buffer.CharacterRange(4));
        Assert.Equal(new VimRange(0, 0), buffer.CharacterRange(-1));
    }

    [Fact]
    public void AdapterKeepsTheSelectionOnWholeCharacters()
    {
        var s = new VimSession($"a{ThumbsUp}b");
        var buffer = s.Engine.Buffer;
        buffer.SetSelectedRange(new VimRange(2, 0));
        Assert.Equal((1, 0), s.Selection);
        buffer.SetSelectedRange(new VimRange(2, 1));
        Assert.Equal((1, 2), s.Selection);
        buffer.SetSelectedRange(new VimRange(0, 2));
        Assert.Equal((0, 3), s.Selection);
    }

    [Fact]
    public void EngineOverTheTextViewStepsAndDeletesWholeEmoji()
    {
        var s = new VimSession($"INSERT INTO notes VALUES ('ok {ThumbsUp}')", caret: 29);
        s.Press("l");
        Assert.Equal(30, s.Caret);
        s.Press("l");
        Assert.Equal(32, s.Caret);
        s.Press("h");
        s.Press("x");
        Assert.Equal("INSERT INTO notes VALUES ('ok ')", s.Text);
        Assert.Equal(30, s.Caret);
    }
}
