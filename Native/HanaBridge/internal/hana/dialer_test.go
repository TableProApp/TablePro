package hana

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/SAP/go-hdb/driver/dial"
)

type silentServer struct {
	listener net.Listener
	accepted atomic.Int32
	mu       sync.Mutex
	conns    []net.Conn
	closed   chan struct{}
}

func newSilentServer(t *testing.T) *silentServer {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &silentServer{listener: listener, closed: make(chan struct{}, 16)}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			server.accepted.Add(1)
			server.mu.Lock()
			server.conns = append(server.conns, conn)
			server.mu.Unlock()
			go func() {
				_, _ = io.Copy(io.Discard, conn)
				server.closed <- struct{}{}
			}()
		}
	}()
	t.Cleanup(func() {
		_ = listener.Close()
		server.mu.Lock()
		defer server.mu.Unlock()
		for _, conn := range server.conns {
			_ = conn.Close()
		}
	})
	return server
}

func (s *silentServer) address() string {
	return s.listener.Addr().String()
}

func (s *silentServer) port() int {
	return s.listener.Addr().(*net.TCPAddr).Port
}

func (s *silentServer) waitForClientHangUp(t *testing.T) {
	t.Helper()
	select {
	case <-s.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("the client never closed its socket")
	}
}

func TestTrackingDialerForgetsClosedConnections(t *testing.T) {
	server := newSilentServer(t)
	dialer := newTrackingDialer(dial.DefaultDialer, nil)
	conn, err := dialer.DialContext(context.Background(), server.address(), dial.DialerOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if dialer.liveConnections() != 1 {
		t.Fatalf("live connections = %d", dialer.liveConnections())
	}
	_ = conn.Close()
	if dialer.liveConnections() != 0 {
		t.Fatalf("a closed connection is still tracked: %d", dialer.liveConnections())
	}
}

func TestSeverClosesEveryLiveSocketAndRefusesNewDials(t *testing.T) {
	server := newSilentServer(t)
	dialer := newTrackingDialer(dial.DefaultDialer, nil)
	for range 2 {
		if _, err := dialer.DialContext(context.Background(), server.address(), dial.DialerOptions{}); err != nil {
			t.Fatal(err)
		}
	}
	dialer.sever()
	server.waitForClientHangUp(t)
	server.waitForClientHangUp(t)
	if dialer.liveConnections() != 0 {
		t.Fatalf("live connections after sever = %d", dialer.liveConnections())
	}
	if _, err := dialer.DialContext(context.Background(), server.address(), dial.DialerOptions{}); !errors.Is(err, errDialerSevered) {
		t.Fatalf("dial after sever = %v; want errDialerSevered", err)
	}
}

func TestSeverInterruptsAHandshakeThatNeverEnds(t *testing.T) {
	server := newSilentServer(t)
	dialer := newTrackingDialer(dial.DefaultDialer, &tls.Config{InsecureSkipVerify: true, ServerName: "127.0.0.1"})
	result := make(chan error, 1)
	go func() {
		_, err := dialer.DialContext(context.Background(), server.address(), dial.DialerOptions{})
		result <- err
	}()
	waitFor(t, func() bool { return dialer.liveConnections() == 1 })
	dialer.sever()
	select {
	case err := <-result:
		var handshake *handshakeError
		if !errors.As(err, &handshake) {
			t.Fatalf("dial = %v; want a handshake error", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("sever did not end the handshake")
	}
}

func TestHandshakeIsBoundedByTheDialContext(t *testing.T) {
	server := newSilentServer(t)
	dialer := newTrackingDialer(dial.DefaultDialer, &tls.Config{InsecureSkipVerify: true, ServerName: "127.0.0.1"})
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	started := time.Now()
	_, err := dialer.DialContext(ctx, "127.0.0.1:"+strconv.Itoa(server.port()), dial.DialerOptions{})
	if err == nil || time.Since(started) > 5*time.Second {
		t.Fatalf("dial = %v after %v; want a prompt failure", err, time.Since(started))
	}
	if dialer.liveConnections() != 0 {
		t.Fatalf("a failed handshake left %d tracked sockets", dialer.liveConnections())
	}
}
