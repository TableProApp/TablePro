package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/TableProApp/TablePro/Native/HanaBridge/internal/frame"
)

const (
	childBackendVariable = "TABLEPRO_HANA_HELPER_TEST_BACKEND"
	blockingChild        = "blocking"
	panickingChild       = "panicking"
	panickingCallChild   = "panicking-call"
	childPanicMessage    = "go-hdb worker goroutine panicked"
	childTimeout         = 20 * time.Second
)

func TestMain(m *testing.M) {
	if name := os.Getenv(childBackendVariable); name != "" {
		os.Exit(run(os.Stdin, os.Stdout, childBackend(name)))
	}
	os.Exit(m.Run())
}

func childBackend(name string) backend {
	switch name {
	case panickingChild:
		return panickingBackend{}
	case panickingCallChild:
		return panickingCallBackend{}
	default:
		return &blockingBackend{running: make(chan struct{})}
	}
}

type idleBackend struct{}

func (idleBackend) Open([]byte) (uint64, []byte)                    { return 1, nil }
func (idleBackend) Connect(uint64, uint64) ([]byte, []byte)         { return []byte("{}"), nil }
func (idleBackend) Execute(uint64, uint64, []byte) ([]byte, []byte) { return []byte("{}"), nil }
func (idleBackend) Explain(uint64, uint64, []byte) ([]byte, []byte) { return []byte("{}"), nil }
func (idleBackend) Ping(uint64, uint64) []byte                      { return nil }
func (idleBackend) Cancel(uint64, uint64)                           {}
func (idleBackend) Close(uint64)                                    {}
func (idleBackend) CloseAll()                                       {}

type blockingBackend struct {
	idleBackend
	running chan struct{}
	started sync.Once
}

func (b *blockingBackend) Execute(uint64, uint64, []byte) ([]byte, []byte) {
	b.started.Do(func() { close(b.running) })
	blockForever()
	return nil, nil
}

func (b *blockingBackend) Ping(uint64, uint64) []byte {
	<-b.running
	return nil
}

type panickingBackend struct {
	idleBackend
}

func (panickingBackend) Execute(uint64, uint64, []byte) ([]byte, []byte) {
	go func() {
		panic(childPanicMessage)
	}()
	blockForever()
	return nil, nil
}

type panickingCallBackend struct {
	idleBackend
}

func (panickingCallBackend) Execute(uint64, uint64, []byte) ([]byte, []byte) {
	panic(childPanicMessage)
}

func blockForever() {
	select {}
}

type lockedBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (b *lockedBuffer) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.Write(data)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.String()
}

type childProcess struct {
	t       *testing.T
	command *exec.Cmd
	stdin   io.WriteCloser
	stdout  io.ReadCloser
	stderr  *lockedBuffer
}

func startChild(t *testing.T, backendName string) *childProcess {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), childTimeout)
	t.Cleanup(cancel)
	command := exec.CommandContext(ctx, os.Args[0])
	command.Env = append(os.Environ(), childBackendVariable+"="+backendName)
	command.WaitDelay = time.Second
	stderr := &lockedBuffer{}
	command.Stderr = stderr
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	child := &childProcess{t: t, command: command, stdin: stdin, stdout: stdout, stderr: stderr}
	expectHello(t, child.next())
	return child
}

func (c *childProcess) send(id uint64, opcode byte, body string) {
	c.t.Helper()
	if err := frame.Write(c.stdin, frame.Frame{ID: id, Code: opcode, Body: []byte(body)}); err != nil {
		c.t.Fatalf("sending frame %d: %v", id, err)
	}
}

func (c *childProcess) next() frame.Frame {
	c.t.Helper()
	incoming, err := frame.Read(c.stdout, frame.MaxBodyLength)
	if err != nil {
		c.t.Fatalf("reading from the helper: %v (stderr %q)", err, c.stderr.String())
	}
	return incoming
}

func (c *childProcess) closeStdin() {
	c.t.Helper()
	if err := c.stdin.Close(); err != nil {
		c.t.Fatal(err)
	}
}

func (c *childProcess) awaitExit() (code int, remainingOutput []byte) {
	c.t.Helper()
	remaining, err := io.ReadAll(c.stdout)
	if err != nil {
		c.t.Fatalf("draining the helper's output: %v", err)
	}
	err = c.command.Wait()
	var exitError *exec.ExitError
	if err != nil && !errors.As(err, &exitError) {
		c.t.Fatalf("waiting for the helper: %v", err)
	}
	return c.command.ProcessState.ExitCode(), remaining
}

func TestProcessExitsZeroOnEOFWhileAnOperationRuns(t *testing.T) {
	child := startChild(t, blockingChild)
	child.send(1, opcodeExecute, `{"session":1,"operation":1,"request":{}}`)
	child.send(2, opcodePing, `{"session":1,"operation":2}`)
	if reply := child.next(); reply.ID != 2 || reply.Code != statusOK {
		t.Fatalf("reply = %+v; want the ping that proves the execute is running", reply)
	}
	child.closeStdin()
	code, remaining := child.awaitExit()
	if code != exitInputClosed {
		t.Fatalf("exit = %d; want %d (stderr %q)", code, exitInputClosed, child.stderr.String())
	}
	if len(remaining) != 0 {
		t.Fatalf("the helper wrote %q after stdin closed; want nothing", remaining)
	}
	if child.stderr.String() != "" {
		t.Fatalf("stderr = %q; want nothing", child.stderr.String())
	}
}

func TestProcessExitsTwoWhenABackendGoroutinePanics(t *testing.T) {
	for _, backendName := range []string{panickingChild, panickingCallChild} {
		t.Run(backendName, func(t *testing.T) {
			child := startChild(t, backendName)
			child.send(1, opcodeExecute, `{"session":1,"operation":1,"request":{}}`)
			code, remaining := child.awaitExit()
			if code != 2 {
				t.Fatalf("exit = %d; want 2 (stderr %q)", code, child.stderr.String())
			}
			if len(remaining) != 0 {
				t.Fatalf("the helper answered %q before it died; want nothing", remaining)
			}
			if trace := child.stderr.String(); !strings.Contains(trace, "panic: "+childPanicMessage) || !strings.Contains(trace, "goroutine ") {
				t.Fatalf("stderr = %q; want the panic and its goroutine trace", trace)
			}
		})
	}
}

func TestProcessExitsThreeOnAFramingViolation(t *testing.T) {
	child := startChild(t, blockingChild)
	if _, err := child.stdin.Write([]byte{0, 0, 0, 2, 0}); err != nil {
		t.Fatal(err)
	}
	child.closeStdin()
	code, _ := child.awaitExit()
	if code != exitTransportFailure {
		t.Fatalf("exit = %d; want %d (stderr %q)", code, exitTransportFailure, child.stderr.String())
	}
	if child.stderr.String() != "" {
		t.Fatalf("stderr = %q; want nothing", child.stderr.String())
	}
}
