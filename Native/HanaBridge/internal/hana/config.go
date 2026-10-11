package hana

import (
	"encoding/json"
	"net"
	"strconv"
	"strings"
	"time"
)

const defaultConnectTimeout = 30 * time.Second

type connectionConfig struct {
	Host                  string  `json:"host"`
	Port                  int     `json:"port"`
	Username              string  `json:"username"`
	Password              string  `json:"password"`
	Schema                string  `json:"schema"`
	TLSMode               string  `json:"tlsMode"`
	TLSServerName         string  `json:"tlsServerName"`
	CACertificatePath     string  `json:"caCertificatePath"`
	ClientCertificatePath string  `json:"clientCertificatePath"`
	ClientKeyPath         string  `json:"clientKeyPath"`
	ConnectTimeoutSeconds float64 `json:"connectTimeoutSeconds"`
}

func parseConnectionConfig(data []byte) (connectionConfig, *bridgeError) {
	var config connectionConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return connectionConfig{}, internalError(err.Error())
	}
	if failure := config.validate(); failure != nil {
		return connectionConfig{}, failure
	}
	return config, nil
}

func (c connectionConfig) validate() *bridgeError {
	switch {
	case c.hostName() == "":
		return configurationError("host")
	case c.Port < 1 || c.Port > 65535:
		return configurationError("port")
	case strings.TrimSpace(c.Username) == "":
		return configurationError("username")
	case !isKnownTLSMode(c.TLSMode):
		return configurationError("tlsMode")
	case c.hasClientCertificatePath() != c.hasClientKeyPath():
		return configurationError("clientCertificate")
	case c.ConnectTimeoutSeconds < 0:
		return configurationError("connectTimeoutSeconds")
	}
	return nil
}

func (c connectionConfig) hostName() string {
	host := strings.TrimSpace(c.Host)
	if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
		return host[1 : len(host)-1]
	}
	return host
}

func (c connectionConfig) address() string {
	return net.JoinHostPort(c.hostName(), strconv.Itoa(c.Port))
}

func (c connectionConfig) hasClientCertificatePath() bool {
	return strings.TrimSpace(c.ClientCertificatePath) != ""
}

func (c connectionConfig) hasClientKeyPath() bool {
	return strings.TrimSpace(c.ClientKeyPath) != ""
}

func (c connectionConfig) hasClientCertificate() bool {
	return c.hasClientCertificatePath() && c.hasClientKeyPath()
}

func (c connectionConfig) connectTimeout() time.Duration {
	if c.ConnectTimeoutSeconds <= 0 {
		return defaultConnectTimeout
	}
	return time.Duration(c.ConnectTimeoutSeconds * float64(time.Second))
}
