package hana

import (
	"database/sql"
	"errors"
	"io"
	"strings"
	"testing"
)

var (
	_ io.Writer   = (*lobCell)(nil)
	_ sql.Scanner = (*lobCell)(nil)
)

func TestLobCellKeepsEverythingUnderTheLimit(t *testing.T) {
	lob := newLobCell(16, nil)
	for _, chunk := range []string{"hello ", "world"} {
		written, err := lob.Write([]byte(chunk))
		if err != nil || written != len(chunk) {
			t.Fatalf("Write(%q) = %d, %v", chunk, written, err)
		}
	}
	if lob.truncated || lob.null {
		t.Fatalf("truncated=%v null=%v under the limit", lob.truncated, lob.null)
	}
	assertText(t, lob.cell(column("NCLOB")), "hello world")
}

func TestLobCellCutsAtTheLimitAndKeepsConsumingTheStream(t *testing.T) {
	lob := newLobCell(8, nil)
	for _, chunk := range []string{"12345", "67890", "abcdef"} {
		written, err := lob.Write([]byte(chunk))
		if err != nil || written != len(chunk) {
			t.Fatalf("Write(%q) = %d, %v; a capped cell must accept the whole stream", chunk, written, err)
		}
	}
	if !lob.truncated || string(lob.data) != "12345678" {
		t.Fatalf("data=%q truncated=%v; want the first 8 bytes and the truncation flag", lob.data, lob.truncated)
	}
	binary := lob.cell(column("BLOB"))
	if binary.kind != cellBytes || string(binary.bytes) != "12345678" {
		t.Fatalf("BLOB cell = %+v", binary)
	}
}

func TestTruncatedTextLobEndsOnARuneBoundary(t *testing.T) {
	lob := newLobCell(len("ab")+2, nil)
	if _, err := lob.Write([]byte("ab😀cd")); err != nil {
		t.Fatal(err)
	}
	assertText(t, lob.cell(column("NCLOB")), "ab")
}

func TestLobCellScansNullAsNull(t *testing.T) {
	lob := newLobCell(lobCellLimit, nil)
	if err := lob.Scan(nil); err != nil {
		t.Fatal(err)
	}
	if got := lob.cell(column("NCLOB")); got.kind != cellNull {
		t.Fatalf("NULL LOB became %+v", got)
	}
}

func TestLobCellAcceptsInlineValues(t *testing.T) {
	lob := newLobCell(lobCellLimit, nil)
	if err := lob.Scan([]byte("inline")); err != nil {
		t.Fatal(err)
	}
	assertText(t, lob.cell(column("CLOB")), "inline")
	other := newLobCell(lobCellLimit, nil)
	if err := other.Scan(42); err == nil {
		t.Fatal("an unexpected LOB source was accepted")
	}
}

func TestEmptyLobIsNotNull(t *testing.T) {
	lob := newLobCell(lobCellLimit, nil)
	assertText(t, lob.cell(column("NCLOB")), "")
	binary := newLobCell(lobCellLimit, nil).cell(column("BLOB"))
	if binary.kind != cellBytes || len(binary.bytes) != 0 {
		t.Fatalf("empty BLOB became %+v", binary)
	}
}

func TestStoppedOperationAbortsALobRead(t *testing.T) {
	stopped := false
	lob := newLobCell(lobCellLimit, func() bool { return stopped })
	if _, err := lob.Write([]byte("first chunk")); err != nil {
		t.Fatal(err)
	}
	stopped = true
	if _, err := lob.Write([]byte("second chunk")); !errors.Is(err, errOperationStopped) {
		t.Fatalf("Write after stop = %v; want errOperationStopped", err)
	}
}

func TestLobLimitIsSixtyFourMebibytes(t *testing.T) {
	if lobCellLimit != 64*1024*1024 {
		t.Fatalf("lobCellLimit = %d", lobCellLimit)
	}
	lob := newLobCell(lobCellLimit, nil)
	chunk := []byte(strings.Repeat("x", 1<<20))
	for range 65 {
		if _, err := lob.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	if !lob.truncated || len(lob.data) != lobCellLimit {
		t.Fatalf("65 MiB kept %d bytes, truncated=%v", len(lob.data), lob.truncated)
	}
}
