package hana

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"sync"

	"github.com/SAP/go-hdb/driver/dial"
)

var errDialerSevered = errors.New("session sockets closed")

type trackingDialer struct {
	base      dial.Dialer
	tlsConfig *tls.Config

	mu      sync.Mutex
	severed bool
	live    map[*trackedConn]struct{}
}

func newTrackingDialer(base dial.Dialer, tlsConfig *tls.Config) *trackingDialer {
	return &trackingDialer{base: base, tlsConfig: tlsConfig, live: map[*trackedConn]struct{}{}}
}

func (d *trackingDialer) DialContext(ctx context.Context, address string, options dial.DialerOptions) (net.Conn, error) {
	if d.isSevered() {
		return nil, errDialerSevered
	}
	raw, err := d.base.DialContext(ctx, address, options)
	if err != nil {
		return nil, err
	}
	conn, err := d.track(raw)
	if err != nil {
		return nil, err
	}
	if d.tlsConfig == nil {
		return conn, nil
	}
	secured := tls.Client(conn, d.tlsConfig)
	if err := secured.HandshakeContext(ctx); err != nil {
		_ = conn.Close()
		return nil, &handshakeError{cause: err}
	}
	return secured, nil
}

func (d *trackingDialer) track(raw net.Conn) (*trackedConn, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.severed {
		_ = raw.Close()
		return nil, errDialerSevered
	}
	conn := &trackedConn{Conn: raw, owner: d}
	d.live[conn] = struct{}{}
	return conn, nil
}

func (d *trackingDialer) forget(conn *trackedConn) {
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.live, conn)
}

func (d *trackingDialer) isSevered() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.severed
}

func (d *trackingDialer) liveConnections() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.live)
}

func (d *trackingDialer) sever() {
	d.mu.Lock()
	d.severed = true
	conns := make([]*trackedConn, 0, len(d.live))
	for conn := range d.live {
		conns = append(conns, conn)
	}
	clear(d.live)
	d.mu.Unlock()
	for _, conn := range conns {
		_ = conn.Conn.Close()
	}
}

type trackedConn struct {
	net.Conn
	owner *trackingDialer
}

func (c *trackedConn) Close() error {
	c.owner.forget(c)
	return c.Conn.Close()
}
