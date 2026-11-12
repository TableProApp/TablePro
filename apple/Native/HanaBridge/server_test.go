package main

import (
	"encoding/json"
	"io"
	"slices"
	"sync"
	"testing"

	"github.com/TableProApp/TablePro/Native/HanaBridge/internal/frame"
)

type recordedCall struct {
	name      string
	session   uint64
	operation uint64
	request   string
}

type recordingBackend struct {
	mu    sync.Mutex
	calls []recordedCall
}

func (b *recordingBackend) record(call recordedCall) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.calls = append(b.calls, call)
}

func (b *recordingBackend) recorded() []recordedCall {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]recordedCall(nil), b.calls...)
}

func (b *recordingBackend) Open([]byte) (uint64, []byte) {
	return 1, nil
}

func (b *recordingBackend) Connect(uint64, uint64) ([]byte, []byte) {
	return []byte("{}"), nil
}

func (b *recordingBackend) Execute(uint64, uint64, []byte) ([]byte, []byte) {
	return []byte("{}"), nil
}

func (b *recordingBackend) Explain(uint64, uint64, []byte) ([]byte, []byte) {
	return []byte("{}"), nil
}

func (b *recordingBackend) OpenCursor(sessionID uint64, operationID uint64, requestJSON []byte) ([]byte, []byte) {
	b.record(recordedCall{name: "openCursor", session: sessionID, operation: operationID, request: string(requestJSON)})
	return []byte(`{"done":false}`), nil
}

func (b *recordingBackend) Fetch(sessionID uint64, operationID uint64) ([]byte, []byte) {
	b.record(recordedCall{name: "fetch", session: sessionID, operation: operationID})
	return []byte(`{"done":true}`), nil
}

func (b *recordingBackend) CloseCursor(sessionID uint64, operationID uint64) ([]byte, []byte) {
	b.record(recordedCall{name: "closeCursor", session: sessionID, operation: operationID})
	return nil, []byte(`{"kind":"internal","message":"no cursor"}`)
}

func (b *recordingBackend) Ping(uint64, uint64) []byte {
	return nil
}

func (b *recordingBackend) Cancel(uint64, uint64) {}

func (b *recordingBackend) Close(uint64) {}

func (b *recordingBackend) CloseAll() {}

func readReply(t *testing.T, replies io.Reader) frame.Frame {
	t.Helper()
	reply, err := frame.Read(replies, frame.MaxBodyLength)
	if err != nil {
		t.Fatalf("reading a reply failed: %v", err)
	}
	return reply
}

func exchange(t *testing.T, requests io.Writer, replies io.Reader, request frame.Frame) frame.Frame {
	t.Helper()
	if err := frame.Write(requests, request); err != nil {
		t.Fatalf("writing frame %d failed: %v", request.ID, err)
	}
	reply := readReply(t, replies)
	if reply.ID != request.ID {
		t.Fatalf("the reply answers frame %d, want %d", reply.ID, request.ID)
	}
	return reply
}

func TestServerRoutesCursorOperationsAndAnnouncesProtocolTwo(t *testing.T) {
	requestReader, requests := io.Pipe()
	replies, replyWriter := io.Pipe()
	backend := &recordingBackend{}
	exited := make(chan int, 1)
	go func() {
		exited <- run(requestReader, replyWriter, backend)
		_ = replyWriter.Close()
	}()

	var greeting struct {
		Protocol int `json:"protocol"`
	}
	if err := json.Unmarshal(readReply(t, replies).Body, &greeting); err != nil || greeting.Protocol != 2 {
		t.Fatalf("the greeting names protocol %d (%v), want 2", greeting.Protocol, err)
	}

	opened := exchange(t, requests, replies, frame.Frame{ID: 1, Code: opcodeOpenCursor, Body: []byte(
		`{"session":4,"operation":9,"request":{"sql":"SELECT 1","batchRows":5}}`,
	)})
	fetched := exchange(t, requests, replies, frame.Frame{ID: 2, Code: opcodeFetch, Body: []byte(`{"session":4,"operation":9}`)})
	closed := exchange(t, requests, replies, frame.Frame{ID: 3, Code: opcodeCloseCursor, Body: []byte(`{"session":4,"operation":9}`)})
	_ = requests.Close()

	if opened.Code != statusOK || string(opened.Body) != `{"done":false}` {
		t.Fatalf("open answered %d %s", opened.Code, opened.Body)
	}
	if fetched.Code != statusOK || string(fetched.Body) != `{"done":true}` {
		t.Fatalf("fetch answered %d %s", fetched.Code, fetched.Body)
	}
	if closed.Code != statusError {
		t.Fatalf("a refused close answered status %d", closed.Code)
	}
	if code := <-exited; code != exitInputClosed {
		t.Fatalf("the server exited with %d", code)
	}
	want := []recordedCall{
		{name: "openCursor", session: 4, operation: 9, request: `{"sql":"SELECT 1","batchRows":5}`},
		{name: "fetch", session: 4, operation: 9},
		{name: "closeCursor", session: 4, operation: 9},
	}
	if got := backend.recorded(); !slices.Equal(got, want) {
		t.Fatalf("the backend saw %+v, want %+v", got, want)
	}
}
