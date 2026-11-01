using System.Diagnostics;
using System.Text;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class LexerThroughputTests
{
    private const int TargetLength = 5 * 1024 * 1024;

    [Fact]
    public void LexesFiveMegabytesInUnderASecond()
    {
        var script = BuildScript();
        var features = PostgreSqlDialect.Instance.LexerFeatures;

        // The first pass pays for JIT, which is not what this guards.
        CountTokens(script[..4096], features);

        var stopwatch = Stopwatch.StartNew();
        var count = CountTokens(script, features);
        stopwatch.Stop();

        Assert.True(count > 500_000, $"Only {count} tokens were read.");
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(1), $"Lexing {script.Length:N0} characters took {stopwatch.ElapsedMilliseconds} ms.");
    }

    private static int CountTokens(string text, SqlLexerFeatures features)
    {
        var lexer = new SqlLexer(text, features);
        var count = 0;
        var covered = 0;
        while (lexer.TryRead(out var token))
        {
            count++;
            covered += token.Length;
        }

        Assert.Equal(text.Length, covered);
        return count;
    }

    private static string BuildScript()
    {
        const string chunk = """
            -- order report
            SELECT o.id, o."Total", c.name AS customer, 'it''s ; fine' AS note, 1.5e3 * o.qty / 2
            FROM public.orders o /* join /* nested */ customers */
            JOIN customers c ON c.id = o.customer_id
            WHERE o.created_at >= $1 AND o.status <> 'void' AND o.tags::text ILIKE :pattern;
            CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 0x1F; END; $$ LANGUAGE plpgsql;

            """;

        var sb = new StringBuilder(TargetLength + chunk.Length);
        while (sb.Length < TargetLength)
        {
            sb.Append(chunk);
        }

        return sb.ToString();
    }
}
