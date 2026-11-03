using System.Text;

namespace TablePro.Editor.Model.Tests;

public sealed class RopeTests
{
    [Fact]
    public void RandomEditsMatchAStringBuilder()
    {
        var random = new Random(1234);
        var rope = new Rope();
        var expected = new StringBuilder();
        for (var step = 0; step < 4000; step++)
        {
            if (expected.Length > 0 && random.Next(3) == 0)
            {
                var offset = random.Next(expected.Length);
                var length = Math.Min(expected.Length - offset, random.Next(1, step % 50 == 0 ? 6000 : 40));
                rope.Remove(offset, length);
                expected.Remove(offset, length);
            }
            else
            {
                var offset = random.Next(expected.Length + 1);
                var text = RandomText(random, step % 97 == 0 ? 5000 : random.Next(1, 30));
                rope.Insert(offset, text);
                expected.Insert(offset, text);
            }
            if (step % 200 == 0)
            {
                rope.CheckInvariants();
                Assert.Equal(expected.ToString(), rope.GetText(0, rope.Length));
            }
        }
        rope.CheckInvariants();
        var final = expected.ToString();
        Assert.Equal(final, rope.GetText(0, rope.Length));
        AssertLinesMatch(rope, final);
    }

    [Fact]
    public void LineLookupsAgreeWithTheText()
    {
        var text = string.Join('\n', Enumerable.Range(0, 3000).Select(i => new string('x', i % 70)));
        var rope = new Rope();
        rope.SetText(text);
        AssertLinesMatch(rope, text);
    }

    [Fact]
    public void FiveMegabytesStaysShallow()
    {
        var rope = new Rope();
        rope.SetText(new string('a', 5_300_000));
        for (var i = 0; i < 2000; i++)
        {
            rope.Insert(2_650_000 + i, "b");
        }
        rope.CheckInvariants();
        Assert.True(rope.Height <= 16, $"height {rope.Height}");
        Assert.Equal('b', rope.CharAt(2_650_000));
    }

    [Fact]
    public void ChunksCoverTheAskedRange()
    {
        var rope = new Rope();
        var text = RandomText(new Random(5), 20_000);
        rope.SetText(text);
        var joined = string.Concat(rope.Chunks(1234, 15_000).Select(c => c.ToString()));
        Assert.Equal(text.Substring(1234, 15_000), joined);
    }

    private static void AssertLinesMatch(Rope rope, string text)
    {
        var starts = new List<int> { 0 };
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '\n')
            {
                starts.Add(i + 1);
            }
        }
        Assert.Equal(starts.Count - 1, rope.LineBreaks);
        for (var line = 0; line < starts.Count; line += Math.Max(1, starts.Count / 300))
        {
            Assert.Equal(starts[line], rope.LineStart(line));
            Assert.Equal(line, rope.LineOf(starts[line]));
        }
        for (var offset = 0; offset <= text.Length; offset += Math.Max(1, text.Length / 500))
        {
            var expected = starts.FindLastIndex(s => s <= offset);
            Assert.Equal(expected, rope.LineOf(offset));
        }
    }

    private static string RandomText(Random random, int length)
    {
        const string alphabet = "abcdef ghij\nklm\tNOP;()'tiếng việt";
        var chars = new char[length];
        for (var i = 0; i < length; i++)
        {
            chars[i] = alphabet[random.Next(alphabet.Length)];
        }
        return new string(chars);
    }
}
