package hana

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strconv"
	"time"
	"unicode/utf8"
)

type cellKind uint8

const (
	cellNull cellKind = iota
	cellText
	cellBytes
)

var errMalformedCell = errors.New("a cell must be null, a string or an object with a bytes field")

type cell struct {
	kind  cellKind
	text  string
	bytes []byte
}

func nullCell() cell {
	return cell{kind: cellNull}
}

func textCell(text string) cell {
	return cell{kind: cellText, text: text}
}

func bytesCell(data []byte) cell {
	return cell{kind: cellBytes, bytes: data}
}

func (c *cell) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if bytes.Equal(trimmed, []byte("null")) {
		*c = nullCell()
		return nil
	}
	if len(trimmed) > 0 && trimmed[0] == '"' {
		var text string
		if err := json.Unmarshal(trimmed, &text); err != nil {
			return err
		}
		*c = textCell(text)
		return nil
	}
	var object struct {
		Bytes *string `json:"bytes"`
	}
	if err := json.Unmarshal(trimmed, &object); err != nil {
		return err
	}
	if object.Bytes == nil {
		return errMalformedCell
	}
	decoded, err := base64.StdEncoding.DecodeString(*object.Bytes)
	if err != nil {
		return err
	}
	*c = bytesCell(decoded)
	return nil
}

func (c cell) appendJSON(buffer []byte) []byte {
	switch c.kind {
	case cellText:
		return appendJSONString(buffer, c.text)
	case cellBytes:
		buffer = append(buffer, `{"bytes":"`...)
		buffer = base64.StdEncoding.AppendEncode(buffer, c.bytes)
		return append(buffer, `"}`...)
	default:
		return append(buffer, "null"...)
	}
}

type executeRequest struct {
	SQL            string  `json:"sql"`
	Parameters     *[]cell `json:"parameters"`
	RowCap         int64   `json:"rowCap"`
	TimeoutSeconds float64 `json:"timeoutSeconds"`
}

func (r executeRequest) hasParameters() bool {
	return r.Parameters != nil && len(*r.Parameters) > 0
}

func (r executeRequest) rowLimit() int {
	if r.RowCap <= 0 {
		return 0
	}
	return int(r.RowCap)
}

type explainRequest struct {
	SQL            string  `json:"sql"`
	TimeoutSeconds float64 `json:"timeoutSeconds"`
}

func secondsDuration(seconds float64) time.Duration {
	if seconds <= 0 {
		return 0
	}
	return time.Duration(seconds * float64(time.Second))
}

func decodeRequest[Request any](data []byte) (Request, *bridgeError) {
	var request Request
	if err := json.Unmarshal(data, &request); err != nil {
		return request, internalError(err.Error())
	}
	return request, nil
}

type connectResult struct {
	ServerVersion string `json:"serverVersion"`
	CurrentSchema string `json:"currentSchema"`
	ConnectionID  int64  `json:"connectionId"`
}

type resultEnvelope struct {
	columns               []string
	columnTypeNames       []string
	columnClassifications []string
	rows                  [][]cell
	rowsAffected          int64
	hasResultSet          bool
	executionTime         float64
	isTruncated           bool
	truncatedLobCount     int
	sessionLost           bool
}

func affectedRowsEnvelope(rowsAffected int64) *resultEnvelope {
	return &resultEnvelope{rowsAffected: rowsAffected}
}

func tabularEnvelope(columns []columnInfo) *resultEnvelope {
	envelope := &resultEnvelope{hasResultSet: true}
	for _, column := range columns {
		envelope.columns = append(envelope.columns, column.name)
		envelope.columnTypeNames = append(envelope.columnTypeNames, column.reportedTypeName())
		envelope.columnClassifications = append(envelope.columnClassifications, column.classification())
	}
	return envelope
}

func (e *resultEnvelope) appendJSON(buffer []byte) []byte {
	buffer = append(buffer, `{"columns":`...)
	buffer = appendStringArray(buffer, e.columns)
	buffer = append(buffer, `,"columnTypeNames":`...)
	buffer = appendStringArray(buffer, e.columnTypeNames)
	buffer = append(buffer, `,"columnClassifications":`...)
	buffer = appendOptionalStringArray(buffer, e.columnClassifications)
	buffer = append(buffer, `,"rows":[`...)
	for index, row := range e.rows {
		if index > 0 {
			buffer = append(buffer, ',')
		}
		buffer = appendRow(buffer, row)
	}
	buffer = append(buffer, `],"rowsAffected":`...)
	buffer = strconv.AppendInt(buffer, e.rowsAffected, 10)
	buffer = append(buffer, `,"hasResultSet":`...)
	buffer = strconv.AppendBool(buffer, e.hasResultSet)
	buffer = append(buffer, `,"executionTime":`...)
	buffer = strconv.AppendFloat(buffer, e.executionTime, 'f', -1, 64)
	buffer = append(buffer, `,"isTruncated":`...)
	buffer = strconv.AppendBool(buffer, e.isTruncated)
	buffer = append(buffer, `,"truncatedLobCount":`...)
	buffer = strconv.AppendInt(buffer, int64(e.truncatedLobCount), 10)
	buffer = append(buffer, `,"sessionLost":`...)
	buffer = strconv.AppendBool(buffer, e.sessionLost)
	return append(buffer, '}')
}

func appendRow(buffer []byte, row []cell) []byte {
	buffer = append(buffer, '[')
	for index, value := range row {
		if index > 0 {
			buffer = append(buffer, ',')
		}
		buffer = value.appendJSON(buffer)
	}
	return append(buffer, ']')
}

func appendStringArray(buffer []byte, values []string) []byte {
	buffer = append(buffer, '[')
	for index, value := range values {
		if index > 0 {
			buffer = append(buffer, ',')
		}
		buffer = appendJSONString(buffer, value)
	}
	return append(buffer, ']')
}

func appendOptionalStringArray(buffer []byte, values []string) []byte {
	buffer = append(buffer, '[')
	for index, value := range values {
		if index > 0 {
			buffer = append(buffer, ',')
		}
		if value == "" {
			buffer = append(buffer, "null"...)
			continue
		}
		buffer = appendJSONString(buffer, value)
	}
	return append(buffer, ']')
}

const lowercaseHexDigits = "0123456789abcdef"

func appendJSONString(buffer []byte, text string) []byte {
	buffer = append(buffer, '"')
	start := 0
	for index := 0; index < len(text); {
		character := text[index]
		if character < utf8.RuneSelf {
			if character >= 0x20 && character != '"' && character != '\\' {
				index++
				continue
			}
			buffer = append(buffer, text[start:index]...)
			buffer = appendEscapedASCII(buffer, character)
			index++
			start = index
			continue
		}
		decoded, size := utf8.DecodeRuneInString(text[index:])
		if decoded == utf8.RuneError && size == 1 {
			buffer = append(buffer, text[start:index]...)
			buffer = utf8.AppendRune(buffer, utf8.RuneError)
			index += size
			start = index
			continue
		}
		index += size
	}
	buffer = append(buffer, text[start:]...)
	return append(buffer, '"')
}

func appendEscapedASCII(buffer []byte, character byte) []byte {
	switch character {
	case '"', '\\':
		return append(buffer, '\\', character)
	case '\n':
		return append(buffer, '\\', 'n')
	case '\r':
		return append(buffer, '\\', 'r')
	case '\t':
		return append(buffer, '\\', 't')
	default:
		return append(buffer, '\\', 'u', '0', '0', lowercaseHexDigits[character>>4], lowercaseHexDigits[character&0xF])
	}
}
