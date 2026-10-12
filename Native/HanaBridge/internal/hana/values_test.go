package hana

import (
	"math"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/SAP/go-hdb/driver/unicode/cesu8"
)

type wireDecimal struct {
	mantissa *big.Int
	exponent int
}

func (d wireDecimal) Decompose(buffer []byte) (form byte, negative bool, coefficient []byte, exponent int32) {
	negative = d.mantissa.Sign() < 0
	exponent = int32(d.exponent)
	magnitude := d.mantissa
	if negative {
		magnitude = new(big.Int).Abs(d.mantissa)
	}
	size := (magnitude.BitLen() + 7) / 8
	if cap(buffer) >= size {
		coefficient = magnitude.FillBytes(buffer[:size])
	} else {
		coefficient = magnitude.Bytes()
	}
	return form, negative, coefficient, exponent
}

type specialDecimal struct {
	form     byte
	negative bool
}

func (d specialDecimal) Decompose([]byte) (byte, bool, []byte, int32) {
	return d.form, d.negative, nil, 0
}

func column(databaseTypeName string) columnInfo {
	return columnInfo{name: "C", databaseTypeName: databaseTypeName}
}

func textColumn(databaseTypeName string) columnInfo {
	return columnInfo{name: "C", databaseTypeName: databaseTypeName, textual: true}
}

func assertText(t *testing.T, got cell, want string) {
	t.Helper()
	if got.kind != cellText || got.text != want {
		t.Fatalf("cell = %+v; want text %q", got, want)
	}
}

func TestIntegersAndBooleansFormatAsPlainText(t *testing.T) {
	assertText(t, formatValue(int64(-9223372036854775808), column("BIGINT")), "-9223372036854775808")
	assertText(t, formatValue(int64(255), column("TINYINT")), "255")
	assertText(t, formatValue(true, column("BOOLEAN")), "TRUE")
	assertText(t, formatValue(false, column("BOOLEAN")), "FALSE")
	if cell := formatValue(nil, column("INTEGER")); cell.kind != cellNull {
		t.Fatalf("nil formatted as %+v", cell)
	}
}

func TestDoubleUsesShortestDigitsAndPlainNotationInsideTheJavaScriptRange(t *testing.T) {
	cases := map[float64]string{
		1000000:            "1000000",
		2500000.5:          "2500000.5",
		123456789012:       "123456789012",
		0.00001:            "0.00001",
		1e-7:               "0.0000001",
		0.1:                "0.1",
		-0.5:               "-0.5",
		0:                  "0",
		1e21:               "1e+21",
		1.5e-8:             "1.5e-8",
		-2.25e300:          "-2.25e+300",
		math.MaxFloat64:    "1.7976931348623157e+308",
		999999999999999999: "1000000000000000000",
		math.Inf(1):        "Infinity",
		math.Inf(-1):       "-Infinity",
	}
	for value, want := range cases {
		assertText(t, formatValue(value, column("DOUBLE")), want)
	}
	assertText(t, formatValue(math.NaN(), column("DOUBLE")), "NaN")
}

func TestRealUsesThirtyTwoBitDigitsOfTheWidenedValue(t *testing.T) {
	cases := map[float32]string{
		1.1:      "1.1",
		16777216: "16777216",
		3.4e38:   "3.4e+38",
		1e-8:     "1e-8",
		-0.3:     "-0.3",
	}
	for value, want := range cases {
		widened := float64(value)
		assertText(t, formatValue(widened, column("REAL")), want)
	}
	if got := formatValue(float64(float32(1.1)), column("DOUBLE")); got.text == "1.1" {
		t.Fatal("DOUBLE formatting lost the widened float32 digits it must keep")
	}
}

func TestDecimalsFormatExactlyThroughDecompose(t *testing.T) {
	huge, _ := new(big.Int).SetString("9999999999999999999999999999999999", 10)
	fixed38, _ := new(big.Int).SetString("99999999999999999999999999999999999999", 10)
	cases := []struct {
		value wireDecimal
		want  string
	}{
		{wireDecimal{big.NewInt(12345), -2}, "123.45"},
		{wireDecimal{big.NewInt(-1), -3}, "-0.001"},
		{wireDecimal{big.NewInt(1), 30}, "1000000000000000000000000000000"},
		{wireDecimal{big.NewInt(12345), 3}, "12345000"},
		{wireDecimal{big.NewInt(12345000), 0}, "12345000"},
		{wireDecimal{big.NewInt(0), -2}, "0.00"},
		{wireDecimal{big.NewInt(0), 0}, "0"},
		{wireDecimal{big.NewInt(-5), -2}, "-0.05"},
		{wireDecimal{big.NewInt(1500), -3}, "1.500"},
		{wireDecimal{big.NewInt(-42), 0}, "-42"},
		{wireDecimal{fixed38, -38}, "0." + strings.Repeat("9", 38)},
		{wireDecimal{big.NewInt(7), 64}, "7" + strings.Repeat("0", 64)},
		{wireDecimal{big.NewInt(7), -64}, "0." + strings.Repeat("0", 63) + "7"},
		{wireDecimal{big.NewInt(7), 65}, "7E+65"},
		{wireDecimal{big.NewInt(-7), -65}, "-7E-65"},
		{wireDecimal{huge, 6000}, strings.Repeat("9", 34) + "E+6000"},
		{wireDecimal{big.NewInt(5), -6176}, "5E-6176"},
	}
	for _, testCase := range cases {
		assertText(t, formatValue(testCase.value, column("DECIMAL")), testCase.want)
	}
	assertText(t, formatValue(specialDecimal{form: 1}, column("DECIMAL")), "Infinity")
	assertText(t, formatValue(specialDecimal{form: 1, negative: true}, column("DECIMAL")), "-Infinity")
	assertText(t, formatValue(specialDecimal{form: 2}, column("DECIMAL")), "NaN")
}

func TestTemporalValuesFormatAsHanaLiteralsInUTC(t *testing.T) {
	leapDay := time.Date(2024, time.February, 29, 0, 0, 0, 0, time.UTC)
	instant := time.Date(2024, time.February, 29, 13, 45, 7, 123456700, time.UTC)
	secondtime := hanaEpoch.Add(13*time.Hour + 45*time.Minute + 7*time.Second)
	assertText(t, formatValue(leapDay, column("DAYDATE")), "2024-02-29")
	assertText(t, formatValue(leapDay, column("DATE")), "2024-02-29")
	assertText(t, formatValue(secondtime, column("SECONDTIME")), "13:45:07")
	assertText(t, formatValue(time.Date(1, 1, 1, 23, 59, 59, 0, time.UTC), column("TIME")), "23:59:59")
	assertText(t, formatValue(instant.Truncate(time.Second), column("SECONDDATE")), "2024-02-29 13:45:07")
	assertText(t, formatValue(instant, column("LONGDATE")), "2024-02-29 13:45:07.1234567")
	assertText(t, formatValue(instant.Truncate(time.Millisecond), column("TIMESTAMP")), "2024-02-29 13:45:07.1230000")
	assertText(t, formatValue(time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC), column("LONGDATE")), "0001-01-01 00:00:00.0000000")
	assertText(t, formatValue(time.Date(9999, 12, 31, 23, 59, 59, 999999900, time.UTC), column("LONGDATE")), "9999-12-31 23:59:59.9999999")

	shifted := time.Date(2024, time.February, 29, 14, 45, 7, 0, time.FixedZone("CET", 3600))
	assertText(t, formatValue(shifted, column("SECONDDATE")), "2024-02-29 13:45:07")
}

func TestEmptyDatesUseHanaSpellings(t *testing.T) {
	assertText(t, formatValue(emptyDateInstant, column("DAYDATE")), "0000-00-00")
	assertText(t, formatValue(emptySecondInstant, column("SECONDDATE")), "0000-00-00 00:00:00")
	assertText(t, formatValue(emptyLongdateInstant, column("LONGDATE")), "0000-00-00 00:00:00.0000000")
	assertText(t, formatValue(emptySecondInstant, column("SECONDTIME")), "00:00:00")
	if emptyDateInstant.Format(timestampLayout) != "0000-12-31 00:00:00.0000000" ||
		emptySecondInstant.Format(timestampLayout) != "0000-12-31 23:59:59.0000000" ||
		emptyLongdateInstant.Format(timestampLayout) != "0000-12-31 23:59:59.9999999" {
		t.Fatalf("empty instants moved: %v %v %v", emptyDateInstant, emptySecondInstant, emptyLongdateInstant)
	}
}

func TestTextColumnsDecodeUTF8AndCESU8(t *testing.T) {
	assertText(t, formatValue([]byte("Grüße"), textColumn("NVARCHAR")), "Grüße")

	emoji := '😀'
	encoded := make([]byte, cesu8.RuneLen(emoji))
	cesu8.EncodeRune(encoded, emoji)
	if len(encoded) != 6 {
		t.Fatalf("go-hdb encoded %q in %d bytes; want a 6-byte surrogate pair", emoji, len(encoded))
	}
	raw := append([]byte("a"), encoded...)
	assertText(t, formatValue(raw, textColumn("VARCHAR")), "a😀")

	loneSurrogate := []byte{'a', 0xED, 0xA0, 0x80, 'b'}
	assertText(t, formatValue(loneSurrogate, textColumn("VARCHAR")), "a\uFFFDb")
	assertText(t, formatValue([]byte{'x', 0xFF, 'y'}, textColumn("CHAR")), "x\uFFFDy")
	assertText(t, formatValue([]byte("plain"), column("CLOB")), "plain")
	assertText(t, formatValue("0101000000000000000000F03F", column("STPOINT")), "0101000000000000000000F03F")
}

func TestBinaryColumnsStayBinary(t *testing.T) {
	data := []byte{0, 1, 0xFF}
	for _, typeName := range []string{"VARBINARY", "BINARY", "BSTRING", "BLOB"} {
		got := formatValue(data, column(typeName))
		if got.kind != cellBytes || string(got.bytes) != string(data) {
			t.Fatalf("%s formatted as %+v; want the raw bytes", typeName, got)
		}
	}
}

func TestColumnTypeNamesAreReportedAsSQLNames(t *testing.T) {
	cases := []struct {
		column         columnInfo
		reported       string
		classification string
	}{
		{column("DAYDATE"), "DATE", ""},
		{column("SECONDTIME"), "TIME", ""},
		{column("LONGDATE"), "TIMESTAMP", ""},
		{column("SECONDDATE"), "SECONDDATE", "TIMESTAMP"},
		{columnInfo{databaseTypeName: "FIXED8", precision: 18, scale: 2, hasDecimalSize: true}, "DECIMAL(18,2)", ""},
		{columnInfo{databaseTypeName: "FIXED12", precision: 28, scale: 0, hasDecimalSize: true}, "DECIMAL(28,0)", ""},
		{columnInfo{databaseTypeName: "FIXED16", precision: 38, scale: 10, hasDecimalSize: true}, "DECIMAL(38,10)", ""},
		{column("FIXED16"), "DECIMAL", ""},
		{columnInfo{databaseTypeName: "DECIMAL", precision: 34, scale: 32767, hasDecimalSize: true}, "DECIMAL", ""},
		{column("SMALLDECIMAL"), "SMALLDECIMAL", "DECIMAL"},
		{column("STGEOMETRY"), "ST_GEOMETRY", "TEXT"},
		{column("STPOINT"), "ST_POINT", "TEXT"},
		{column("ALPHANUM"), "ALPHANUM", "NVARCHAR"},
		{column("SHORTTEXT"), "SHORTTEXT", "NVARCHAR"},
		{column("NSTRING"), "NSTRING", "NVARCHAR"},
		{column("STRING"), "STRING", ""},
		{column("BINTEXT"), "BINTEXT", "TEXT"},
		{column("BSTRING"), "BSTRING", "VARBINARY"},
		{column("NVARCHAR"), "NVARCHAR", ""},
		{column("INTEGER"), "INTEGER", ""},
		{column("NCLOB"), "NCLOB", ""},
		{column("BOOLEAN"), "BOOLEAN", ""},
	}
	for _, testCase := range cases {
		if got := testCase.column.reportedTypeName(); got != testCase.reported {
			t.Errorf("%s reported as %q; want %q", testCase.column.databaseTypeName, got, testCase.reported)
		}
		if got := testCase.column.classification(); got != testCase.classification {
			t.Errorf("%s classified as %q; want %q", testCase.column.databaseTypeName, got, testCase.classification)
		}
	}
}

func TestLobColumnsAreRecognisedByTypeName(t *testing.T) {
	for _, typeName := range []string{"BLOB", "CLOB", "NCLOB", "TEXT", "BINTEXT"} {
		if !column(typeName).isLob() {
			t.Errorf("%s is not treated as a LOB", typeName)
		}
	}
	for _, typeName := range []string{"NVARCHAR", "VARBINARY", "STGEOMETRY", "DECIMAL"} {
		if column(typeName).isLob() {
			t.Errorf("%s is treated as a LOB", typeName)
		}
	}
	if column("BLOB").holdsText() || !column("NCLOB").holdsText() || !column("BINTEXT").holdsText() {
		t.Fatal("LOB text and binary kinds are mixed up")
	}
}

func TestTrimIncompleteRuneOnlyDropsATrailingPartialSequence(t *testing.T) {
	complete := []byte("abc😀")
	if got := trimIncompleteRune(complete); string(got) != "abc😀" {
		t.Fatalf("a complete tail was trimmed to %q", got)
	}
	for cut := 1; cut < 4; cut++ {
		partial := complete[:len(complete)-cut]
		if got := trimIncompleteRune(partial); string(got) != "abc" {
			t.Fatalf("cutting %d bytes left %q; want %q", cut, got, "abc")
		}
	}
	if got := trimIncompleteRune(nil); len(got) != 0 {
		t.Fatalf("nil trimmed to %q", got)
	}
}
