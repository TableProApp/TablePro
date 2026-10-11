package hana

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"os"
	"strings"
)

const (
	tlsModeDisabled       = "disabled"
	tlsModePreferred      = "preferred"
	tlsModeRequired       = "required"
	tlsModeVerifyCA       = "verifyCa"
	tlsModeVerifyIdentity = "verifyIdentity"
)

var (
	errNoCertificatesInFile = errors.New("the file holds no PEM certificate")
	errNoPeerCertificate    = errors.New("the server presented no certificate")
)

func isKnownTLSMode(mode string) bool {
	switch mode {
	case tlsModeDisabled, tlsModePreferred, tlsModeRequired, tlsModeVerifyCA, tlsModeVerifyIdentity:
		return true
	default:
		return false
	}
}

func buildTLSConfig(config connectionConfig, host string) (*tls.Config, *bridgeError) {
	if config.TLSMode == tlsModeDisabled {
		return nil, nil
	}
	roots, err := loadRootCertificates(config.CACertificatePath)
	if err != nil {
		return nil, configurationError("caCertificate")
	}
	settings := &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}
	if config.hasClientCertificate() {
		certificate, err := tls.LoadX509KeyPair(config.ClientCertificatePath, config.ClientKeyPath)
		if err != nil {
			return nil, tlsError(tlsFailureClientCertificate, err)
		}
		settings.Certificates = []tls.Certificate{certificate}
	}
	switch config.TLSMode {
	case tlsModePreferred, tlsModeRequired:
		settings.InsecureSkipVerify = true
	case tlsModeVerifyCA:
		settings.InsecureSkipVerify = true
		settings.VerifyConnection = peerChainVerifier(roots, "")
	case tlsModeVerifyIdentity:
		settings.RootCAs = roots
		identity := verifiedIdentity(config, host)
		if identity != host {
			settings.InsecureSkipVerify = true
			settings.VerifyConnection = peerChainVerifier(roots, identity)
		}
	}
	return settings, nil
}

func verifiedIdentity(config connectionConfig, host string) string {
	if override := strings.TrimSpace(config.TLSServerName); override != "" {
		return override
	}
	return host
}

func loadRootCertificates(path string) (*x509.CertPool, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(data) {
		return nil, errNoCertificatesInFile
	}
	return pool, nil
}

func peerChainVerifier(roots *x509.CertPool, dnsName string) func(tls.ConnectionState) error {
	return func(state tls.ConnectionState) error {
		if len(state.PeerCertificates) == 0 {
			return &tls.CertificateVerificationError{Err: errNoPeerCertificate}
		}
		intermediates := x509.NewCertPool()
		for _, certificate := range state.PeerCertificates[1:] {
			intermediates.AddCert(certificate)
		}
		options := x509.VerifyOptions{Roots: roots, Intermediates: intermediates, DNSName: dnsName}
		if _, err := state.PeerCertificates[0].Verify(options); err != nil {
			return &tls.CertificateVerificationError{UnverifiedCertificates: state.PeerCertificates, Err: err}
		}
		return nil
	}
}
