using TablePro.Core.Generation;

namespace TablePro.Core.Tests.Generation;

public sealed class RowGenerationEngineTests
{
    private static RowGenerationSettings Settings(RowGenerationTable table, ulong seed = 7, int rows = 100, params (string Column, RowGeneratorSettings Settings)[] overrides)
    {
        var settings = RowGenerationDefaults.ForTable(table, new DateOnly(2026, 1, 1), seed, rows);
        foreach (var (column, value) in overrides)
        {
            settings = settings.With(column, value);
        }

        return settings;
    }

    private static readonly RowGenerationTable People = new(
    [
        new RowGenerationColumn("id", "bigint", RowValueClass.Integer) { IsUnique = true, IsNullable = false },
        new RowGenerationColumn("email", "varchar(80)", RowValueClass.Text) { MaxLength = 80 },
        new RowGenerationColumn("name", "varchar(40)", RowValueClass.Text) { MaxLength = 40 },
        new RowGenerationColumn("created", "timestamp", RowValueClass.Timestamp),
        new RowGenerationColumn("price", "numeric(8,2)", RowValueClass.Decimal) { Precision = 8, Scale = 2 },
        new RowGenerationColumn("rowid", "integer", RowValueClass.Integer) { Ownership = ServerOwnership.Assigned },
    ]);

    [Fact]
    public void TheSameSeedGivesTheSameRowsAndAnotherSeedOthers()
    {
        var first = new RowGenerationEngine(People, Settings(People)).NextRows(20);
        var again = new RowGenerationEngine(People, Settings(People)).NextRows(20);
        var other = new RowGenerationEngine(People, Settings(People, seed: 8)).NextRows(20);

        Assert.Equal(first.Select(r => string.Join('|', r)), again.Select(r => string.Join('|', r)));
        Assert.NotEqual(first.Select(r => string.Join('|', r)), other.Select(r => string.Join('|', r)));
    }

    [Fact]
    public void AColumnTheServerFillsIsLeftOut()
    {
        var engine = new RowGenerationEngine(People, Settings(People));

        Assert.Equal(["id", "email", "name", "created", "price"], engine.ColumnNames);
        Assert.Equal(5, engine.NextRow().Length);
    }

    [Fact]
    public void ChangingOneColumnsGeneratorLeavesTheOthersAlone()
    {
        var before = new RowGenerationEngine(People, Settings(People)).NextRows(10);
        var after = new RowGenerationEngine(People, Settings(People, overrides: ("name", new RowGeneratorSettings(RowGeneratorKind.City)))).NextRows(10);

        Assert.Equal(before.Select(r => r[1]), after.Select(r => r[1]));
        Assert.NotEqual(before.Select(r => r[2]), after.Select(r => r[2]));
    }

    [Fact]
    public void ValuesAreTypedForTheColumn()
    {
        var row = new RowGenerationEngine(People, Settings(People)).NextRow();

        Assert.IsType<long>(row[0]);
        Assert.Contains("@example.", Assert.IsType<string>(row[1]), StringComparison.Ordinal);
        Assert.IsType<DateTime>(row[3]);
        var price = Assert.IsType<decimal>(row[4]);
        Assert.InRange(price, 1m, 1000m);
        Assert.Equal(2, price.Scale);
    }

    [Fact]
    public void AUniqueEmailColumnNeverRepeats()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("email", "text", RowValueClass.Text) { IsUnique = true }]);

        var rows = new RowGenerationEngine(table, Settings(table, rows: 3000)).NextRows(3000);

        Assert.Equal(3000, rows.Select(r => r[0]).Distinct().Count());
    }

    [Fact]
    public void AUniqueNameColumnNumbersTheRestInsideItsLength()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("city", "varchar(12)", RowValueClass.Text) { IsUnique = true, MaxLength = 12 }]);

        var rows = new RowGenerationEngine(table, Settings(table, rows: 200)).NextRows(200).Select(r => (string)r[0]!).ToArray();

        Assert.Equal(200, rows.Distinct().Count());
        Assert.All(rows, r => Assert.True(r.Length <= 12));
        Assert.Contains(rows, r => r.Contains(' ', StringComparison.Ordinal) && char.IsDigit(r[^1]));
    }

    [Fact]
    public void AUniqueRangeAsWideAsTheRowCountUsesEveryNumberOnce()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("n", "int", RowValueClass.Integer) { IsUnique = true }]);
        var settings = Settings(table, rows: 50, overrides: ("n", new RowGeneratorSettings(RowGeneratorKind.IntegerRange) { IntegerMinimum = 1, IntegerMaximum = 50 }));

        var values = new RowGenerationEngine(table, settings).NextRows(50).Select(r => (long)r[0]!).Order();

        Assert.Equal(Enumerable.Range(1, 50).Select(i => (long)i), values);
    }

    [Fact]
    public void AUniqueColumnWithNoValuesLeftNamesTheColumn()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("flag", "boolean", RowValueClass.Boolean) { IsUnique = true }]);
        var engine = new RowGenerationEngine(table, Settings(table, rows: 3));
        engine.NextRows(2);

        var error = Assert.Throws<RowGenerationException>(engine.NextRow);
        Assert.Contains("(flag)", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void AKeyOverTwoColumnsNeverRepeatsAndFillsEveryCombination()
    {
        var table = new RowGenerationTable(
        [
            new RowGenerationColumn("a", "int", RowValueClass.Integer),
            new RowGenerationColumn("b", "int", RowValueClass.Integer),
        ])
        { UniqueGroups = [["a", "b"]] };
        var range = new RowGeneratorSettings(RowGeneratorKind.IntegerRange) { IntegerMinimum = 1, IntegerMaximum = 5 };
        var settings = Settings(table, rows: 25, overrides: [("a", range), ("b", range)]);

        var pairs = new RowGenerationEngine(table, settings).NextRows(25).Select(r => (r[0], r[1])).ToArray();

        Assert.Equal(25, pairs.Distinct().Count());
    }

    [Fact]
    public void AKeyThatCountsNullsAsEqualNeverRepeatsANull()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("a", "int", RowValueClass.Integer), new RowGenerationColumn("b", "int", RowValueClass.Integer)]) { UniqueGroups = [["a", "b"]] };
        var settings = Settings(
            table,
            rows: 6,
            overrides: [("a", new RowGeneratorSettings(RowGeneratorKind.IntegerRange) { IntegerMinimum = 1, IntegerMaximum = 2, NullRatio = 0.5 }), ("b", new RowGeneratorSettings(RowGeneratorKind.IntegerRange) { IntegerMinimum = 1, IntegerMaximum = 2 })]);

        var pairs = new RowGenerationEngine(table, settings, nullsAreDistinct: false).NextRows(6).Select(r => (r[0], r[1])).ToArray();

        Assert.Equal(6, pairs.Distinct().Count());
    }

    [Fact]
    public void AUniquePatternWalksItsValues()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("code", "char(2)", RowValueClass.Text) { IsUnique = true, MaxLength = 2 }]);
        var settings = Settings(table, rows: 100, overrides: ("code", new RowGeneratorSettings(RowGeneratorKind.Pattern) { Pattern = "##" }));

        var codes = new RowGenerationEngine(table, settings).NextRows(100).Select(r => (string)r[0]!).ToArray();

        Assert.Equal(100, codes.Distinct().Count());
        Assert.All(codes, c => Assert.Matches("^[0-9]{2}$", c));
    }

    [Fact]
    public void ARangeAsWideAsBigintStillGivesNumbers()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("n", "bigint", RowValueClass.Integer)]);
        var settings = Settings(table, overrides: ("n", new RowGeneratorSettings(RowGeneratorKind.IntegerRange) { IntegerMinimum = long.MinValue, IntegerMaximum = long.MaxValue }));

        Assert.All(new RowGenerationEngine(table, settings).NextRows(10), r => Assert.IsType<long>(r[0]));
    }

    [Fact]
    public void ColumnsOfOneForeignKeyTakeTheSameReferencedRow()
    {
        var source = new ReferenceSource("fk", "lines", ["order_id", "line"], [[1L, 1L], [1L, 2L], [2L, 1L], [3L, 7L]]);
        var table = new RowGenerationTable(
        [
            new RowGenerationColumn("order_id", "int", RowValueClass.Integer) { Reference = new ReferenceSlot("fk", 0) },
            new RowGenerationColumn("line", "int", RowValueClass.Integer) { Reference = new ReferenceSlot("fk", 1) },
        ])
        { References = [source] };

        var rows = new RowGenerationEngine(table, Settings(table, rows: 50)).NextRows(50);

        Assert.All(rows, r => Assert.Contains(source.Tuples, t => Equals(t[0], r[0]) && Equals(t[1], r[1])));
    }

    [Fact]
    public void AUniqueForeignKeyColumnClaimsEachReferencedRowOnce()
    {
        var source = new ReferenceSource("fk", "users", ["user_id"], [[1L], [2L], [3L]]);
        var table = new RowGenerationTable([new RowGenerationColumn("user_id", "int", RowValueClass.Integer) { IsUnique = true, Reference = new ReferenceSlot("fk", 0) }]) { References = [source] };

        var values = new RowGenerationEngine(table, Settings(table, rows: 3)).NextRows(3).Select(r => (long)r[0]!).Order();

        Assert.Equal([1L, 2L, 3L], values);
    }

    [Fact]
    public void ANullRatioOfOneGivesNullOnlyWhereTheColumnAllowsIt()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("a", "text", RowValueClass.Text), new RowGenerationColumn("b", "text", RowValueClass.Text) { IsNullable = false }]);
        var all = new RowGeneratorSettings(RowGeneratorKind.City) { NullRatio = 1 };

        var rows = new RowGenerationEngine(table, Settings(table, overrides: [("a", all), ("b", all)])).NextRows(20);

        Assert.All(rows, r => Assert.Null(r[0]));
        Assert.All(rows, r => Assert.NotNull(r[1]));
    }

    [Fact]
    public void ASequenceCountsUpByItsStepAndTextNeverRunsPastItsLength()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("n", "int", RowValueClass.Integer), new RowGenerationColumn("t", "varchar(7)", RowValueClass.Text) { MaxLength = 7 }]);
        var settings = Settings(table, overrides: [("n", new RowGeneratorSettings(RowGeneratorKind.Sequence) { IntegerMinimum = 10, SequenceStep = 5 }), ("t", new RowGeneratorSettings(RowGeneratorKind.Text) { MinLength = 20, MaxLength = 60 })]);

        var rows = new RowGenerationEngine(table, settings).NextRows(4);

        Assert.Equal([10L, 15L, 20L, 25L], rows.Select(r => (long)r[0]!));
        Assert.All(rows, r => Assert.True(((string)r[1]!).Length <= 7));
    }

    [Fact]
    public void AUuidCarriesItsVersionAndVersionSevenSortsInRowOrder()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("id", "uuid", RowValueClass.Uuid), new RowGenerationColumn("key", "text", RowValueClass.Text)]);
        var settings = Settings(table, overrides: [("id", new RowGeneratorSettings(RowGeneratorKind.Uuid) { UuidVersion = UuidVersion.V7 }), ("key", new RowGeneratorSettings(RowGeneratorKind.Uuid))]);

        var rows = new RowGenerationEngine(table, settings).NextRows(5);

        var sevens = rows.Select(r => Assert.IsType<Guid>(r[0]).ToString("D")).ToArray();
        Assert.All(sevens, g => Assert.Equal('7', g[14]));
        Assert.Equal(sevens.Order(StringComparer.Ordinal), sevens);
        Assert.All(rows, r => Assert.Equal('4', Assert.IsType<string>(r[1])[14]));
    }

    [Fact]
    public void DatesTimesAndListsComeFromTheirDomains()
    {
        var table = new RowGenerationTable(
        [
            new RowGenerationColumn("d", "date", RowValueClass.Date),
            new RowGenerationColumn("t", "time", RowValueClass.Time),
            new RowGenerationColumn("s", "text", RowValueClass.Text),
        ]);
        var settings = Settings(
            table,
            overrides:
            [
                ("d", new RowGeneratorSettings(RowGeneratorKind.Date) { DateStart = new DateOnly(2024, 2, 28), DateEnd = new DateOnly(2024, 3, 1) }),
                ("t", new RowGeneratorSettings(RowGeneratorKind.Time)),
                ("s", new RowGeneratorSettings(RowGeneratorKind.List) { Values = ["a", "", "b", "a"] }),
            ]);

        var rows = new RowGenerationEngine(table, settings).NextRows(40);

        Assert.All(rows, r => Assert.InRange(Assert.IsType<DateOnly>(r[0]), new DateOnly(2024, 2, 28), new DateOnly(2024, 3, 1)));
        Assert.All(rows, r => Assert.IsType<TimeOnly>(r[1]));
        Assert.Equal(["a", "b"], rows.Select(r => (string)r[2]!).Distinct().Order());
    }

    [Fact]
    public void APatternFillsDigitsAndLettersAndKeepsEscapes()
    {
        Assert.Equal("AA-01", RowGenerationPattern.ValueAt(1, "??-##"));
        Assert.Equal("AB-01", RowGenerationPattern.ValueAt(101, "??-##"));
        Assert.Equal("#A9", RowGenerationPattern.ValueAt(9, "\\#?#"));
        Assert.Equal(26L * 26 * 100, RowGenerationPattern.Combinations("??-##"));
        Assert.Equal(26L, RowGenerationPattern.Combinations("??-##", length: 1));
    }

    [Fact]
    public void TheSeededStreamIsSplitMix64()
    {
        var random = new SeededRandom(0);

        Assert.Equal(0xE220A8397B1DCDAFUL, random.Next());
        for (var i = 0; i < 1000; i++)
        {
            Assert.InRange(random.Integer(-3, 3), -3, 3);
        }

        Assert.False(random.Chance(0));
        Assert.True(random.Chance(1));
    }

    [Fact]
    public void ADecimalIsExactFromItsSteps()
    {
        Assert.Equal("12.50", RowValueText.Decimal(1250, 2).ToString(System.Globalization.CultureInfo.InvariantCulture));
        Assert.Equal("-0.05", RowValueText.Decimal(-5, 2).ToString(System.Globalization.CultureInfo.InvariantCulture));
        Assert.Equal("2024-03-01 13:05:00", RowValueText.Invariant(new DateTime(2024, 3, 1, 13, 5, 0)));
    }
}
