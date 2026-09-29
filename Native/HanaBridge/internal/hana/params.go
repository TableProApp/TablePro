package hana

import (
	"encoding/hex"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	hdb "github.com/SAP/go-hdb/driver"
)

const (
	expectDate       = "date"
	expectTime       = "time"
	expectSecondDate = "seconddate"
	expectTimestamp  = "timestamp"
	expectBoolean    = "boolean"
	expectInteger    = "integer"
	expectDecimal    = "decimal"
	expectDouble     = "double"
	expectScale      = "scale"
	expectHex        = "hex"
	expectOutput     = "output"
)

const maxTimestampFractionDigits = 7

var (
	hanaEpoch            = time.Date(1, time.January, 1, 0, 0, 0, 0, time.UTC)
	emptyDateInstant     = hanaEpoch.AddDate(0, 0, -1)
	emptySecondInstant   = hanaEpoch.Add(-time.Second)
	emptyLongdateInstant = hanaEpoch.Add(-100 * time.Nanosecond)
)

type parameterType struct {
	databaseTypeName string
	precision        int64
	scale            int64
	hasDecimalSize   bool
	output           bool
}

func describeParameter(parameter hdb.ParameterType) parameterType {
	precision, scale, hasDecimalSize := parameter.DecimalSize()
	return parameterType{
		databaseTypeName: parameter.DatabaseTypeName(),
		precision:        precision,
		scale:            scale,
		hasDecimalSize:   hasDecimalSize,
		output:           parameter.Out() || parameter.InOut(),
	}
}

func refuseOutputParameters(parameters []parameterType) *bridgeError {
	for index, parameter := range parameters {
		if parameter.output {
			return parameterError(index+1, expectOutput, "")
		}
	}
	return nil
}

func bindsLargeObject(parameters []parameterType) bool {
	for _, parameter := range parameters {
		switch parameter.databaseTypeName {
		case "BLOB", "CLOB", "NCLOB", "TEXT", "BINTEXT", "LOCATOR", "NLOCATOR":
			return true
		}
	}
	return false
}

func isSpatialType(databaseTypeName string) bool {
	switch databaseTypeName {
	case "STGEOMETRY", "STPOINT", "ST_GEOMETRY", "ST_POINT":
		return true
	default:
		return false
	}
}

func bindParameters(values []cell, types []parameterType) ([]any, *bridgeError) {
	if len(values) != len(types) {
		return nil, internalError(fmt.Sprintf("the statement takes %d parameters, %d were sent", len(types), len(values)))
	}
	arguments := make([]any, len(values))
	for index, value := range values {
		argument, failure := bindParameter(index+1, value, types[index])
		if failure != nil {
			return nil, failure
		}
		arguments[index] = argument
	}
	return arguments, nil
}

func bindParameter(position int, value cell, target parameterType) (any, *bridgeError) {
	switch value.kind {
	case cellNull:
		return nil, nil
	case cellBytes:
		if isSpatialType(target.databaseTypeName) {
			return hex.EncodeToString(value.bytes), nil
		}
		return value.bytes, nil
	default:
		return convertText(position, value.text, target)
	}
}

func convertText(position int, text string, target parameterType) (any, *bridgeError) {
	switch target.databaseTypeName {
	case "DATE", "DAYDATE":
		return parseTemporalParameter(position, text, temporalDate, expectDate)
	case "TIME", "SECONDTIME":
		return parseTemporalParameter(position, text, temporalTime, expectTime)
	case "SECONDDATE":
		return parseTemporalParameter(position, text, temporalSecondDate, expectSecondDate)
	case "TIMESTAMP", "LONGDATE":
		return parseTemporalParameter(position, text, temporalTimestamp, expectTimestamp)
	case "BOOLEAN":
		return parseBooleanParameter(position, text)
	case "TINYINT":
		return parseIntegerParameter(position, text, 0, math.MaxUint8)
	case "SMALLINT":
		return parseIntegerParameter(position, text, math.MinInt16, math.MaxInt16)
	case "INTEGER":
		return parseIntegerParameter(position, text, math.MinInt32, math.MaxInt32)
	case "BIGINT":
		return parseIntegerParameter(position, text, math.MinInt64, math.MaxInt64)
	case "DECIMAL", "SMALLDECIMAL", "FIXED8", "FIXED12", "FIXED16":
		return checkDecimalParameter(position, text, target)
	case "REAL", "DOUBLE":
		return checkFloatParameter(position, text)
	case "STGEOMETRY", "STPOINT", "ST_GEOMETRY", "ST_POINT":
		return checkHexParameter(position, text)
	default:
		return text, nil
	}
}

func checkHexParameter(position int, text string) (any, *bridgeError) {
	if _, err := hex.DecodeString(text); err != nil {
		return nil, parameterError(position, expectHex, text)
	}
	return text, nil
}

func parseTemporalParameter(position int, text string, kind temporalKind, expected string) (any, *bridgeError) {
	instant, ok := parseTemporalText(text, kind)
	if !ok {
		return nil, parameterError(position, expected, text)
	}
	return instant, nil
}

func parseBooleanParameter(position int, text string) (any, *bridgeError) {
	switch strings.ToUpper(text) {
	case "TRUE", "1":
		return true, nil
	case "FALSE", "0":
		return false, nil
	default:
		return nil, parameterError(position, expectBoolean, text)
	}
}

func parseIntegerParameter(position int, text string, minimum, maximum int64) (any, *bridgeError) {
	value, err := strconv.ParseInt(text, 10, 64)
	if err != nil || value < minimum || value > maximum {
		return nil, parameterError(position, expectInteger, text)
	}
	return value, nil
}

func checkFloatParameter(position int, text string) (any, *bridgeError) {
	if _, err := strconv.ParseFloat(text, 64); err != nil {
		return nil, parameterError(position, expectDouble, text)
	}
	return text, nil
}

func checkDecimalParameter(position int, text string, target parameterType) (any, *bridgeError) {
	literal, ok := parseDecimalLiteral(text)
	if !ok {
		return nil, parameterError(position, expectDecimal, text)
	}
	if !target.hasDecimalSize || !isFixedDecimal(target.databaseTypeName) {
		return text, nil
	}
	if int64(literal.fractionDigits()) > target.scale {
		return nil, parameterError(position, expectScale, text)
	}
	if int64(literal.integerDigits()) > target.precision-target.scale {
		return nil, parameterError(position, expectDecimal, text)
	}
	return text, nil
}

func isFixedDecimal(databaseTypeName string) bool {
	switch databaseTypeName {
	case "FIXED8", "FIXED12", "FIXED16":
		return true
	default:
		return false
	}
}

type decimalLiteral struct {
	significand string
	exponent    int
}

func parseDecimalLiteral(text string) (decimalLiteral, bool) {
	body := text
	if strings.HasPrefix(body, "-") || strings.HasPrefix(body, "+") {
		body = body[1:]
	}
	mantissa, exponentText, hasExponent := cutExponent(body)
	exponent := 0
	if hasExponent {
		parsed, err := strconv.Atoi(exponentText)
		if err != nil {
			return decimalLiteral{}, false
		}
		exponent = parsed
	}
	whole, fraction, _ := strings.Cut(mantissa, ".")
	if whole == "" && fraction == "" {
		return decimalLiteral{}, false
	}
	if !isDigits(whole) || !isDigits(fraction) {
		return decimalLiteral{}, false
	}
	significand := strings.TrimLeft(whole+fraction, "0")
	exponent -= len(fraction)
	for strings.HasSuffix(significand, "0") {
		significand = significand[:len(significand)-1]
		exponent++
	}
	if significand == "" {
		return decimalLiteral{}, true
	}
	return decimalLiteral{significand: significand, exponent: exponent}, true
}

func cutExponent(body string) (string, string, bool) {
	marker := strings.IndexAny(body, "eE")
	if marker < 0 {
		return body, "", false
	}
	return body[:marker], body[marker+1:], true
}

func isDigits(text string) bool {
	for index := 0; index < len(text); index++ {
		if text[index] < '0' || text[index] > '9' {
			return false
		}
	}
	return true
}

func (d decimalLiteral) fractionDigits() int {
	if d.exponent >= 0 {
		return 0
	}
	return -d.exponent
}

func (d decimalLiteral) integerDigits() int {
	return max(len(d.significand)+d.exponent, 0)
}

func parseTemporalText(text string, kind temporalKind) (time.Time, bool) {
	if kind == temporalTime {
		clock, ok := parseClock(text, false)
		if !ok {
			return time.Time{}, false
		}
		return hanaEpoch.Add(clock), true
	}
	datePart, clockPart, hasClock := splitDateAndClock(text)
	if hasClock && kind == temporalDate {
		return time.Time{}, false
	}
	var clock time.Duration
	if hasClock {
		parsed, ok := parseClock(clockPart, kind == temporalTimestamp)
		if !ok {
			return time.Time{}, false
		}
		clock = parsed
	}
	if datePart == emptyDateText {
		if clock != 0 {
			return time.Time{}, false
		}
		return emptyInstant(kind), true
	}
	day, ok := parseCalendarDate(datePart)
	if !ok {
		return time.Time{}, false
	}
	return day.Add(clock), true
}

func emptyInstant(kind temporalKind) time.Time {
	switch kind {
	case temporalDate:
		return emptyDateInstant
	case temporalSecondDate:
		return emptySecondInstant
	default:
		return emptyLongdateInstant
	}
}

func splitDateAndClock(text string) (string, string, bool) {
	if len(text) > len(dateLayout) && (text[len(dateLayout)] == ' ' || text[len(dateLayout)] == 'T') {
		return text[:len(dateLayout)], text[len(dateLayout)+1:], true
	}
	return text, "", false
}

func parseCalendarDate(text string) (time.Time, bool) {
	if len(text) != len(dateLayout) || text[4] != '-' || text[7] != '-' {
		return time.Time{}, false
	}
	year, yearOK := parseFixedDigits(text[0:4])
	month, monthOK := parseFixedDigits(text[5:7])
	day, dayOK := parseFixedDigits(text[8:10])
	if !yearOK || !monthOK || !dayOK || year < 1 || month < 1 || month > 12 || day < 1 {
		return time.Time{}, false
	}
	value := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
	if value.Month() != time.Month(month) || value.Day() != day {
		return time.Time{}, false
	}
	return value, true
}

func parseClock(text string, allowsFraction bool) (time.Duration, bool) {
	if len(text) < len(timeLayout) || text[2] != ':' || text[5] != ':' {
		return 0, false
	}
	hour, hourOK := parseFixedDigits(text[0:2])
	minute, minuteOK := parseFixedDigits(text[3:5])
	second, secondOK := parseFixedDigits(text[6:8])
	if !hourOK || !minuteOK || !secondOK || hour > 23 || minute > 59 || second > 59 {
		return 0, false
	}
	clock := time.Duration(hour)*time.Hour + time.Duration(minute)*time.Minute + time.Duration(second)*time.Second
	fraction := text[len(timeLayout):]
	if fraction == "" {
		return clock, true
	}
	digits, hasPoint := strings.CutPrefix(fraction, ".")
	if !allowsFraction || !hasPoint || digits == "" || len(digits) > maxTimestampFractionDigits || !isDigits(digits) {
		return 0, false
	}
	padded, _ := strconv.Atoi(digits + strings.Repeat("0", maxTimestampFractionDigits-len(digits)))
	return clock + time.Duration(padded)*100*time.Nanosecond, true
}

func parseFixedDigits(text string) (int, bool) {
	if text == "" || !isDigits(text) {
		return 0, false
	}
	value, err := strconv.Atoi(text)
	return value, err == nil
}
