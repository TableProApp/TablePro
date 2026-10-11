package hana

import (
	"database/sql"
	"fmt"
	"math"
	"math/big"
	"reflect"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/SAP/go-hdb/driver/unicode/cesu8"
	"golang.org/x/text/transform"
)

type temporalKind uint8

const (
	temporalTimestamp temporalKind = iota
	temporalDate
	temporalTime
	temporalSecondDate
)

const (
	dateLayout       = "2006-01-02"
	timeLayout       = "15:04:05"
	secondDateLayout = "2006-01-02 15:04:05"
	timestampLayout  = "2006-01-02 15:04:05.0000000"
)

const (
	emptyDateText       = "0000-00-00"
	emptyTimeText       = "00:00:00"
	emptySecondDateText = "0000-00-00 00:00:00"
	emptyTimestampText  = "0000-00-00 00:00:00.0000000"
)

const maxPlainDecimalExponent = 64

var (
	stringScanType     = reflect.TypeFor[string]()
	nullStringScanType = reflect.TypeFor[sql.NullString]()
)

type columnInfo struct {
	name             string
	databaseTypeName string
	textual          bool
	precision        int64
	scale            int64
	hasDecimalSize   bool
}

type decimalDecomposer interface {
	Decompose(buffer []byte) (form byte, negative bool, coefficient []byte, exponent int32)
}

func describeColumn(columnType *sql.ColumnType) columnInfo {
	precision, scale, hasDecimalSize := columnType.DecimalSize()
	return columnInfo{
		name:             columnType.Name(),
		databaseTypeName: columnType.DatabaseTypeName(),
		textual:          isTextScanType(columnType.ScanType()),
		precision:        precision,
		scale:            scale,
		hasDecimalSize:   hasDecimalSize,
	}
}

func isTextScanType(scanType reflect.Type) bool {
	return scanType == stringScanType || scanType == nullStringScanType
}

func (c columnInfo) reportedTypeName() string {
	switch c.databaseTypeName {
	case "DAYDATE":
		return "DATE"
	case "SECONDTIME":
		return "TIME"
	case "LONGDATE":
		return "TIMESTAMP"
	case "FIXED8", "FIXED12", "FIXED16":
		if c.hasDecimalSize {
			return fmt.Sprintf("DECIMAL(%d,%d)", c.precision, c.scale)
		}
		return "DECIMAL"
	case "STGEOMETRY":
		return "ST_GEOMETRY"
	case "STPOINT":
		return "ST_POINT"
	default:
		return c.databaseTypeName
	}
}

func (c columnInfo) classification() string {
	switch c.databaseTypeName {
	case "SECONDDATE":
		return "TIMESTAMP"
	case "SMALLDECIMAL":
		return "DECIMAL"
	case "STGEOMETRY", "STPOINT", "BINTEXT":
		return "TEXT"
	case "ALPHANUM", "SHORTTEXT", "NSTRING":
		return "NVARCHAR"
	case "BSTRING":
		return "VARBINARY"
	default:
		return ""
	}
}

func (c columnInfo) isLob() bool {
	switch c.databaseTypeName {
	case "BLOB", "CLOB", "NCLOB", "TEXT", "BINTEXT":
		return true
	default:
		return false
	}
}

func (c columnInfo) holdsText() bool {
	if c.textual {
		return true
	}
	switch c.databaseTypeName {
	case "CLOB", "NCLOB", "TEXT", "BINTEXT", "STGEOMETRY", "STPOINT", "ST_GEOMETRY", "ST_POINT":
		return true
	default:
		return false
	}
}

func (c columnInfo) floatBitSize() int {
	if c.databaseTypeName == "REAL" {
		return 32
	}
	return 64
}

func (c columnInfo) temporalKind() temporalKind {
	switch c.databaseTypeName {
	case "DAYDATE", "DATE":
		return temporalDate
	case "SECONDTIME", "TIME":
		return temporalTime
	case "SECONDDATE":
		return temporalSecondDate
	default:
		return temporalTimestamp
	}
}

func formatValue(value any, column columnInfo) cell {
	switch typed := value.(type) {
	case nil:
		return nullCell()
	case int64:
		return textCell(strconv.FormatInt(typed, 10))
	case float64:
		return textCell(formatFloat(typed, column.floatBitSize()))
	case bool:
		return textCell(formatBoolean(typed))
	case time.Time:
		return textCell(formatTemporal(typed, column.temporalKind()))
	case []byte:
		if column.holdsText() {
			return textCell(decodeText(typed))
		}
		return bytesCell(typed)
	case string:
		return textCell(decodeText([]byte(typed)))
	case decimalDecomposer:
		return textCell(formatDecimal(typed.Decompose(nil)))
	default:
		return textCell(fmt.Sprint(typed))
	}
}

func formatBoolean(value bool) string {
	if value {
		return "TRUE"
	}
	return "FALSE"
}

func formatFloat(value float64, bitSize int) string {
	switch {
	case math.IsNaN(value):
		return "NaN"
	case math.IsInf(value, 1):
		return "Infinity"
	case math.IsInf(value, -1):
		return "-Infinity"
	}
	magnitude := math.Abs(value)
	if value == 0 || (magnitude >= 1e-7 && magnitude < 1e21) {
		return strconv.FormatFloat(value, 'f', -1, bitSize)
	}
	return compactExponent(strconv.FormatFloat(value, 'e', -1, bitSize))
}

func compactExponent(scientific string) string {
	marker := strings.IndexByte(scientific, 'e')
	if marker < 0 || marker+2 > len(scientific) {
		return scientific
	}
	mantissa, sign, digits := scientific[:marker], scientific[marker+1], scientific[marker+2:]
	digits = strings.TrimLeft(digits, "0")
	if digits == "" {
		digits = "0"
	}
	return mantissa + "e" + string(sign) + digits
}

func formatDecimal(form byte, negative bool, coefficient []byte, exponent int32) string {
	switch form {
	case 1:
		if negative {
			return "-Infinity"
		}
		return "Infinity"
	case 2:
		return "NaN"
	}
	digits := new(big.Int).SetBytes(coefficient).String()
	text := decimalText(digits, exponent)
	if negative && digits != "0" {
		return "-" + text
	}
	return text
}

func decimalText(digits string, exponent int32) string {
	if exponent > maxPlainDecimalExponent || exponent < -maxPlainDecimalExponent {
		return digits + "E" + signedExponent(exponent)
	}
	if exponent >= 0 {
		if digits == "0" {
			return digits
		}
		return digits + strings.Repeat("0", int(exponent))
	}
	scale := int(-exponent)
	if len(digits) <= scale {
		digits = strings.Repeat("0", scale-len(digits)+1) + digits
	}
	point := len(digits) - scale
	return digits[:point] + "." + digits[point:]
}

func signedExponent(exponent int32) string {
	if exponent < 0 {
		return strconv.FormatInt(int64(exponent), 10)
	}
	return "+" + strconv.FormatInt(int64(exponent), 10)
}

func formatTemporal(value time.Time, kind temporalKind) string {
	value = value.UTC()
	if value.Year() == 0 {
		return emptyTemporalText(kind)
	}
	switch kind {
	case temporalDate:
		return value.Format(dateLayout)
	case temporalTime:
		return value.Format(timeLayout)
	case temporalSecondDate:
		return value.Format(secondDateLayout)
	default:
		return value.Format(timestampLayout)
	}
}

func emptyTemporalText(kind temporalKind) string {
	switch kind {
	case temporalDate:
		return emptyDateText
	case temporalTime:
		return emptyTimeText
	case temporalSecondDate:
		return emptySecondDateText
	default:
		return emptyTimestampText
	}
}

func decodeText(data []byte) string {
	if utf8.Valid(data) {
		return string(data)
	}
	decoded, _, err := transform.Bytes(cesu8.NewDecoder(cesu8.ReplaceErrorHandler), data)
	if err != nil || !utf8.Valid(decoded) {
		return strings.ToValidUTF8(string(data), string(utf8.RuneError))
	}
	return string(decoded)
}

func trimIncompleteRune(data []byte) []byte {
	start := len(data) - 1
	for start >= 0 && len(data)-start < utf8.UTFMax && !utf8.RuneStart(data[start]) {
		start--
	}
	if start < 0 || utf8.FullRune(data[start:]) {
		return data
	}
	return data[:start]
}
