package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"sync"
	"time"

	"github.com/TableProApp/TablePro/Native/HanaBridge/internal/frame"
	"github.com/TableProApp/TablePro/Native/HanaBridge/internal/hana"
)

const protocolVersion = 1

const (
	opcodeOpen    byte = 1
	opcodeConnect byte = 2
	opcodeExecute byte = 3
	opcodeExplain byte = 4
	opcodePing    byte = 5
	opcodeCancel  byte = 6
	opcodeClose   byte = 7
)

const (
	statusOK    byte = 0
	statusError byte = 1
)

const (
	helloFrameID           uint64 = 0
	maxRequestBodyLength   uint32 = 1 << 30
	oversizedResultMessage        = "the result is larger than 2 GiB"
)

const (
	exitInputClosed      = 0
	exitTransportFailure = 3
)

type backend interface {
	Open(configJSON []byte) (sessionID uint64, failure []byte)
	Connect(sessionID uint64, operationID uint64) (result []byte, failure []byte)
	Execute(sessionID uint64, operationID uint64, requestJSON []byte) (result []byte, failure []byte)
	Explain(sessionID uint64, operationID uint64, requestJSON []byte) (result []byte, failure []byte)
	Ping(sessionID uint64, operationID uint64) (failure []byte)
	Cancel(sessionID uint64, operationID uint64)
	Close(sessionID uint64)
	CloseAll()
}

type requestBody struct {
	Session   uint64          `json:"session"`
	Operation uint64          `json:"operation"`
	Request   json.RawMessage `json:"request"`
}

type operation func(body requestBody) (result []byte, failure []byte)

type server struct {
	backend  backend
	output   io.Writer
	writeMu  sync.Mutex
	finished chan error
}

func run(input io.Reader, output io.Writer, bridge backend) int {
	s := &server{backend: bridge, output: output, finished: make(chan error, 1)}
	if err := s.write(frame.Frame{ID: helloFrameID, Code: statusOK, Body: helloBody()}); err != nil {
		return exitTransportFailure
	}
	go s.readRequests(input)
	failure := <-s.finished
	bridge.CloseAll()
	if failure != nil {
		return exitTransportFailure
	}
	return exitInputClosed
}

func (s *server) readRequests(input io.Reader) {
	for {
		request, err := frame.Read(input, maxRequestBodyLength)
		if errors.Is(err, io.EOF) {
			s.finish(nil)
			return
		}
		if err != nil {
			s.finish(err)
			return
		}
		s.dispatch(request)
	}
}

func (s *server) finish(err error) {
	select {
	case s.finished <- err:
	default:
	}
}

func (s *server) dispatch(request frame.Frame) {
	switch request.Code {
	case opcodeOpen:
		s.openSession(request)
	case opcodeConnect:
		s.start(request, s.connect)
	case opcodeExecute:
		s.start(request, s.execute)
	case opcodeExplain:
		s.start(request, s.explain)
	case opcodePing:
		s.start(request, s.ping)
	case opcodeCancel:
		s.cancelOperation(request)
	case opcodeClose:
		s.closeSession(request)
	default:
		s.reply(request.ID, nil, hana.InternalFailure(fmt.Sprintf("unknown opcode %d", request.Code)))
	}
}

func (s *server) openSession(request frame.Frame) {
	sessionID, failure := s.backend.Open(request.Body)
	if failure != nil {
		s.reply(request.ID, nil, failure)
		return
	}
	s.reply(request.ID, openedBody(sessionID), nil)
}

func (s *server) start(request frame.Frame, perform operation) {
	body, failure := decodeRequestBody(request.Body)
	if failure != nil {
		s.reply(request.ID, nil, failure)
		return
	}
	go func() {
		result, failure := perform(body)
		s.reply(request.ID, result, failure)
	}()
}

func (s *server) connect(body requestBody) ([]byte, []byte) {
	return s.backend.Connect(body.Session, body.Operation)
}

func (s *server) execute(body requestBody) ([]byte, []byte) {
	return s.backend.Execute(body.Session, body.Operation, body.Request)
}

func (s *server) explain(body requestBody) ([]byte, []byte) {
	return s.backend.Explain(body.Session, body.Operation, body.Request)
}

func (s *server) ping(body requestBody) ([]byte, []byte) {
	if failure := s.backend.Ping(body.Session, body.Operation); failure != nil {
		return nil, failure
	}
	return []byte("{}"), nil
}

func (s *server) cancelOperation(request frame.Frame) {
	body, failure := decodeRequestBody(request.Body)
	if failure != nil {
		s.reply(request.ID, nil, failure)
		return
	}
	s.backend.Cancel(body.Session, body.Operation)
}

func (s *server) closeSession(request frame.Frame) {
	body, failure := decodeRequestBody(request.Body)
	if failure != nil {
		s.reply(request.ID, nil, failure)
		return
	}
	s.backend.Close(body.Session)
}

func (s *server) reply(id uint64, result []byte, failure []byte) {
	if err := s.write(replyFrame(id, result, failure)); err != nil {
		s.finish(err)
	}
}

func (s *server) write(outgoing frame.Frame) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return frame.Write(s.output, outgoing)
}

func replyFrame(id uint64, result []byte, failure []byte) frame.Frame {
	if failure != nil {
		return frame.Frame{ID: id, Code: statusError, Body: failure}
	}
	if !fitsInFrame(len(result)) {
		return frame.Frame{ID: id, Code: statusError, Body: hana.InternalFailure(oversizedResultMessage)}
	}
	return frame.Frame{ID: id, Code: statusOK, Body: result}
}

func fitsInFrame(length int) bool {
	return length >= 0 && uint64(length) <= frame.MaxBodyLength
}

func decodeRequestBody(data []byte) (requestBody, []byte) {
	var body requestBody
	if err := json.Unmarshal(data, &body); err != nil {
		return requestBody{}, hana.InternalFailure(err.Error())
	}
	return body, nil
}

func helloBody() []byte {
	return fmt.Appendf(nil, `{"protocol":%d,"forcedSeverGraceSeconds":%d}`, protocolVersion, wholeSecondsRoundedUp(hana.ForcedSeverGrace))
}

func wholeSecondsRoundedUp(duration time.Duration) int64 {
	return int64(math.Ceil(duration.Seconds()))
}

func openedBody(sessionID uint64) []byte {
	return fmt.Appendf(nil, `{"session":%d}`, sessionID)
}
