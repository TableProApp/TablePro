package hana

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/SAP/go-hdb/driver/dial"
)

type testAuthority struct {
	certificate *x509.Certificate
	key         *ecdsa.PrivateKey
	pemPath     string
}

func newTestAuthority(t *testing.T) *testAuthority {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "TablePro Test Root"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "ca.pem")
	writePEM(t, path, "CERTIFICATE", der)
	return &testAuthority{certificate: certificate, key: key, pemPath: path}
}

func (a *testAuthority) issue(t *testing.T, serial int64, usage x509.ExtKeyUsage, dnsNames ...string) (tls.Certificate, string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      pkix.Name{CommonName: "leaf"},
		DNSNames:     dnsNames,
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{usage},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, a.certificate, &key.PublicKey, a.key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	certificatePath := filepath.Join(directory, "leaf.pem")
	keyPath := filepath.Join(directory, "leaf.key")
	writePEM(t, certificatePath, "CERTIFICATE", der)
	writePEM(t, keyPath, "EC PRIVATE KEY", keyDER)
	pair, err := tls.LoadX509KeyPair(certificatePath, keyPath)
	if err != nil {
		t.Fatal(err)
	}
	return pair, certificatePath, keyPath
}

func writePEM(t *testing.T, path string, blockType string, der []byte) {
	t.Helper()
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: blockType, Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
}

type tlsTestServer struct {
	server      *httptest.Server
	mu          sync.Mutex
	serverNames []string
}

func newTLSTestServer(t *testing.T, certificate tls.Certificate, clientAuthority *testAuthority) *tlsTestServer {
	t.Helper()
	testServer := &tlsTestServer{}
	testServer.server = httptest.NewUnstartedServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	testServer.server.Config.ErrorLog = log.New(io.Discard, "", 0)
	testServer.server.TLS = &tls.Config{
		Certificates: []tls.Certificate{certificate},
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			testServer.mu.Lock()
			testServer.serverNames = append(testServer.serverNames, hello.ServerName)
			testServer.mu.Unlock()
			return nil, nil
		},
	}
	if clientAuthority != nil {
		pool := x509.NewCertPool()
		pool.AddCert(clientAuthority.certificate)
		testServer.server.TLS.ClientCAs = pool
		testServer.server.TLS.ClientAuth = tls.RequireAndVerifyClientCert
	}
	testServer.server.StartTLS()
	t.Cleanup(testServer.server.Close)
	return testServer
}

func (s *tlsTestServer) port() int {
	return s.server.Listener.Addr().(*net.TCPAddr).Port
}

func (s *tlsTestServer) lastServerName() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.serverNames) == 0 {
		return ""
	}
	return s.serverNames[len(s.serverNames)-1]
}

func handshake(t *testing.T, config connectionConfig, port int) *bridgeError {
	t.Helper()
	settings, failure := buildTLSConfig(config, config.hostName())
	if failure != nil {
		t.Fatalf("buildTLSConfig: %v", failure)
	}
	dialer := newTrackingDialer(dial.DefaultDialer, settings)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	address := net.JoinHostPort(config.hostName(), strconv.Itoa(port))
	conn, err := dialer.DialContext(ctx, address, dial.DialerOptions{})
	if err != nil {
		return classifyConnectError(err)
	}
	if _, ok := conn.(*tls.Conn); !ok {
		t.Fatalf("dialer returned %T; want a TLS connection", conn)
	}
	_ = conn.Close()
	return nil
}

func tlsConfig(mode string, host string) connectionConfig {
	return connectionConfig{Host: host, Port: 1, Username: "U", TLSMode: mode}
}

func assertTLSCode(t *testing.T, failure *bridgeError, code int) {
	t.Helper()
	assertKind(t, failure, kindTLS)
	if failure.Code != code {
		t.Fatalf("tls code = %d (%s); want %d", failure.Code, failure.Message, code)
	}
}

func TestTLSModesAgainstAServerWithAPrivateAuthority(t *testing.T) {
	authority := newTestAuthority(t)
	serverCertificate, _, _ := authority.issue(t, 2, x509.ExtKeyUsageServerAuth, "hana.internal")
	server := newTLSTestServer(t, serverCertificate, nil)

	verifyCA := tlsConfig(tlsModeVerifyCA, "127.0.0.1")
	verifyCA.CACertificatePath = authority.pemPath
	if failure := handshake(t, verifyCA, server.port()); failure != nil {
		t.Fatalf("verifyCa rejected a trusted chain with a different host name: %v", failure)
	}

	identity := tlsConfig(tlsModeVerifyIdentity, "127.0.0.1")
	identity.CACertificatePath = authority.pemPath
	assertTLSCode(t, handshake(t, identity, server.port()), tlsFailureHostnameMismatch)

	localhostIdentity := tlsConfig(tlsModeVerifyIdentity, "localhost")
	localhostIdentity.CACertificatePath = authority.pemPath
	assertTLSCode(t, handshake(t, localhostIdentity, server.port()), tlsFailureHostnameMismatch)
	if name := server.lastServerName(); name != "localhost" {
		t.Fatalf("SNI = %q; want the host", name)
	}

	override := localhostIdentity
	override.TLSServerName = "hana.internal"
	if failure := handshake(t, override, server.port()); failure != nil {
		t.Fatalf("verifyIdentity with tlsServerName rejected the matching certificate: %v", failure)
	}
	if name := server.lastServerName(); name != "localhost" {
		t.Fatalf("SNI with an override = %q; want the host, not the verified name", name)
	}

	wrongOverride := override
	wrongOverride.TLSServerName = "other.internal"
	assertTLSCode(t, handshake(t, wrongOverride, server.port()), tlsFailureHostnameMismatch)

	systemRootsIdentity := tlsConfig(tlsModeVerifyIdentity, "localhost")
	systemRootsIdentity.TLSServerName = "hana.internal"
	assertTLSCode(t, handshake(t, systemRootsIdentity, server.port()), tlsFailureUntrusted)

	systemRootsCA := tlsConfig(tlsModeVerifyCA, "127.0.0.1")
	assertTLSCode(t, handshake(t, systemRootsCA, server.port()), tlsFailureUntrusted)

	for _, mode := range []string{tlsModeRequired, tlsModePreferred} {
		if failure := handshake(t, tlsConfig(mode, "127.0.0.1"), server.port()); failure != nil {
			t.Fatalf("%s refused an unverified server: %v", mode, failure)
		}
	}
}

func TestTLSConfigurationShape(t *testing.T) {
	disabled, failure := buildTLSConfig(tlsConfig(tlsModeDisabled, "h"), "h")
	if failure != nil || disabled != nil {
		t.Fatalf("disabled = %v, %v", disabled, failure)
	}
	for _, mode := range []string{tlsModePreferred, tlsModeRequired, tlsModeVerifyCA, tlsModeVerifyIdentity} {
		settings, failure := buildTLSConfig(tlsConfig(mode, "db.example.com"), "db.example.com")
		if failure != nil {
			t.Fatal(failure)
		}
		if settings.ServerName != "db.example.com" || settings.MinVersion != tls.VersionTLS12 {
			t.Fatalf("%s: ServerName=%q MinVersion=%x", mode, settings.ServerName, settings.MinVersion)
		}
	}
	identity, _ := buildTLSConfig(tlsConfig(tlsModeVerifyIdentity, "db.example.com"), "db.example.com")
	if identity.InsecureSkipVerify || identity.VerifyConnection != nil || identity.RootCAs != nil {
		t.Fatal("verifyIdentity without an override must use standard verification against the system roots")
	}
	verifyCA, _ := buildTLSConfig(tlsConfig(tlsModeVerifyCA, "db.example.com"), "db.example.com")
	if !verifyCA.InsecureSkipVerify || verifyCA.VerifyConnection == nil {
		t.Fatal("verifyCa must replace the host name check with a chain check")
	}
}

func TestUnreadableAuthorityFileIsAConfigurationError(t *testing.T) {
	garbage := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(garbage, []byte("not a certificate"), 0o600); err != nil {
		t.Fatal(err)
	}
	config := tlsConfig(tlsModeVerifyCA, "h")
	config.CACertificatePath = garbage
	_, failure := buildTLSConfig(config, "h")
	assertKind(t, failure, kindConfiguration)
}

func TestClientCertificateLoadingAndMutualTLS(t *testing.T) {
	authority := newTestAuthority(t)
	serverCertificate, _, _ := authority.issue(t, 2, x509.ExtKeyUsageServerAuth, "hana.internal")
	_, clientCertificatePath, clientKeyPath := authority.issue(t, 3, x509.ExtKeyUsageClientAuth, "client")
	server := newTLSTestServer(t, serverCertificate, authority)

	withClient := tlsConfig(tlsModeRequired, "127.0.0.1")
	withClient.ClientCertificatePath = clientCertificatePath
	withClient.ClientKeyPath = clientKeyPath
	settings, failure := buildTLSConfig(withClient, "127.0.0.1")
	if failure != nil || len(settings.Certificates) != 1 {
		t.Fatalf("client certificate not loaded: %v", failure)
	}
	if failure := handshake(t, withClient, server.port()); failure != nil {
		t.Fatalf("mutual TLS failed with a valid client certificate: %v", failure)
	}

	missingKey := withClient
	missingKey.ClientKeyPath = filepath.Join(t.TempDir(), "missing.key")
	_, failure = buildTLSConfig(missingKey, "127.0.0.1")
	assertTLSCode(t, failure, tlsFailureClientCertificate)

	mismatched := withClient
	_, otherCertificatePath, _ := authority.issue(t, 4, x509.ExtKeyUsageClientAuth, "other")
	mismatched.ClientCertificatePath = otherCertificatePath
	_, failure = buildTLSConfig(mismatched, "127.0.0.1")
	assertTLSCode(t, failure, tlsFailureClientCertificate)

	encryptedKeyPath := filepath.Join(t.TempDir(), "encrypted.key")
	encrypted := "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIGbMFcGCSqGSIb3DQEFDTBKMCkGCSqGSIb3DQEFDDAcBAgAAAAAAAAAAAICCAAw\n-----END ENCRYPTED PRIVATE KEY-----\n"
	if err := os.WriteFile(encryptedKeyPath, []byte(encrypted), 0o600); err != nil {
		t.Fatal(err)
	}
	encryptedKey := withClient
	encryptedKey.ClientKeyPath = encryptedKeyPath
	_, failure = buildTLSConfig(encryptedKey, "127.0.0.1")
	assertTLSCode(t, failure, tlsFailureClientCertificate)
}

func TestPlaintextServerIsReportedAsNotSpeakingTLS(t *testing.T) {
	answering := startPlaintextServer(t, func(conn net.Conn) {
		buffer := make([]byte, 512)
		_, _ = conn.Read(buffer)
		_, _ = io.WriteString(conn, "HTTP/1.1 400 Bad Request\r\n\r\n")
	})
	assertTLSCode(t, handshake(t, tlsConfig(tlsModeRequired, "127.0.0.1"), answering), tlsFailurePlaintextServer)

	hangingUp := startPlaintextServer(t, func(conn net.Conn) {
		buffer := make([]byte, 512)
		_, _ = conn.Read(buffer)
	})
	assertTLSCode(t, handshake(t, tlsConfig(tlsModeRequired, "127.0.0.1"), hangingUp), tlsFailurePlaintextServer)
}

func startPlaintextServer(t *testing.T, serve func(net.Conn)) int {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = conn.Close() }()
				serve(conn)
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port
}
