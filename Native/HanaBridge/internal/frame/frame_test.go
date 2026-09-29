package frame

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"testing"
)

var errBrokenStream = errors.New("broken stream")

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) {
	return 0, errBrokenStream
}

type failingWriter struct {
	failAfter int
	writes    int
}

func (w *failingWriter) Write(data []byte) (int, error) {
	if w.writes >= w.failAfter {
		return 0, errBrokenStream
	}
	w.writes++
	return len(data), nil
}

func encoded(t *testing.T, outgoing Frame) []byte {
	t.Helper()
	var buffer bytes.Buffer
	if err := Write(&buffer, outgoing); err != nil {
		t.Fatalf("Write: %v", err)
	}
	return buffer.Bytes()
}

func headerBytes(length uint32, id uint64, code byte) []byte {
	encoded, err := encodeHeader(id, code, int(length))
	if err != nil {
		panic(err)
	}
	return encoded[:]
}

func TestHeaderIsLengthThenIDThenCodeInBigEndian(t *testing.T) {
	got := encoded(t, Frame{ID: 0x0102030405060708, Code: 3, Body: []byte(`{"a":1}`)})
	want := append([]byte{0, 0, 0, 7, 1, 2, 3, 4, 5, 6, 7, 8, 3}, `{"a":1}`...)
	if !bytes.Equal(got, want) {
		t.Fatalf("encoded = % x; want % x", got, want)
	}
}

func TestFrameRoundTrips(t *testing.T) {
	outgoing := Frame{ID: 42, Code: 1, Body: []byte(`{"host":"db.example.com"}`)}
	incoming, err := Read(bytes.NewReader(encoded(t, outgoing)), MaxBodyLength)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if incoming.ID != outgoing.ID || incoming.Code != outgoing.Code || !bytes.Equal(incoming.Body, outgoing.Body) {
		t.Fatalf("read %+v; want %+v", incoming, outgoing)
	}
}

func TestMaximumIDRoundTrips(t *testing.T) {
	data := encoded(t, Frame{ID: math.MaxUint64, Code: 255})
	if !bytes.Equal(data[4:12], bytes.Repeat([]byte{0xFF}, 8)) {
		t.Fatalf("id bytes = % x; want all ones", data[4:12])
	}
	incoming, err := Read(bytes.NewReader(data), MaxBodyLength)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if incoming.ID != math.MaxUint64 || incoming.Code != 255 {
		t.Fatalf("read id %d code %d; want the maximum of each", incoming.ID, incoming.Code)
	}
}

func TestEmptyBodyIsTheHeaderAlone(t *testing.T) {
	data := encoded(t, Frame{ID: 9, Code: 6})
	if len(data) != HeaderSize {
		t.Fatalf("an empty frame took %d bytes; want %d", len(data), HeaderSize)
	}
	incoming, err := Read(bytes.NewReader(data), MaxBodyLength)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if incoming.ID != 9 || incoming.Code != 6 || len(incoming.Body) != 0 {
		t.Fatalf("read %+v; want id 9, code 6 and no body", incoming)
	}
}

func TestConsecutiveFramesReadInOrder(t *testing.T) {
	var stream []byte
	for id := uint64(1); id <= 3; id++ {
		stream = append(stream, encoded(t, Frame{ID: id, Code: byte(id), Body: bytes.Repeat([]byte{'x'}, int(id))})...)
	}
	input := bytes.NewReader(stream)
	for id := uint64(1); id <= 3; id++ {
		incoming, err := Read(input, MaxBodyLength)
		if err != nil {
			t.Fatalf("frame %d: %v", id, err)
		}
		if incoming.ID != id || len(incoming.Body) != int(id) {
			t.Fatalf("frame %d read as %+v", id, incoming)
		}
	}
	if _, err := Read(input, MaxBodyLength); !errors.Is(err, io.EOF) {
		t.Fatalf("after the last frame err = %v; want io.EOF", err)
	}
}

func TestStreamEndingBetweenFramesIsEOF(t *testing.T) {
	if _, err := Read(bytes.NewReader(nil), MaxBodyLength); !errors.Is(err, io.EOF) {
		t.Fatalf("err = %v; want io.EOF", err)
	}
}

func TestStreamEndingInsideTheHeaderIsAShortHeader(t *testing.T) {
	for length := 1; length < HeaderSize; length++ {
		partial := headerBytes(0, 1, 1)[:length]
		if _, err := Read(bytes.NewReader(partial), MaxBodyLength); !errors.Is(err, ErrShortHeader) {
			t.Fatalf("%d header bytes: err = %v; want ErrShortHeader", length, err)
		}
	}
}

func TestStreamEndingInsideTheBodyIsAShortBody(t *testing.T) {
	truncated := append(headerBytes(10, 1, 3), "four"...)
	if _, err := Read(bytes.NewReader(truncated), MaxBodyLength); !errors.Is(err, ErrShortBody) {
		t.Fatalf("err = %v; want ErrShortBody", err)
	}
	if _, err := Read(bytes.NewReader(headerBytes(10, 1, 3)), MaxBodyLength); !errors.Is(err, ErrShortBody) {
		t.Fatalf("a header with no body: err = %v; want ErrShortBody", err)
	}
}

func TestBodyOverTheLimitIsRefusedBeforeItIsRead(t *testing.T) {
	const limit = 16
	input := bytes.NewReader(append(headerBytes(limit+1, 1, 3), bytes.Repeat([]byte{'x'}, limit+1)...))
	if _, err := Read(input, limit); !errors.Is(err, ErrBodyTooLarge) {
		t.Fatalf("err = %v; want ErrBodyTooLarge", err)
	}
	if unread := input.Len(); unread != limit+1 {
		t.Fatalf("%d body bytes left unread; want all %d", unread, limit+1)
	}
}

func TestBodyAtTheLimitIsAccepted(t *testing.T) {
	const limit = 16
	body := bytes.Repeat([]byte{'x'}, limit)
	incoming, err := Read(bytes.NewReader(encoded(t, Frame{ID: 1, Code: 3, Body: body})), limit)
	if err != nil || !bytes.Equal(incoming.Body, body) {
		t.Fatalf("read %q, %v; want the whole body", incoming.Body, err)
	}
}

func TestTheCapIsTwoGiBMinusOne(t *testing.T) {
	if MaxBodyLength != 1<<31-1 {
		t.Fatalf("MaxBodyLength = %d; want 2^31-1, the cap both ends of the pipe share", MaxBodyLength)
	}
}

func TestHeaderRefusesALengthOverTheCap(t *testing.T) {
	if _, err := encodeHeader(1, 0, MaxBodyLength+1); !errors.Is(err, ErrBodyTooLarge) {
		t.Fatalf("length 2^31: err = %v; want ErrBodyTooLarge", err)
	}
	if _, err := encodeHeader(1, 0, math.MaxUint32); !errors.Is(err, ErrBodyTooLarge) {
		t.Fatalf("length 2^32-1: err = %v; want ErrBodyTooLarge", err)
	}
	if _, err := encodeHeader(1, 0, -1); !errors.Is(err, ErrBodyTooLarge) {
		t.Fatalf("length -1: err = %v; want ErrBodyTooLarge", err)
	}
	encoded, err := encodeHeader(1, 0, MaxBodyLength)
	if err != nil {
		t.Fatalf("length 2^31-1: %v", err)
	}
	if decoded := decodeHeader(encoded); decoded.length != MaxBodyLength {
		t.Fatalf("length decoded as %d; want %d", decoded.length, MaxBodyLength)
	}
}

func TestWriteRefusesABodyOverTheCapBeforeWritingAnything(t *testing.T) {
	var output bytes.Buffer
	err := Write(&output, Frame{ID: 1, Body: make([]byte, MaxBodyLength+1)})
	if !errors.Is(err, ErrBodyTooLarge) {
		t.Fatalf("err = %v; want ErrBodyTooLarge", err)
	}
	if output.Len() != 0 {
		t.Fatalf("wrote %d bytes; want nothing", output.Len())
	}
}

func TestReadRefusesAHeaderOverTheCapBeforeReadingTheBody(t *testing.T) {
	for _, length := range []uint32{MaxBodyLength + 1, math.MaxUint32} {
		header := make([]byte, HeaderSize)
		binary.BigEndian.PutUint32(header[0:4], length)
		binary.BigEndian.PutUint64(header[4:12], 1)
		input := bytes.NewReader(append(header, "body"...))
		if _, err := Read(input, MaxBodyLength); !errors.Is(err, ErrBodyTooLarge) {
			t.Fatalf("length %d: err = %v; want ErrBodyTooLarge", length, err)
		}
		if unread := input.Len(); unread != len("body") {
			t.Fatalf("length %d: %d body bytes left unread; want all %d", length, unread, len("body"))
		}
	}
}

func TestReadErrorsOtherThanEOFPassThrough(t *testing.T) {
	if _, err := Read(failingReader{}, MaxBodyLength); !errors.Is(err, errBrokenStream) {
		t.Fatalf("err = %v; want the reader's own error", err)
	}
	body := io.MultiReader(bytes.NewReader(headerBytes(4, 1, 3)), failingReader{})
	if _, err := Read(body, MaxBodyLength); !errors.Is(err, errBrokenStream) {
		t.Fatalf("body read err = %v; want the reader's own error", err)
	}
}

func TestWriteErrorsPassThrough(t *testing.T) {
	if err := Write(&failingWriter{failAfter: 0}, Frame{ID: 1, Body: []byte("{}")}); !errors.Is(err, errBrokenStream) {
		t.Fatalf("header write err = %v; want the writer's own error", err)
	}
	if err := Write(&failingWriter{failAfter: 1}, Frame{ID: 1, Body: []byte("{}")}); !errors.Is(err, errBrokenStream) {
		t.Fatalf("body write err = %v; want the writer's own error", err)
	}
	if err := Write(&failingWriter{failAfter: 1}, Frame{ID: 1}); err != nil {
		t.Fatalf("an empty body wrote more than its header: %v", err)
	}
}
