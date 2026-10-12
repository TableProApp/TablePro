package hana

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func decodeEnvelope(t *testing.T, envelope *resultEnvelope) map[string]json.RawMessage {
	t.Helper()
	encoded := envelope.appendJSON(nil)
	if !json.Valid(encoded) {
		t.Fatalf("envelope is not valid JSON: %s", encoded)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &fields); err != nil {
		t.Fatal(err)
	}
	return fields
}

func TestEnvelopeArraysAreNeverNull(t *testing.T) {
	envelopes := map[string]*resultEnvelope{
		"affected rows": affectedRowsEnvelope(3),
		"zero value":    {},
		"no rows":       tabularEnvelope([]columnInfo{column("INTEGER")}),
		"no columns":    tabularEnvelope(nil),
	}
	for label, envelope := range envelopes {
		fields := decodeEnvelope(t, envelope)
		for _, key := range []string{"columns", "columnTypeNames", "columnClassifications", "rows"} {
			raw, ok := fields[key]
			if !ok || !bytes.HasPrefix(raw, []byte("[")) {
				t.Fatalf("%s: %s = %s; want an array", label, key, raw)
			}
		}
	}
}

func TestEnvelopeCarriesEveryContractKey(t *testing.T) {
	envelope := tabularEnvelope([]columnInfo{
		{name: "ID", databaseTypeName: "INTEGER"},
		{name: "WHEN", databaseTypeName: "SECONDDATE"},
	})
	envelope.rows = append(envelope.rows, []cell{textCell("1"), nullCell()})
	envelope.executionTime = 0.0123
	envelope.isTruncated = true
	envelope.truncatedLobCount = 2
	encoded := string(envelope.appendJSON(nil))
	want := `{"columns":["ID","WHEN"],"columnTypeNames":["INTEGER","SECONDDATE"],"columnClassifications":[null,"TIMESTAMP"],` +
		`"rows":[["1",null]],"rowsAffected":0,"hasResultSet":true,"executionTime":0.0123,"isTruncated":true,"truncatedLobCount":2,"sessionLost":false}`
	if encoded != want {
		t.Fatalf("envelope =\n%s\nwant\n%s", encoded, want)
	}
}

func TestCellsEncodeAsNullStringOrBytesObject(t *testing.T) {
	row := []cell{nullCell(), textCell("a\"b"), bytesCell([]byte{0, 1, 255}), bytesCell(nil), textCell("")}
	encoded := appendRow(nil, row)
	want := `[null,"a\"b",{"bytes":"AAH/"},{"bytes":""},""]`
	if string(encoded) != want {
		t.Fatalf("row = %s; want %s", encoded, want)
	}
	var decoded []cell
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded[0].kind != cellNull || decoded[1].text != "a\"b" || string(decoded[2].bytes) != string([]byte{0, 1, 255}) {
		t.Fatalf("round trip = %+v", decoded)
	}
}

func TestJSONStringEscapingMatchesEncodingJSON(t *testing.T) {
	samples := []string{
		"",
		"plain",
		"quote \" and backslash \\",
		"controls \x00 \x01 \x1f \t \n \r \b \f",
		"unicode Grüße 😀 \u2028 \u2029",
		"invalid \xff\xfe bytes",
		"cut \xe2\x82",
		"<html> & 'quotes'",
		"\x7f",
	}
	for _, sample := range samples {
		encoded := appendJSONString(nil, sample)
		if !json.Valid(encoded) {
			t.Fatalf("%q encoded to invalid JSON %s", sample, encoded)
		}
		var decoded string
		if err := json.Unmarshal(encoded, &decoded); err != nil {
			t.Fatal(err)
		}
		reference, _ := json.Marshal(sample)
		var referenceDecoded string
		if err := json.Unmarshal(reference, &referenceDecoded); err != nil {
			t.Fatal(err)
		}
		if decoded != referenceDecoded {
			t.Fatalf("%q decodes to %q; encoding/json gives %q", sample, decoded, referenceDecoded)
		}
	}
}

func TestExecuteRequestDecoding(t *testing.T) {
	request, failure := decodeRequest[executeRequest]([]byte(`{"sql":"SELECT 1 FROM DUMMY","parameters":null,"rowCap":1000,"timeoutSeconds":2.5}`))
	if failure != nil {
		t.Fatal(failure)
	}
	if request.hasParameters() || request.rowLimit() != 1000 || secondsDuration(request.TimeoutSeconds).Milliseconds() != 2500 {
		t.Fatalf("request = %+v", request)
	}
	request, failure = decodeRequest[executeRequest]([]byte(`{"sql":"INSERT INTO T VALUES (?, ?, ?)","parameters":[null,"text",{"bytes":"AAH/"}],"rowCap":0,"timeoutSeconds":0}`))
	if failure != nil {
		t.Fatal(failure)
	}
	if !request.hasParameters() || request.rowLimit() != 0 || secondsDuration(request.TimeoutSeconds) != 0 {
		t.Fatalf("request = %+v", request)
	}
	values := *request.Parameters
	if values[0].kind != cellNull || values[1].kind != cellText || values[1].text != "text" || values[2].kind != cellBytes || len(values[2].bytes) != 3 {
		t.Fatalf("parameters = %+v", values)
	}
	empty, _ := decodeRequest[executeRequest]([]byte(`{"sql":"SELECT 1 FROM DUMMY","parameters":[]}`))
	if empty.hasParameters() {
		t.Fatal("an empty parameter array routed to the prepared path")
	}
	negative, _ := decodeRequest[executeRequest]([]byte(`{"sql":"x","rowCap":-5}`))
	if negative.rowLimit() != 0 {
		t.Fatalf("a negative row cap became %d", negative.rowLimit())
	}
}

func TestMalformedRequestsAreInternalErrors(t *testing.T) {
	for _, body := range []string{`not json`, `{"sql":"x","parameters":[{"text":"x"}]}`, `{"sql":"x","parameters":[{"bytes":"%%%"}]}`, `{"sql":"x","parameters":[1]}`} {
		_, failure := decodeRequest[executeRequest]([]byte(body))
		assertKind(t, failure, kindInternal)
	}
}

func TestErrorJSONCarriesEveryKey(t *testing.T) {
	failure := &bridgeError{Kind: kindServer, Code: 259, Position: 14, Message: "invalid table name:  Could not find table/view X"}
	encoded := string(failure.encoded())
	want := `{"kind":"server","code":259,"position":14,"message":"invalid table name:  Could not find table/view X","parameter":0,"expected":""}`
	if encoded != want {
		t.Fatalf("error JSON = %s; want %s", encoded, want)
	}
	if !strings.Contains(string(parameterError(2, expectScale, "1.234").encoded()), `"parameter":2,"expected":"scale"`) {
		t.Fatal("parameter errors lost their position or expectation")
	}
}

func TestEnvelopeAlwaysCarriesSessionLost(t *testing.T) {
	envelopes := map[string]*resultEnvelope{
		"affected rows": affectedRowsEnvelope(3),
		"zero value":    {},
		"no rows":       tabularEnvelope([]columnInfo{column("INTEGER")}),
		"plan":          planEnvelope(nil),
	}
	for label, envelope := range envelopes {
		if raw := string(decodeEnvelope(t, envelope)["sessionLost"]); raw != "false" {
			t.Fatalf("%s: sessionLost = %q; want false", label, raw)
		}
		envelope.sessionLost = true
		if raw := string(decodeEnvelope(t, envelope)["sessionLost"]); raw != "true" {
			t.Fatalf("%s: sessionLost = %q; want true", label, raw)
		}
	}
}
