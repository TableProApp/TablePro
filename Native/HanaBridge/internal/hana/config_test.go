package hana

import (
	"context"
	"log/slog"
	"testing"
	"time"

	"github.com/SAP/go-hdb/driver/dial"
	"golang.org/x/text/transform"
)

func TestConfigurationValidation(t *testing.T) {
	cases := map[string]string{
		`{"host":"","port":443,"username":"U","tlsMode":"disabled"}`:                                            "host",
		`{"host":"   ","port":443,"username":"U","tlsMode":"disabled"}`:                                         "host",
		`{"host":"h","port":0,"username":"U","tlsMode":"disabled"}`:                                             "port",
		`{"host":"h","port":65536,"username":"U","tlsMode":"disabled"}`:                                         "port",
		`{"host":"h","port":443,"username":" ","tlsMode":"disabled"}`:                                           "username",
		`{"host":"h","port":443,"username":"U","tlsMode":"sometimes"}`:                                          "tlsMode",
		`{"host":"h","port":443,"username":"U","tlsMode":""}`:                                                   "tlsMode",
		`{"host":"h","port":443,"username":"U","tlsMode":"required","clientCertificatePath":"/tmp/c.pem"}`:      "clientCertificate",
		`{"host":"h","port":443,"username":"U","tlsMode":"required","clientKeyPath":"/tmp/k.pem"}`:              "clientCertificate",
		`{"host":"h","port":443,"username":"U","tlsMode":"disabled","connectTimeoutSeconds":-1}`:                "connectTimeoutSeconds",
		`{"host":"h","port":443,"username":"U","tlsMode":"verifyCa","caCertificatePath":"/nonexistent/ca.pem"}`: "caCertificate",
	}
	for body, field := range cases {
		_, failure := testBridge.openSession([]byte(body))
		assertKind(t, failure, kindConfiguration)
		if field != "" && failure.Message != field {
			t.Errorf("%s rejected with %q; want %q", body, failure.Message, field)
		}
	}
	_, failure := testBridge.openSession([]byte(`{"host":`))
	assertKind(t, failure, kindInternal)
}

func TestConfigurationDefaultsAndAddresses(t *testing.T) {
	config, failure := parseConnectionConfig([]byte(`{"host":" db.example.com ","port":443,"username":"U","tlsMode":"verifyIdentity"}`))
	if failure != nil {
		t.Fatal(failure)
	}
	if config.address() != "db.example.com:443" || config.connectTimeout() != 30*time.Second {
		t.Fatalf("address=%q timeout=%v", config.address(), config.connectTimeout())
	}
	ipv6, failure := parseConnectionConfig([]byte(`{"host":"[::1]","port":30015,"username":"U","tlsMode":"disabled","connectTimeoutSeconds":2.5}`))
	if failure != nil {
		t.Fatal(failure)
	}
	if ipv6.address() != "[::1]:30015" || ipv6.connectTimeout() != 2500*time.Millisecond {
		t.Fatalf("address=%q timeout=%v", ipv6.address(), ipv6.connectTimeout())
	}
}

func TestSessionConnectorSettings(t *testing.T) {
	id := openTestSession(t, []byte(`{"host":"127.0.0.1","port":1,"username":"DBADMIN","password":"p","schema":"my schema","tlsMode":"disabled"}`))
	entry, failure := testBridge.sessions.lookup(id)
	if failure != nil {
		t.Fatal(failure)
	}
	connector := entry.connector
	if connector.Timeout() != 0 {
		t.Errorf("socket timeout = %v; want 0 so a long statement is never cut", connector.Timeout())
	}
	if connector.ApplicationName() != "TablePro" {
		t.Errorf("application name = %q", connector.ApplicationName())
	}
	if connector.DefaultSchema() != "my schema" {
		t.Errorf("default schema = %q", connector.DefaultSchema())
	}
	if connector.Logger().Handler() != slog.DiscardHandler {
		t.Errorf("logger handler = %T; want the discard handler", connector.Logger().Handler())
	}
	if connector.Logger().Enabled(context.Background(), slog.LevelError) {
		t.Error("go-hdb would still write errors to the host process")
	}
	if connector.Dialer() != entry.dialer {
		t.Errorf("dialer = %T; want the session's tracking dialer", connector.Dialer())
	}
	if entry.dialer.base != dial.DefaultDialer {
		t.Errorf("tracking dialer wraps %T; want go-hdb's IPv4-first default dialer", entry.dialer.base)
	}
	if connector.TLSConfig() != nil || entry.dialer.tlsConfig != nil {
		t.Error("a disabled TLS mode produced a TLS configuration")
	}
	decoded, _, err := transform.Bytes(connector.CESU8Decoder()(), []byte{'a', 0xED, 0xA0, 0x80, 'b'})
	if err != nil || string(decoded) != "a\uFFFDb" {
		t.Errorf("go-hdb decodes a lone surrogate as %q, %v; want a replacement character", decoded, err)
	}
	if entry.connectTimeout != defaultConnectTimeout {
		t.Errorf("connect timeout = %v", entry.connectTimeout)
	}
}
