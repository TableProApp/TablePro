namespace TablePro.Core.Generation;

/// <summary>
/// SplitMix64 with its own bounded draws. <see cref="Random"/> may change its algorithm between .NET releases, and a
/// seed has to give the same rows in every version of the app; the stream matches the macOS generator's bit for bit.
/// </summary>
public struct SeededRandom
{
    private ulong _state;

    public SeededRandom(ulong seed) => _state = seed;

    /// <summary>Each column draws from its own stream, so changing one column's generator leaves every other column's values.</summary>
    public SeededRandom(ulong seed, string stream) => _state = seed ^ Fnv1a(stream);

    public ulong Next()
    {
        _state += 0x9E37_79B9_7F4A_7C15;
        var mixed = _state;
        mixed = (mixed ^ (mixed >> 30)) * 0xBF58_476D_1CE4_E5B9;
        mixed = (mixed ^ (mixed >> 27)) * 0x94D0_49BB_1331_11EB;
        return mixed ^ (mixed >> 31);
    }

    /// <summary>A double in [0, 1).</summary>
    public double Unit() => (Next() >> 11) * (1.0 / (1UL << 53));

    public int Index(int count) => count <= 1 ? 0 : (int)Bounded((ulong)count);

    /// <summary>A long in [<paramref name="minimum"/>, <paramref name="maximum"/>], both included.</summary>
    public long Integer(long minimum, long maximum)
    {
        var span = unchecked((ulong)(maximum - minimum));
        return span == ulong.MaxValue ? unchecked((long)Next()) : unchecked(minimum + (long)Bounded(span + 1));
    }

    public bool Chance(double ratio) => ratio > 0 && (ratio >= 1 || Unit() < ratio);

    // Lemire's multiply-shift with rejection, so every value in the range is equally likely.
    private ulong Bounded(ulong upper)
    {
        var high = Math.BigMul(Next(), upper, out var low);
        if (low < upper)
        {
            var threshold = unchecked(0 - upper) % upper;
            while (low < threshold)
            {
                high = Math.BigMul(Next(), upper, out low);
            }
        }

        return high;
    }

    internal static ulong Fnv1a(string text)
    {
        var hash = 0xCBF2_9CE4_8422_2325UL;
        Span<byte> buffer = stackalloc byte[4];
        foreach (var rune in text.EnumerateRunes())
        {
            var length = rune.EncodeToUtf8(buffer);
            for (var i = 0; i < length; i++)
            {
                hash ^= buffer[i];
                hash *= 0x0000_0100_0000_01B3;
            }
        }

        return hash;
    }
}
