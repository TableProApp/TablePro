using System.Globalization;
using System.Text;
using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.DataGrid.Gate;

// The spike's 20 columns (wingates2 griddata-core/src/synth.rs) through the real core, shown 10 times as 200 columns.
internal sealed class BenchData : IAsyncDisposable
{
    public const int PoolSize = 4096;

    private readonly string _directory;
    private readonly TableProCore _core;
    private readonly DatabaseSession _session;
    private readonly QueryEditor _editor;

    private BenchData(string directory, TableProCore core, DatabaseSession session, QueryEditor editor)
    {
        _directory = directory;
        _core = core;
        _session = session;
        _editor = editor;
    }

    public static async Task<BenchData> CreateAsync()
    {
        var directory = Directory.CreateTempSubdirectory("tablepro-grid-gate-").FullName;
        var core = TableProCore.Create(new HostConfiguration("grid-gate"), new NoSecrets());
        var session = await core.OpenFileAsync(new FileOpenOptions(Path.Combine(directory, "gate.sqlite"), Create: true));
        var editor = await session.OpenEditorAsync();
        var bench = new BenchData(directory, core, session, editor);
        await bench.ExecuteAsync("CREATE TABLE pool (k INTEGER PRIMARY KEY, amount TEXT, name TEXT, uuid TEXT, description TEXT, " +
            "note TEXT, payload TEXT, tags TEXT, blob BLOB)");
        foreach (var batch in PoolInserts())
        {
            await bench.ExecuteAsync(batch);
        }
        return bench;
    }

    public async Task<(QueryRun Run, ResultSet Set, ResultSetData Data)> QueryAsync(string sql, long rowLimit)
    {
        var run = _editor.Run(sql, new QueryOptions(RowLimit: rowLimit));
        var outcome = await run.Completion;
        if (outcome is not QueryOutcome.Completed)
        {
            throw new InvalidOperationException($"query ended {outcome}");
        }
        var set = run.GetResultSet(0) ?? throw new InvalidOperationException("no result set");
        return (run, set, new ResultSetData(set, set.GetColumns()));
    }

    public static string WideQuery(int rows) => string.Create(CultureInfo.InvariantCulture, $"""
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < {rows})
        SELECT
          x AS id,
          CASE WHEN (x * 37) % 10 = 0 THEN NULL ELSE (x * 7919) % 10000 END AS qty,
          CASE WHEN (x * 41) % 20 = 0 THEN NULL ELSE ((x * 2654435761) % 4294967291) * 1000003 END AS big,
          CASE WHEN (x * 43) % 10 = 0 THEN NULL ELSE printf('%.2f', ((x * 7907) % 10000000000) / 100.0 - 1000000) END AS price,
          p.amount,
          CASE WHEN (x * 47) % 10 = 0 THEN NULL ELSE ((x * 104729) % 1000000) / 1000.0 - 500 END AS ratio,
          CASE WHEN (x * 53) % 20 = 0 THEN NULL
            ELSE strftime('%Y-%m-%d %H:%M:%f', 2440587.5 + ((x * 7919) % 2207520000) / 86400.0) END AS created_at,
          CASE WHEN (x * 59) % 5 = 0 THEN NULL
            ELSE strftime('%Y-%m-%d %H:%M:%f', 2440587.5 + ((x * 6113) % 2207520000) / 86400.0) || '+00:00' END AS updated_at,
          CASE WHEN (x * 61) % 10 = 0 THEN NULL ELSE date(2440587.5 + ((x * 4021) % 36500) - 18250) END AS birth_date,
          CASE WHEN (x * 67) % 20 = 0 THEN NULL ELSE (x * 31) % 2 END AS active,
          p.name,
          'user' || x || '.' || ((x * 13) % 1000) || '@example.com' AS email,
          p.uuid,
          p.description,
          p.note,
          p.payload,
          p.tags,
          CASE WHEN (x * 71) % 5 = 0 THEN NULL ELSE p.blob END AS blob,
          NULL AS empty,
          CASE (x * 17) % 4 WHEN 0 THEN 'active' WHEN 1 THEN 'pending' WHEN 2 THEN 'disabled' ELSE 'archived' END AS status
        FROM c JOIN pool p ON p.k = (x * 2654435761) % {PoolSize}
        """);

    // Values the drawing has to get right: right-to-left text, color emoji, NULL, a value past the cap, two lines.
    public const string ContentQuery =
        "SELECT 'مرحبا بالعالم' AS rtl, 'שלום עולם' AS hebrew, '😀🚀 emoji' AS emoji, NULL AS nothing, " +
        "printf('%.1000c', 'w') AS long_value, 'line one' || char(10) || 'line two' AS two_lines, " +
        "'Tiếng Việt 你好 日本語' AS mixed";

    public async ValueTask DisposeAsync()
    {
        await _editor.DisposeAsync();
        await _session.DisposeAsync();
        _core.Dispose();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private async Task ExecuteAsync(string sql)
    {
        using var run = _editor.Run(sql);
        var outcome = await run.Completion;
        if (outcome is not QueryOutcome.Completed)
        {
            throw new InvalidOperationException($"{outcome}: {sql[..Math.Min(sql.Length, 200)]}");
        }
    }

    private static IEnumerable<string> PoolInserts()
    {
        var sql = new StringBuilder();
        for (var k = 0; k < PoolSize; k++)
        {
            if (sql.Length == 0)
            {
                sql.Append("INSERT INTO pool VALUES ");
            }
            else
            {
                sql.Append(',');
            }
            var rng = new Rng(0x7A11_0000UL + (ulong)k);
            sql.Append('(').Append(k.ToString(CultureInfo.InvariantCulture)).Append(',');
            Literal(sql, Synth.Amount(ref rng));
            sql.Append(',');
            Literal(sql, rng.Below(1000) < 50 ? null : Synth.Name(ref rng));
            sql.Append(',');
            Literal(sql, Synth.Uuid(ref rng));
            sql.Append(',');
            Literal(sql, rng.Below(1000) < 100 ? null : Synth.Description(ref rng));
            sql.Append(',');
            Literal(sql, rng.Below(1000) < 300 ? null : Synth.Note(ref rng));
            sql.Append(',');
            Literal(sql, rng.Below(1000) < 100 ? null : Synth.Payload(ref rng, k));
            sql.Append(',');
            Literal(sql, Synth.Tags(ref rng));
            sql.Append(",X'").Append(Convert.ToHexString(Synth.Blob(ref rng))).Append("')");
            if (sql.Length > 400_000)
            {
                yield return sql.ToString();
                sql.Clear();
            }
        }
        if (sql.Length > 0)
        {
            yield return sql.ToString();
        }
    }

    private static void Literal(StringBuilder sql, string? value)
    {
        if (value is null)
        {
            sql.Append("NULL");
            return;
        }
        sql.Append('\'').Append(value.Replace("'", "''", StringComparison.Ordinal)).Append('\'');
    }

    private sealed class NoSecrets : ISecretStore
    {
        public string? Load(Guid connectionId, SecretKind kind) => null;

        public void Store(Guid connectionId, SecretKind kind, string secret, string label)
        {
        }

        public void Relabel(Guid connectionId, SecretKind kind, string label)
        {
        }

        public void Delete(Guid connectionId, SecretKind kind)
        {
        }

        public void DeleteConnection(Guid connectionId)
        {
        }

        public string? LoadItem(SecretItem item) => null;

        public void StoreItem(SecretItem item, string secret)
        {
        }

        public void DeleteItem(SecretItem item)
        {
        }
    }
}

// The spike's generator for the text columns.
internal struct Rng(ulong state)
{
    private ulong _state = state;

    public ulong Next()
    {
        var z = _state + 0x9E37_79B9_7F4A_7C15UL;
        z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBUL;
        _state = z ^ (z >> 31);
        return _state;
    }

    public ulong Below(ulong n) => Next() % n;
}

internal static class Synth
{
    private static readonly string[] AsciiWords =
    [
        "lorem", "ipsum", "dolor", "sit", "amet", "database", "query", "index", "table", "column", "select", "order",
        "customer", "invoice", "shipping", "pending", "value", "native", "window", "stream",
    ];

    private static readonly string[] WideWords =
    [
        "Nguyễn", "đường", "phố", "Hà", "Nội", "日本語", "数据库", "查询", "Ünïcödé", "café", "naïve", "Привет", "🚀", "😀", "العربية",
    ];

    public static string Amount(ref Rng rng)
    {
        var digits = rng.Below(100) == 0 ? 30 + (int)rng.Below(8) : 3 + (int)rng.Below(16);
        var text = new StringBuilder();
        if (rng.Below(2) == 0)
        {
            text.Append('-');
        }
        for (var i = 0; i < digits; i++)
        {
            text.Append((char)('0' + (i == 0 ? 1 + (int)rng.Below(9) : (int)rng.Below(10))));
        }
        text.Insert(text.Length - 2, '.');
        return text.ToString();
    }

    public static string Name(ref Rng rng)
    {
        var length = 6 + (int)rng.Below(14);
        var text = new char[length];
        for (var i = 0; i < length; i++)
        {
            text[i] = (char)('a' + rng.Below(26));
        }
        return new string(text);
    }

    public static string Uuid(ref Rng rng)
    {
        var a = rng.Next();
        var b = rng.Next();
        return string.Create(CultureInfo.InvariantCulture,
            $"{a >> 32:x8}-{(a >> 16) & 0xffff:x4}-{a & 0xffff:x4}-{b >> 48:x4}-{b & 0xffff_ffff_ffff:x12}");
    }

    // One in twenty is long enough to pass the display cap.
    public static string Description(ref Rng rng)
    {
        var target = rng.Below(20) == 0 ? 1200 + (int)rng.Below(2800) : 40 + (int)rng.Below(160);
        return Words(ref rng, target, wide: rng.Below(4) == 0, newlines: true);
    }

    public static string Note(ref Rng rng) => Words(ref rng, 10 + (int)rng.Below(50), wide: true, newlines: false);

    public static string Payload(ref Rng rng, int row)
    {
        var pretty = rng.Below(10) == 0;
        var nl = pretty ? "\n  " : "";
        var text = new StringBuilder();
        text.Append(CultureInfo.InvariantCulture, $"{{{nl}\"id\": {row},{nl}\"items\": [");
        var items = 1 + rng.Below(6);
        for (var i = 0UL; i < items; i++)
        {
            if (i > 0)
            {
                text.Append(',');
            }
            text.Append(CultureInfo.InvariantCulture,
                $"{{\"sku\": \"SKU-{rng.Below(1_000_000):D6}\", \"qty\": {rng.Below(50)}, \"price\": \"{rng.Below(1000)}.{rng.Below(100):D2}\"}}");
        }
        text.Append(CultureInfo.InvariantCulture, $"],{nl}\"meta\": {{\"source\": \"import\", \"note\": \"");
        text.Append(Words(ref rng, 20 + (int)rng.Below(40), wide: true, newlines: false));
        text.Append("\"}").Append(pretty ? "\n" : "").Append('}');
        return text.ToString();
    }

    public static string Tags(ref Rng rng)
    {
        var text = new StringBuilder("[");
        var count = 1 + rng.Below(4);
        for (var i = 0UL; i < count; i++)
        {
            if (i > 0)
            {
                text.Append(", ");
            }
            text.Append('"').Append(AsciiWords[rng.Below(20)]).Append('"');
        }
        return text.Append(']').ToString();
    }

    public static byte[] Blob(ref Rng rng)
    {
        var bytes = new byte[16 + rng.Below(256)];
        for (var i = 0; i < bytes.Length; i++)
        {
            bytes[i] = (byte)rng.Next();
        }
        return bytes;
    }

    private static string Words(ref Rng rng, int target, bool wide, bool newlines)
    {
        var text = new StringBuilder();
        while (Encoding.UTF8.GetByteCount(text.ToString()) < target)
        {
            if (text.Length > 0)
            {
                text.Append(newlines && rng.Below(40) == 0 ? '\n' : ' ');
            }
            text.Append(wide && rng.Below(4) == 0 ? WideWords[rng.Below((ulong)WideWords.Length)] : AsciiWords[rng.Below(20)]);
        }
        return text.ToString();
    }
}

// 200 grid columns over the 20 of the result set, round r of column c named c_r, as the spike's wide fetch did.
internal sealed class WideData(ResultSetData inner, int rounds) : IGridData
{
    public int RowCount => inner.RowCount;

    public int ColumnCount => inner.ColumnCount * rounds;

    public ResultSetData Inner => inner;

    public string GetColumnName(int column)
    {
        var round = column / inner.ColumnCount;
        var name = inner.GetColumnName(column % inner.ColumnCount);
        return round == 0 ? name : string.Create(CultureInfo.InvariantCulture, $"{name}_{round}");
    }

    public IGridReader OpenReader() => new Reader(inner.OpenReader(), inner.ColumnCount, ColumnCount);

    private sealed class Reader(IGridReader inner, int physical, int total) : IGridReader
    {
        private readonly List<CellBlock> _runs = [];

        // Grid columns in runs of the set's columns, each read into a block of its own, then copied in order.
        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
            columnCount = Math.Max(0, Math.Min(columnCount, total - firstColumn));
            var runs = 0;
            var rows = rowCount;
            for (var column = firstColumn; column < firstColumn + columnCount;)
            {
                var start = column % physical;
                var length = Math.Min(firstColumn + columnCount - column, physical - start);
                if (runs == _runs.Count)
                {
                    _runs.Add(new CellBlock());
                }
                inner.Read(firstRow, rowCount, start, length, maxCharacters, _runs[runs]);
                rows = Math.Min(rows, _runs[runs].RowCount);
                runs++;
                column += length;
            }
            block.Reset(firstRow, rows, firstColumn, columnCount, maxCharacters);
            for (var run = 0; run < runs; run++)
            {
                var source = _runs[run];
                for (var column = source.FirstColumn; column < source.FirstColumn + source.ColumnCount; column++)
                {
                    for (var row = firstRow; row < firstRow + rows; row++)
                    {
                        block.Add(source.Get(row, column));
                    }
                }
            }
        }

        public string? ReadWhole(int row, int column) => inner.ReadWhole(row, column % physical);

        public void Dispose() => inner.Dispose();
    }
}
