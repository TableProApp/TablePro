package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"testing"
	"time"

	"github.com/TableProApp/TablePro/Native/HanaBridge/internal/frame"
	"github.com/TableProApp/TablePro/Native/HanaBridge/internal/hana"
)

const replyTimeout = 5 * time.Second

type backendCall struct {
	name      string
	session   uint64
	operation uint64
	request   string
}

type fakeBackend struct {
	calls         chan backendCall
	openedSession uint64
	openFailure   []byte
	result        []byte
	failure       []byte
	executeGate   chan struct{}
}

func newFakeBackend() *fakeBackend {
	return &fakeBackend{calls: make(chan backendCall, 64), result: []byte(`{"answer":42}`)}
}

func (f *fakeBackend) record(call backendCall) {
	f.calls <- call
}

func (f *fakeBackend) Open(configJSON []byte) (uint64, []byte) {
	f.record(backendCall{name: "open", request: string(configJSON)})
	return f.openedSession, f.openFailure
}

func (f *fakeBackend) Connect(sessionID uint64, operationID uint64) ([]byte, []byte) {
	f.record(backendCall{name: "connect", session: sessionID, operation: operationID})
	return f.result, f.failure
}

func (f *fakeBackend) Execute(sessionID uint64, operationID uint64, requestJSON []byte) ([]byte, []byte) {
	f.record(backendCall{name: "execute", session: sessionID, operation: operationID, request: string(requestJSON)})
	if f.executeGate != nil {
		<-f.executeGate
	}
	return f.result, f.failure
}

func (f *fakeBackend) Explain(sessionID uint64, operationID uint64, requestJSON []byte) ([]byte, []byte) {
	f.record(backendCall{name: "explain", session: sessionID, operation: operationID, request: string(requestJSON)})
	return f.result, f.failure
}

func (f *fakeBackend) Ping(sessionID uint64, operationID uint64) []byte {
	f.record(backendCall{name: "ping", session: sessionID, operation: operationID})
	return f.failure
}

func (f *fakeBackend) Cancel(sessionID uint64, operationID uint64) {
	f.record(backendCall{name: "cancel", session: sessionID, operation: operationID})
}

func (f *fakeBackend) Close(sessionID uint64) {
	f.record(backendCall{name: "close", session: sessionID})
}

func (f *fakeBackend) CloseAll() {
	f.record(backendCall{name: "closeAll"})
}

func (f *fakeBackend) awaitCall(t *testing.T, name string) backendCall {
	t.Helper()
	select {
	case call := <-f.calls:
		if call.name != name {
			t.Fatalf("backend call = %+v; want %s", call, name)
		}
		return call
	case <-time.After(replyTimeout):
		t.Fatalf("the backend never received %s", name)
		return backendCall{}
	}
}

type harness struct {
	t      *testing.T
	input  *io.PipeWriter
	output *io.PipeReader
	exit   chan int
}

func startServer(t *testing.T, bridge backend) *harness {
	t.Helper()
	inputReader, inputWriter := io.Pipe()
	outputReader, outputWriter := io.Pipe()
	exit := make(chan int, 1)
	go func() {
		exit <- run(inputReader, outputWriter, bridge)
	}()
	t.Cleanup(func() {
		_ = inputWriter.Close()
		_ = outputReader.Close()
	})
	h := &harness{t: t, input: inputWriter, output: outputReader, exit: exit}
	expectHello(t, h.next())
	return h
}

type helloFields struct {
	Protocol                *int   `json:"protocol"`
	ForcedSeverGraceSeconds *int64 `json:"forcedSeverGraceSeconds"`
}

func decodeHello(t *testing.T, hello frame.Frame) helloFields {
	t.Helper()
	if hello.ID != helloFrameID || hello.Code != statusOK {
		t.Fatalf("first frame = id %d status %d (%s); want the hello", hello.ID, hello.Code, hello.Body)
	}
	decoder := json.NewDecoder(bytes.NewReader(hello.Body))
	decoder.DisallowUnknownFields()
	var fields helloFields
	if err := decoder.Decode(&fields); err != nil {
		t.Fatalf("hello %s does not decode as the protocol's hello: %v", hello.Body, err)
	}
	if fields.Protocol == nil || fields.ForcedSeverGraceSeconds == nil {
		t.Fatalf("hello %s lacks protocol or forcedSeverGraceSeconds", hello.Body)
	}
	return fields
}

func expectHello(t *testing.T, hello frame.Frame) {
	t.Helper()
	fields := decodeHello(t, hello)
	if *fields.Protocol != protocolVersion {
		t.Fatalf("hello %s announces protocol %d; want %d", hello.Body, *fields.Protocol, protocolVersion)
	}
	if *fields.ForcedSeverGraceSeconds != wholeSecondsRoundedUp(hana.ForcedSeverGrace) {
		t.Fatalf("hello %s announces a %d s grace; want the bridge's %v", hello.Body, *fields.ForcedSeverGraceSeconds, hana.ForcedSeverGrace)
	}
}

func (h *harness) send(id uint64, opcode byte, body string) {
	h.t.Helper()
	if err := frame.Write(h.input, frame.Frame{ID: id, Code: opcode, Body: []byte(body)}); err != nil {
		h.t.Fatalf("sending frame %d: %v", id, err)
	}
}

func (h *harness) next() frame.Frame {
	h.t.Helper()
	type readResult struct {
		frame frame.Frame
		err   error
	}
	result := make(chan readResult, 1)
	go func() {
		incoming, err := frame.Read(h.output, frame.MaxBodyLength)
		result <- readResult{frame: incoming, err: err}
	}()
	select {
	case got := <-result:
		if got.err != nil {
			h.t.Fatalf("reading a reply: %v", got.err)
		}
		return got.frame
	case <-time.After(replyTimeout):
		h.t.Fatal("no reply arrived")
		return frame.Frame{}
	}
}

func (h *harness) expectReply(id uint64, status byte) frame.Frame {
	h.t.Helper()
	reply := h.next()
	if reply.ID != id || reply.Code != status {
		h.t.Fatalf("reply = id %d status %d (%s); want id %d status %d", reply.ID, reply.Code, reply.Body, id, status)
	}
	return reply
}

func (h *harness) expectFailure(id uint64, kind string) map[string]any {
	h.t.Helper()
	reply := h.expectReply(id, statusError)
	var failure map[string]any
	if err := json.Unmarshal(reply.Body, &failure); err != nil {
		h.t.Fatalf("failure %q is not JSON: %v", reply.Body, err)
	}
	if failure["kind"] != kind {
		h.t.Fatalf("failure = %s; want kind %q", reply.Body, kind)
	}
	return failure
}

func (h *harness) sendExpectingInternalFailure(id uint64, opcode byte, body string) map[string]any {
	h.t.Helper()
	h.send(id, opcode, body)
	return h.expectFailure(id, "internal")
}

func (h *harness) closeInput() {
	h.t.Helper()
	if err := h.input.Close(); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) awaitExit() int {
	h.t.Helper()
	select {
	case code := <-h.exit:
		return code
	case <-time.After(replyTimeout):
		h.t.Fatal("the server did not stop")
		return -1
	}
}

func TestHelloAdvertisesTheProtocolAndTheForcedSeverGrace(t *testing.T) {
	inputReader, inputWriter := io.Pipe()
	outputReader, outputWriter := io.Pipe()
	t.Cleanup(func() {
		_ = inputWriter.Close()
		_ = outputReader.Close()
	})
	go run(inputReader, outputWriter, newFakeBackend())
	h := &harness{t: t, input: inputWriter, output: outputReader}
	fields := decodeHello(t, h.next())
	if *fields.Protocol != 1 {
		t.Fatalf("protocol = %d; want 1", *fields.Protocol)
	}
	advertised := time.Duration(*fields.ForcedSeverGraceSeconds) * time.Second
	if advertised < hana.ForcedSeverGrace || advertised >= hana.ForcedSeverGrace+time.Second {
		t.Fatalf("forcedSeverGraceSeconds = %d; want %v rounded up to a whole second", *fields.ForcedSeverGraceSeconds, hana.ForcedSeverGrace)
	}
}

func TestGraceSecondsRoundUpSoTheHostNeverStopsTheHelperEarly(t *testing.T) {
	cases := map[time.Duration]int64{
		0:                                     0,
		30 * time.Second:                      30,
		30*time.Second + time.Millisecond:     31,
		29*time.Second + 999*time.Millisecond: 30,
	}
	for duration, want := range cases {
		if got := wholeSecondsRoundedUp(duration); got != want {
			t.Fatalf("wholeSecondsRoundedUp(%v) = %d; want %d", duration, got, want)
		}
	}
}

func TestHelloIsTheFirstFrameAndEOFExitsZero(t *testing.T) {
	bridge := newFakeBackend()
	h := startServer(t, bridge)
	h.closeInput()
	if code := h.awaitExit(); code != exitInputClosed {
		t.Fatalf("exit = %d; want %d", code, exitInputClosed)
	}
	bridge.awaitCall(t, "closeAll")
}

func TestOpenPassesTheConfigThroughAndAnswersTheSession(t *testing.T) {
	bridge := newFakeBackend()
	bridge.openedSession = 7
	h := startServer(t, bridge)
	h.send(1, opcodeOpen, `{"host":"db","password":"secret"}`)
	if call := bridge.awaitCall(t, "open"); call.request != `{"host":"db","password":"secret"}` {
		t.Fatalf("open received %q", call.request)
	}
	if reply := h.expectReply(1, statusOK); string(reply.Body) != `{"session":7}` {
		t.Fatalf("open reply = %s", reply.Body)
	}
}

func TestOpenFailureIsSentVerbatim(t *testing.T) {
	bridge := newFakeBackend()
	bridge.openFailure = []byte(`{"kind":"configuration","code":0,"position":0,"message":"host","parameter":0,"expected":""}`)
	h := startServer(t, bridge)
	h.send(2, opcodeOpen, `{}`)
	if reply := h.expectReply(2, statusError); string(reply.Body) != string(bridge.openFailure) {
		t.Fatalf("open failure = %s", reply.Body)
	}
}

func TestOperationsReachTheBackendWithTheirSessionAndOperation(t *testing.T) {
	bridge := newFakeBackend()
	h := startServer(t, bridge)

	h.send(10, opcodeConnect, `{"session":3,"operation":4}`)
	if call := bridge.awaitCall(t, "connect"); call.session != 3 || call.operation != 4 {
		t.Fatalf("connect call = %+v", call)
	}
	if reply := h.expectReply(10, statusOK); string(reply.Body) != `{"answer":42}` {
		t.Fatalf("connect reply = %s", reply.Body)
	}

	h.send(11, opcodeExecute, `{"session":3,"operation":5,"request":{"sql":"SELECT 1 FROM DUMMY","rowCap":10}}`)
	if call := bridge.awaitCall(t, "execute"); call.session != 3 || call.operation != 5 || call.request != `{"sql":"SELECT 1 FROM DUMMY","rowCap":10}` {
		t.Fatalf("execute call = %+v", call)
	}
	h.expectReply(11, statusOK)

	h.send(12, opcodeExplain, `{"session":3,"operation":6,"request":{"sql":"SELECT 1 FROM DUMMY"}}`)
	if call := bridge.awaitCall(t, "explain"); call.operation != 6 || call.request != `{"sql":"SELECT 1 FROM DUMMY"}` {
		t.Fatalf("explain call = %+v", call)
	}
	h.expectReply(12, statusOK)

	h.send(13, opcodePing, `{"session":3,"operation":7}`)
	if call := bridge.awaitCall(t, "ping"); call.operation != 7 {
		t.Fatalf("ping call = %+v", call)
	}
	if reply := h.expectReply(13, statusOK); string(reply.Body) != `{}` {
		t.Fatalf("ping reply = %s; want {}", reply.Body)
	}
}

func TestOperationFailuresAreSentVerbatim(t *testing.T) {
	bridge := newFakeBackend()
	bridge.failure = []byte(`{"kind":"closed","code":0,"position":0,"message":"","parameter":0,"expected":""}`)
	h := startServer(t, bridge)
	for id, opcode := range map[uint64]byte{20: opcodeConnect, 21: opcodeExecute, 22: opcodeExplain, 23: opcodePing} {
		h.send(id, opcode, `{"session":1,"operation":1,"request":{}}`)
		if reply := h.expectReply(id, statusError); string(reply.Body) != string(bridge.failure) {
			t.Fatalf("opcode %d failure = %s", opcode, reply.Body)
		}
		<-bridge.calls
	}
}

func TestUnknownOpcodeAnswersAnInternalError(t *testing.T) {
	h := startServer(t, newFakeBackend())
	failure := h.sendExpectingInternalFailure(30, 99, `{}`)
	if failure["message"] != "unknown opcode 99" {
		t.Fatalf("message = %v", failure["message"])
	}
	h.sendExpectingInternalFailure(31, 0, `{}`)
}

func TestMalformedBodiesAnswerAnInternalError(t *testing.T) {
	bridge := newFakeBackend()
	h := startServer(t, bridge)
	for index, opcode := range []byte{opcodeConnect, opcodeExecute, opcodeExplain, opcodePing, opcodeCancel, opcodeClose} {
		h.sendExpectingInternalFailure(uint64(40+index), opcode, `{"session":`)
		h.sendExpectingInternalFailure(uint64(50+index), opcode, ``)
		h.sendExpectingInternalFailure(uint64(60+index), opcode, `{"session":"one"}`)
	}
	select {
	case call := <-bridge.calls:
		t.Fatalf("a malformed request reached the backend: %+v", call)
	default:
	}
}

func TestCancelAndCloseRunWhileAnExecuteBlocks(t *testing.T) {
	bridge := newFakeBackend()
	bridge.executeGate = make(chan struct{})
	h := startServer(t, bridge)

	h.send(70, opcodeExecute, `{"session":1,"operation":9,"request":{"sql":"SELECT * FROM BIG"}}`)
	bridge.awaitCall(t, "execute")

	h.send(71, opcodeCancel, `{"session":1,"operation":9}`)
	if call := bridge.awaitCall(t, "cancel"); call.session != 1 || call.operation != 9 {
		t.Fatalf("cancel call = %+v", call)
	}
	h.send(72, opcodeClose, `{"session":1}`)
	if call := bridge.awaitCall(t, "close"); call.session != 1 {
		t.Fatalf("close call = %+v", call)
	}
	h.send(73, opcodePing, `{"session":2,"operation":1}`)
	bridge.awaitCall(t, "ping")
	h.expectReply(73, statusOK)

	close(bridge.executeGate)
	h.expectReply(70, statusOK)
}

func TestEOFExitsZeroWithoutWaitingForARunningOperation(t *testing.T) {
	bridge := newFakeBackend()
	bridge.executeGate = make(chan struct{})
	t.Cleanup(func() { close(bridge.executeGate) })
	h := startServer(t, bridge)
	h.send(80, opcodeExecute, `{"session":1,"operation":1,"request":{}}`)
	bridge.awaitCall(t, "execute")
	h.closeInput()
	if code := h.awaitExit(); code != exitInputClosed {
		t.Fatalf("exit = %d; want %d", code, exitInputClosed)
	}
	bridge.awaitCall(t, "closeAll")
}

func TestFramingViolationsExitThree(t *testing.T) {
	violations := map[string][]byte{
		"short header":      {0, 0, 0, 2, 0, 0},
		"short body":        append(rawHeader(8, 1, opcodePing), `{}`...),
		"body over the cap": rawHeader(maxRequestBodyLength+1, 1, opcodeExecute),
	}
	for name, data := range violations {
		t.Run(name, func(t *testing.T) {
			bridge := newFakeBackend()
			h := startServer(t, bridge)
			if _, err := h.input.Write(data); err != nil {
				t.Fatal(err)
			}
			h.closeInput()
			if code := h.awaitExit(); code != exitTransportFailure {
				t.Fatalf("exit = %d; want %d", code, exitTransportFailure)
			}
			bridge.awaitCall(t, "closeAll")
		})
	}
}

func rawHeader(length uint32, id uint64, code byte) []byte {
	header := make([]byte, frame.HeaderSize)
	binary.BigEndian.PutUint32(header[0:4], length)
	binary.BigEndian.PutUint64(header[4:12], id)
	header[12] = code
	return header
}

func TestAnInputErrorOtherThanEOFExitsThree(t *testing.T) {
	inputReader, inputWriter := io.Pipe()
	outputReader, outputWriter := io.Pipe()
	t.Cleanup(func() { _ = outputReader.Close() })
	exit := make(chan int, 1)
	go func() { exit <- run(inputReader, outputWriter, newFakeBackend()) }()
	h := &harness{t: t, input: inputWriter, output: outputReader, exit: exit}
	h.next()
	_ = inputWriter.CloseWithError(errors.New("stdin went away"))
	if code := h.awaitExit(); code != exitTransportFailure {
		t.Fatalf("exit = %d; want %d", code, exitTransportFailure)
	}
}

type failingWriter struct {
	remaining int
}

func (w *failingWriter) Write(data []byte) (int, error) {
	if w.remaining == 0 {
		return 0, io.ErrClosedPipe
	}
	w.remaining--
	return len(data), nil
}

func TestHelloThatCannotBeWrittenExitsThree(t *testing.T) {
	inputReader, inputWriter := io.Pipe()
	t.Cleanup(func() { _ = inputWriter.Close() })
	if code := run(inputReader, &failingWriter{}, newFakeBackend()); code != exitTransportFailure {
		t.Fatalf("exit = %d; want %d", code, exitTransportFailure)
	}
}

func TestReplyThatCannotBeWrittenExitsThree(t *testing.T) {
	inputReader, inputWriter := io.Pipe()
	t.Cleanup(func() { _ = inputWriter.Close() })
	bridge := newFakeBackend()
	exit := make(chan int, 1)
	go func() { exit <- run(inputReader, &failingWriter{remaining: 2}, bridge) }()
	if err := frame.Write(inputWriter, frame.Frame{ID: 1, Code: opcodeOpen, Body: []byte(`{}`)}); err != nil {
		t.Fatal(err)
	}
	select {
	case code := <-exit:
		if code != exitTransportFailure {
			t.Fatalf("exit = %d; want %d", code, exitTransportFailure)
		}
	case <-time.After(replyTimeout):
		t.Fatal("a lost reply did not stop the server")
	}
	bridge.awaitCall(t, "open")
	bridge.awaitCall(t, "closeAll")
}

func TestResultsOnlyFitAFrameUpToTwoGiBMinusOne(t *testing.T) {
	if !fitsInFrame(0) || !fitsInFrame(frame.MaxBodyLength) {
		t.Fatal("a result up to 2 GiB - 1 was refused")
	}
	if fitsInFrame(frame.MaxBodyLength+1) || fitsInFrame(math.MaxUint32) || fitsInFrame(-1) {
		t.Fatal("a result over the frame cap was accepted")
	}
	if small := replyFrame(5, []byte("{}"), nil); small.Code != statusOK || small.ID != 5 {
		t.Fatalf("a small result became %+v", small)
	}
}

func TestAResultOverTheCapAnswersAnInternalErrorAndTheServerKeepsServing(t *testing.T) {
	bridge := newFakeBackend()
	bridge.result = make([]byte, frame.MaxBodyLength+1)
	h := startServer(t, bridge)
	h.send(90, opcodeExecute, `{"session":1,"operation":1,"request":{}}`)
	bridge.awaitCall(t, "execute")
	if failure := h.expectFailure(90, "internal"); failure["message"] != "the result is larger than 2 GiB" {
		t.Fatalf("message = %v; want the oversized result message", failure["message"])
	}
	h.send(91, opcodePing, `{"session":1,"operation":2}`)
	bridge.awaitCall(t, "ping")
	h.expectReply(91, statusOK)
}

func closedPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	return port
}

func TestRealBridgeAnswersOverFrames(t *testing.T) {
	h := startServer(t, hana.NewBridge())
	config := fmt.Sprintf(`{"host":"127.0.0.1","port":%d,"username":"DBADMIN","password":"secret","tlsMode":"disabled","connectTimeoutSeconds":2}`, closedPort(t))
	h.send(1, opcodeOpen, config)
	if reply := h.expectReply(1, statusOK); string(reply.Body) != `{"session":1}` {
		t.Fatalf("open reply = %s", reply.Body)
	}
	h.send(2, opcodeConnect, `{"session":1,"operation":1}`)
	h.expectFailure(2, "connect")
	h.send(3, opcodePing, `{"session":1,"operation":2}`)
	h.expectFailure(3, "connectionLost")
	h.send(4, opcodeClose, `{"session":1}`)
	h.send(5, opcodeExecute, `{"session":1,"operation":3,"request":{"sql":"SELECT 1 FROM DUMMY"}}`)
	h.expectFailure(5, "closed")
	h.send(6, opcodeOpen, `{"host":`)
	h.expectFailure(6, "internal")
	h.closeInput()
	if code := h.awaitExit(); code != exitInputClosed {
		t.Fatalf("exit = %d; want %d", code, exitInputClosed)
	}
}
