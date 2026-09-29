package hana

import (
	"bytes"
	"math"
	"strconv"
	"testing"
	"time"
)

func parameter(databaseTypeName string) parameterType {
	return parameterType{databaseTypeName: databaseTypeName}
}

func fixedParameter(databaseTypeName string, precision, scale int64) parameterType {
	return parameterType{databaseTypeName: databaseTypeName, precision: precision, scale: scale, hasDecimalSize: true}
}

func bindText(t *testing.T, text string, target parameterType) any {
	t.Helper()
	value, failure := bindParameter(1, textCell(text), target)
	if failure != nil {
		t.Fatalf("binding %q to %s failed: %v", text, target.databaseTypeName, failure)
	}
	return value
}

func assertParameterFailure(t *testing.T, text string, target parameterType, expected string) {
	t.Helper()
	_, failure := bindParameter(3, textCell(text), target)
	assertKind(t, failure, kindParameter)
	if failure.Parameter != 3 || failure.Expected != expected || failure.Message != text {
		t.Fatalf("failure = %+v; want parameter 3, expected %q, message %q", failure, expected, text)
	}
}

func hanaDayNumber(value time.Time) int64 {
	midnight := time.Date(value.Year(), value.Month(), value.Day(), 0, 0, 0, 0, time.UTC)
	return int64(midnight.Sub(hanaEpoch)/(24*time.Hour)) + 1
}

func encodeDaydate(value time.Time) int64 {
	return hanaDayNumber(value)
}

func encodeSeconddate(value time.Time) int64 {
	return ((((hanaDayNumber(value)-1)*24+int64(value.Hour()))*60+int64(value.Minute()))*60 + int64(value.Second())) + 1
}

func encodeLongdate(value time.Time) int64 {
	seconds := (((hanaDayNumber(value)-1)*24+int64(value.Hour()))*60+int64(value.Minute()))*60 + int64(value.Second())
	return seconds*10000000 + int64(value.Nanosecond()/100) + 1
}

func TestNullAndBytesBindAsIs(t *testing.T) {
	value, failure := bindParameter(1, nullCell(), parameter("DAYDATE"))
	if failure != nil || value != nil {
		t.Fatalf("null bound as %v, %v", value, failure)
	}
	value, failure = bindParameter(1, bytesCell([]byte{1, 2}), parameter("BLOB"))
	data, ok := value.([]byte)
	if failure != nil || !ok || len(data) != 2 {
		t.Fatalf("bytes bound as %v, %v", value, failure)
	}
}

func TestDateParametersParseInUTC(t *testing.T) {
	want := time.Date(2024, time.February, 29, 0, 0, 0, 0, time.UTC)
	for _, typeName := range []string{"DATE", "DAYDATE"} {
		if got := bindText(t, "2024-02-29", parameter(typeName)); got != want {
			t.Fatalf("%s bound as %v", typeName, got)
		}
	}
	for _, text := range []string{"2023-02-29", "2024-13-01", "2024-00-10", "0000-01-01", "2024-1-01", "2024/01/01", "2024-01-01 00:00:00", "", "20240101"} {
		assertParameterFailure(t, text, parameter("DAYDATE"), expectDate)
	}
}

func TestTimeParametersParseTheClock(t *testing.T) {
	got := bindText(t, "13:45:07", parameter("SECONDTIME"))
	if got != hanaEpoch.Add(13*time.Hour+45*time.Minute+7*time.Second) {
		t.Fatalf("SECONDTIME bound as %v", got)
	}
	bindText(t, "00:00:00", parameter("TIME"))
	bindText(t, "23:59:59", parameter("TIME"))
	for _, text := range []string{"24:00:00", "12:60:00", "12:00:60", "12:00", "12:00:00.5", "1:02:03", "12-00-00"} {
		assertParameterFailure(t, text, parameter("SECONDTIME"), expectTime)
	}
}

func TestSecondDateParametersAcceptTheDateFormAndATSeparator(t *testing.T) {
	want := time.Date(2024, time.February, 29, 13, 45, 7, 0, time.UTC)
	if got := bindText(t, "2024-02-29 13:45:07", parameter("SECONDDATE")); got != want {
		t.Fatalf("bound as %v", got)
	}
	if got := bindText(t, "2024-02-29T13:45:07", parameter("SECONDDATE")); got != want {
		t.Fatalf("T separator bound as %v", got)
	}
	if got := bindText(t, "2024-02-29", parameter("SECONDDATE")); got != want.Truncate(24*time.Hour) {
		t.Fatalf("date form bound as %v", got)
	}
	for _, text := range []string{"2024-02-29 13:45:07.1", "2024-02-29 13:45", "2024-02-29X13:45:07", "2024-02-29 13:45:07Z"} {
		assertParameterFailure(t, text, parameter("SECONDDATE"), expectSecondDate)
	}
}

func TestTimestampParametersAcceptUpToSevenFractionDigits(t *testing.T) {
	cases := map[string]time.Time{
		"2024-02-29 13:45:07.1234567": time.Date(2024, 2, 29, 13, 45, 7, 123456700, time.UTC),
		"2024-02-29 13:45:07.5":       time.Date(2024, 2, 29, 13, 45, 7, 500000000, time.UTC),
		"2024-02-29T13:45:07.0000001": time.Date(2024, 2, 29, 13, 45, 7, 100, time.UTC),
		"2024-02-29 13:45:07":         time.Date(2024, 2, 29, 13, 45, 7, 0, time.UTC),
		"2024-02-29":                  time.Date(2024, 2, 29, 0, 0, 0, 0, time.UTC),
		"0001-01-01 00:00:00.0000000": time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC),
		"9999-12-31 23:59:59.9999999": time.Date(9999, 12, 31, 23, 59, 59, 999999900, time.UTC),
	}
	for text, want := range cases {
		for _, typeName := range []string{"TIMESTAMP", "LONGDATE"} {
			if got := bindText(t, text, parameter(typeName)); got != want {
				t.Fatalf("%s %q bound as %v; want %v", typeName, text, got, want)
			}
		}
	}
	for _, text := range []string{"2024-02-29 13:45:07.12345678", "2024-02-29 13:45:07.", "2024-02-29 13:45:07,5", "2024-02-29 13:45:07.12a"} {
		assertParameterFailure(t, text, parameter("LONGDATE"), expectTimestamp)
	}
}

func TestEmptyDateSpellingsRoundTripToTheInstantsGoHdbEncodesAsEmpty(t *testing.T) {
	cases := []struct {
		column    string
		decoded   time.Time
		encode    func(time.Time) int64
		spellings []string
	}{
		{"DAYDATE", hanaEpoch.AddDate(0, 0, -1), encodeDaydate, []string{"0000-00-00"}},
		{"SECONDDATE", hanaEpoch.Add(-time.Second), encodeSeconddate, []string{"0000-00-00", "0000-00-00 00:00:00", "0000-00-00T00:00:00"}},
		{"LONGDATE", hanaEpoch.Add(-100 * time.Nanosecond), encodeLongdate, []string{"0000-00-00", "0000-00-00 00:00:00", "0000-00-00 00:00:00.0000000"}},
	}
	for _, testCase := range cases {
		if encoded := testCase.encode(testCase.decoded); encoded != 0 {
			t.Fatalf("%s: go-hdb's decoding of wire value 0 re-encodes as %d", testCase.column, encoded)
		}
		formatted := formatValue(testCase.decoded, column(testCase.column)).text
		spellings := append([]string{formatted}, testCase.spellings...)
		for _, spelling := range spellings {
			bound := bindText(t, spelling, parameter(testCase.column))
			instant, ok := bound.(time.Time)
			if !ok || !instant.Equal(testCase.decoded) {
				t.Fatalf("%s %q bound as %v; want %v", testCase.column, spelling, bound, testCase.decoded)
			}
			if encoded := testCase.encode(instant); encoded != 0 {
				t.Fatalf("%s %q encodes as %d; want the empty value 0", testCase.column, spelling, encoded)
			}
		}
	}
	assertParameterFailure(t, "0000-00-00 00:00:01", parameter("SECONDDATE"), expectSecondDate)
	assertParameterFailure(t, "0000-00-00 00:00:00.0000001", parameter("LONGDATE"), expectTimestamp)
}

func TestFormattedTemporalValuesParseBackToTheSameInstant(t *testing.T) {
	cases := []struct {
		column string
		value  time.Time
	}{
		{"DAYDATE", time.Date(2024, 2, 29, 0, 0, 0, 0, time.UTC)},
		{"DAYDATE", time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC)},
		{"SECONDTIME", hanaEpoch.Add(23*time.Hour + 59*time.Minute + 59*time.Second)},
		{"SECONDDATE", time.Date(1999, 12, 31, 23, 59, 59, 0, time.UTC)},
		{"LONGDATE", time.Date(2024, 2, 29, 13, 45, 7, 123456700, time.UTC)},
		{"LONGDATE", time.Date(9999, 12, 31, 23, 59, 59, 999999900, time.UTC)},
	}
	for _, testCase := range cases {
		formatted := formatValue(testCase.value, column(testCase.column)).text
		bound := bindText(t, formatted, parameter(testCase.column))
		if instant, ok := bound.(time.Time); !ok || !instant.Equal(testCase.value) {
			t.Fatalf("%s %q bound as %v; want %v", testCase.column, formatted, bound, testCase.value)
		}
	}
}

func TestBooleanParameters(t *testing.T) {
	for text, want := range map[string]bool{"TRUE": true, "true": true, "True": true, "1": true, "FALSE": false, "false": false, "0": false} {
		if got := bindText(t, text, parameter("BOOLEAN")); got != want {
			t.Fatalf("%q bound as %v", text, got)
		}
	}
	for _, text := range []string{"yes", "t", "2", "", "UNKNOWN"} {
		assertParameterFailure(t, text, parameter("BOOLEAN"), expectBoolean)
	}
}

func TestIntegerParametersParseAndRespectTheColumnRange(t *testing.T) {
	cases := []struct {
		typeName string
		minimum  int64
		maximum  int64
	}{
		{"TINYINT", 0, math.MaxUint8},
		{"SMALLINT", math.MinInt16, math.MaxInt16},
		{"INTEGER", math.MinInt32, math.MaxInt32},
		{"BIGINT", math.MinInt64, math.MaxInt64},
	}
	for _, testCase := range cases {
		for _, value := range []int64{testCase.minimum, testCase.maximum} {
			text := strconv.FormatInt(value, 10)
			if got := bindText(t, text, parameter(testCase.typeName)); got != value {
				t.Fatalf("%s %q bound as %v", testCase.typeName, text, got)
			}
		}
		if testCase.typeName != "BIGINT" {
			assertParameterFailure(t, strconv.FormatInt(testCase.maximum+1, 10), parameter(testCase.typeName), expectInteger)
			assertParameterFailure(t, strconv.FormatInt(testCase.minimum-1, 10), parameter(testCase.typeName), expectInteger)
		}
	}
	for _, text := range []string{"1.5", "abc", "", " 1", "1e3", "9223372036854775808"} {
		assertParameterFailure(t, text, parameter("BIGINT"), expectInteger)
	}
}

func TestDecimalParametersRejectMoreFractionDigitsThanTheScale(t *testing.T) {
	fixed := fixedParameter("FIXED8", 10, 2)
	for _, text := range []string{"123.45", "-0.05", "1.50", "1.500", "12345678.9", "0", "1E2", "1.2E1", "-12345678.99", "+7", ".5", "5."} {
		if got := bindText(t, text, fixed); got != text {
			t.Fatalf("%q bound as %v; want the text passed through", text, got)
		}
	}
	assertParameterFailure(t, "123.456", fixed, expectScale)
	assertParameterFailure(t, "-0.001", fixed, expectScale)
	assertParameterFailure(t, "1E-3", fixed, expectScale)
	assertParameterFailure(t, "123456789", fixed, expectDecimal)
	for _, text := range []string{"abc", "", "1/3", "0x10", "1.2.3", "--1", "1e", "Inf", "NaN", ".", "1 000"} {
		assertParameterFailure(t, text, fixed, expectDecimal)
	}
	for _, typeName := range []string{"FIXED12", "FIXED16"} {
		assertParameterFailure(t, "0.123", fixedParameter(typeName, 28, 2), expectScale)
	}
}

func TestFloatingDecimalAndDoubleParametersPassTheTextThrough(t *testing.T) {
	floating := fixedParameter("DECIMAL", 34, 32767)
	if got := bindText(t, "1.234567890123456789E-40", floating); got != "1.234567890123456789E-40" {
		t.Fatalf("DECIMAL bound as %v", got)
	}
	bindText(t, "3.14", parameter("SMALLDECIMAL"))
	assertParameterFailure(t, "pi", parameter("SMALLDECIMAL"), expectDecimal)
	for _, typeName := range []string{"REAL", "DOUBLE"} {
		if got := bindText(t, "2.5e-3", parameter(typeName)); got != "2.5e-3" {
			t.Fatalf("%s bound as %v", typeName, got)
		}
		assertParameterFailure(t, "two", parameter(typeName), expectDouble)
	}
}

func TestOtherTypesBindTheTextUnchanged(t *testing.T) {
	for _, typeName := range []string{"NVARCHAR", "VARCHAR", "NCLOB", "CLOB", "VARBINARY", "ALPHANUM"} {
		if got := bindText(t, "value", parameter(typeName)); got != "value" {
			t.Fatalf("%s bound as %v", typeName, got)
		}
	}
}

func TestBindParametersNamesTheFailingPosition(t *testing.T) {
	values := []cell{textCell("1"), textCell("2024-02-30")}
	types := []parameterType{parameter("INTEGER"), parameter("DAYDATE")}
	_, failure := bindParameters(values, types)
	assertKind(t, failure, kindParameter)
	if failure.Parameter != 2 || failure.Expected != expectDate {
		t.Fatalf("failure = %+v; want parameter 2 expecting a date", failure)
	}
	_, failure = bindParameters(values[:1], types)
	assertKind(t, failure, kindInternal)
	arguments, failure := bindParameters([]cell{textCell("7"), nullCell()}, types)
	if failure != nil || arguments[0] != int64(7) || arguments[1] != nil {
		t.Fatalf("arguments = %v, %v", arguments, failure)
	}
}

func TestSpatialParametersTakeHexWellKnownBinaryOnly(t *testing.T) {
	point := "0101000000000000000000F03F0000000000000040"
	for _, typeName := range []string{"STGEOMETRY", "STPOINT", "ST_GEOMETRY", "ST_POINT"} {
		if got := bindText(t, point, parameter(typeName)); got != point {
			t.Fatalf("%s bound as %v", typeName, got)
		}
		assertParameterFailure(t, "POINT (1 2)", parameter(typeName), expectHex)
		bound, failure := bindParameter(1, bytesCell([]byte{0x01, 0xFF}), parameter(typeName))
		if failure != nil || bound != "01ff" {
			t.Fatalf("%s bytes bound as %v, %v; want the hex text go-hdb decodes", typeName, bound, failure)
		}
	}
	bound, failure := bindParameter(1, bytesCell([]byte{0x01, 0xFF}), parameter("VARBINARY"))
	if failure != nil || !bytes.Equal(bound.([]byte), []byte{0x01, 0xFF}) {
		t.Fatalf("VARBINARY bytes bound as %v, %v", bound, failure)
	}
}

func TestOutputParametersAreRefusedWithTheirPosition(t *testing.T) {
	input := parameter("INTEGER")
	output := parameter("INTEGER")
	output.output = true
	if failure := refuseOutputParameters([]parameterType{input, input}); failure != nil {
		t.Fatalf("input parameters refused: %+v", failure)
	}
	failure := refuseOutputParameters([]parameterType{input, output})
	assertKind(t, failure, kindParameter)
	if failure.Parameter != 2 || failure.Expected != expectOutput {
		t.Fatalf("failure = %+v; want parameter 2 refused as an OUT parameter", failure)
	}
}

func TestOnlyLargeObjectParametersNeedATransaction(t *testing.T) {
	for _, typeName := range []string{"BLOB", "CLOB", "NCLOB", "TEXT", "BINTEXT"} {
		if !bindsLargeObject([]parameterType{parameter("INTEGER"), parameter(typeName)}) {
			t.Fatalf("%s does not ask for a transaction", typeName)
		}
	}
	if bindsLargeObject([]parameterType{parameter("NVARCHAR"), parameter("VARBINARY"), parameter("DECIMAL")}) {
		t.Fatal("a statement without LOB parameters asks for a transaction")
	}
}
