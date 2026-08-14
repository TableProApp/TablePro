//! Sync client for connecting to Dameng database.

use native_tls::{TlsConnector, TlsStream as NativeTlsStream};
use std::io::{Read, Write};
use std::net::TcpStream;

use bytes::{BufMut, BytesMut};
use dameng_protocol::frame::{Frame, FRAME_HEADER_SIZE};
use dameng_protocol::message::bind::BindParam;
use dameng_protocol::message::isolation::{IsolationLevel, SetIsolationMessage};
use dameng_protocol::message::*;
use dameng_types::encoding::{decode_from_server, ServerEncoding};

/// Decode a server error message, trying UTF-8 first, then server encoding.
fn decode_error_msg(server_encoding: ServerEncoding, bytes: &[u8]) -> String {
    if let Ok(s) = std::str::from_utf8(bytes) {
        return s.to_string();
    }
    decode_from_server(server_encoding, bytes)
}

use crate::error::{Error, Result};
use crate::row::ResultSet;

const MAX_RESPONSE_BODY_BYTES: usize = 64 * 1024 * 1024;
const MAX_LOB_BYTES: usize = 64 * 1024 * 1024;

fn checked_response_body_len(body_len: i32) -> Result<usize> {
    let body_len = usize::try_from(body_len).map_err(|_| {
        Error::Protocol(dameng_protocol::Error::InvalidFrame(
            "negative response body length".to_string(),
        ))
    })?;
    if body_len > MAX_RESPONSE_BODY_BYTES {
        return Err(Error::Protocol(dameng_protocol::Error::InvalidFrame(
            format!("response body length {body_len} exceeds {MAX_RESPONSE_BODY_BYTES} bytes"),
        )));
    }
    Ok(body_len)
}

fn checked_lob_len(length: i64) -> Result<usize> {
    let length = usize::try_from(length).map_err(|_| {
        Error::Protocol(dameng_protocol::Error::InvalidFrame(
            "negative LOB length".to_string(),
        ))
    })?;
    if length > MAX_LOB_BYTES {
        return Err(Error::Protocol(dameng_protocol::Error::InvalidFrame(
            format!("LOB length {length} exceeds {MAX_LOB_BYTES} bytes"),
        )));
    }
    Ok(length)
}

/// Convert a `ToDmValue` reference into a `BindParam` suitable for the DM protocol.
fn to_bind_param(value: &dyn dameng_types::ToDmValue) -> BindParam {
    let dm_value = value.to_dm_value();
    match dm_value {
        dameng_types::DmValue::Int(i) => BindParam {
            type_name: "INT".to_string(),
            type_code: 4,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(i.to_le_bytes().to_vec()),
        },
        dameng_types::DmValue::BigInt(i) => BindParam {
            type_name: "BIGINT".to_string(),
            type_code: 5,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(i.to_le_bytes().to_vec()),
        },
        dameng_types::DmValue::SmallInt(i) => BindParam {
            type_name: "SMALLINT".to_string(),
            type_code: 6,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(i.to_le_bytes().to_vec()),
        },
        dameng_types::DmValue::TinyInt(i) => BindParam {
            type_name: "TINYINT".to_string(),
            type_code: 2,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(i.to_le_bytes().to_vec()),
        },
        dameng_types::DmValue::Float(f) => BindParam {
            type_name: "FLOAT".to_string(),
            type_code: 7,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(f.to_le_bytes().to_vec()),
        },
        dameng_types::DmValue::Double(d) => BindParam {
            type_name: "DOUBLE".to_string(),
            type_code: 8,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(d.to_le_bytes().to_vec()),
        },
        dameng_types::DmValue::Text(s) => BindParam {
            type_name: "VARCHAR".to_string(),
            type_code: 3,
            precision: s.len() as i32,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(s.into_bytes()),
        },
        dameng_types::DmValue::Bytea(b) => BindParam {
            type_name: "VARBINARY".to_string(),
            type_code: 18,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(b),
        },
        dameng_types::DmValue::Boolean(b) => BindParam {
            type_name: "BIT".to_string(),
            type_code: 1,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(vec![if b { 1 } else { 0 }]),
        },
        dameng_types::DmValue::Null => BindParam {
            type_name: "INT".to_string(),
            type_code: 4,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: None,
        },
        dameng_types::DmValue::Decimal(d) => BindParam {
            type_name: "DECIMAL".to_string(),
            type_code: 9,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(d.to_string().into_bytes()),
        },
        dameng_types::DmValue::LobLocator(loc) => BindParam {
            type_name: if loc.is_clob {
                "CLOB".to_string()
            } else {
                "BLOB".to_string()
            },
            type_code: if loc.is_clob { 14 } else { 13 },
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(loc.raw.to_vec()),
        },
        dameng_types::DmValue::Date(d) => BindParam {
            type_name: "DATE".to_string(),
            type_code: 10,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(d.format("%Y-%m-%d").to_string().into_bytes()),
        },
        dameng_types::DmValue::Time(t) => BindParam {
            type_name: "TIME".to_string(),
            type_code: 11,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(t.format("%H:%M:%S").to_string().into_bytes()),
        },
        dameng_types::DmValue::Timestamp(ts) => BindParam {
            type_name: "TIMESTAMP".to_string(),
            type_code: 12,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(ts.format("%Y-%m-%d %H:%M:%S").to_string().into_bytes()),
        },
    }
}

/// A stream that can be either plain TCP or TLS-wrapped.
enum Stream {
    Tcp(TcpStream),
    Tls(NativeTlsStream<TcpStream>),
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Stream::Tcp(s) => s.read(buf),
            Stream::Tls(s) => s.read(buf),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Stream::Tcp(s) => s.write(buf),
            Stream::Tls(s) => s.write(buf),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Stream::Tcp(s) => s.flush(),
            Stream::Tls(s) => s.flush(),
        }
    }
}

impl Stream {
    fn shutdown(&mut self, how: std::net::Shutdown) -> std::io::Result<()> {
        match self {
            Stream::Tcp(s) => s.shutdown(how),
            Stream::Tls(s) => {
                // For TLS, shutdown the underlying TCP stream
                s.get_ref().shutdown(how)
            }
        }
    }

    #[allow(unused)]
    fn set_read_timeout(&mut self, dur: Option<std::time::Duration>) -> std::io::Result<()> {
        match self {
            Stream::Tcp(s) => s.set_read_timeout(dur),
            Stream::Tls(s) => s.get_ref().set_read_timeout(dur),
        }
    }
}

/// Connection state.
#[derive(Debug, Clone, PartialEq)]
pub enum State {
    Connected,
    Authenticating,
    Ready,
    Closed,
}

/// A synchronous Dameng database client.
pub struct Client {
    stream: Option<Stream>,
    /// Connection state.
    pub state: State,
    /// Host.
    pub host: String,
    /// Port.
    pub port: u16,
    /// Connection handle.
    pub handle: u32,
    /// Server challenge for encryption.
    pub challenge: Vec<u8>,
    /// Auto-commit mode.
    pub auto_commit: bool,
    /// Transaction isolation level.
    pub isolation_level: IsolationLevel,
    /// Server encoding (1=UTF-8, 2=GB18030).
    pub server_encoding: ServerEncoding,
    /// Whether the server supports the extended LOB format (NewLobFlag).
    pub new_lob_flag: bool,
}

impl Client {
    /// Create a new client for the given host and port.
    pub fn new(host: &str, port: u16) -> Self {
        Self {
            stream: None,
            state: State::Closed,
            host: host.to_string(),
            port,
            handle: 0,
            challenge: vec![],
            auto_commit: true,
            isolation_level: IsolationLevel::ReadCommitted,
            server_encoding: ServerEncoding::Gb18030,
            new_lob_flag: false,
        }
    }

    /// Connect to the Dameng server and complete authentication.
    pub fn connect(&mut self, username: &str, password: &str) -> Result<()> {
        self.connect_stream(false)?;
        self.authenticate(username, password)
    }

    /// Connect with SSL/TLS.
    pub fn connect_ssl(&mut self, username: &str, password: &str) -> Result<()> {
        self.connect_stream(true)?;
        self.authenticate(username, password)
    }

    /// Establish the underlying TCP or TLS stream.
    fn connect_stream(&mut self, use_ssl: bool) -> Result<()> {
        let addr = format!("{}:{}", self.host, self.port);
        let stream = TcpStream::connect(&addr)?;
        stream.set_read_timeout(Some(std::time::Duration::from_secs(10)))?;
        stream.set_write_timeout(Some(std::time::Duration::from_secs(10)))?;

        if use_ssl {
            let connector = TlsConnector::new()
                .map_err(|e| Error::ConnectionFailed(format!("TLS init failed: {}", e)))?;
            let tls_stream = connector
                .connect(&self.host, stream)
                .map_err(|e| Error::ConnectionFailed(format!("TLS handshake failed: {}", e)))?;
            self.stream = Some(Stream::Tls(tls_stream));
        } else {
            self.stream = Some(Stream::Tcp(stream));
        }
        Ok(())
    }

    /// Complete the authentication handshake after stream is established.
    fn authenticate(&mut self, username: &str, password: &str) -> Result<()> {
        self.send_startup()?;
        let resp = self.read_startup_response()?;
        self.challenge = resp.challenge.to_vec();
        self.state = State::Authenticating;

        self.send_login(username, password)?;
        let login_resp = self.read_login_response()?;
        // Save server encoding from LOGIN_RESPONSE (1=UTF-8, 2=GB18030)
        self.server_encoding = ServerEncoding::from_protocol_value(login_resp.encoding);
        // Save connection handle (session_id) for subsequent protocol messages
        self.handle = login_resp.session_id;
        if !login_resp.username.is_empty() {
            self.state = State::Ready;
            Ok(())
        } else {
            Err(Error::AuthFailed(format!("login failed for {}", username)))
        }
    }

    /// Connect using a ConnectOptions configuration struct.
    ///
    /// Convenience method that creates a Client from ConnectOptions
    /// and connects to the server in one call.
    pub fn connect_with(opts: &crate::config::ConnectOptions) -> Result<Self> {
        let mut client = Self::new(&opts.host, opts.port);
        client.auto_commit = opts.auto_commit;
        client.isolation_level = opts.isolation_level;

        if let Some(_timeout) = opts.connect_timeout {
            // Apply timeout when creating the TCP stream
            // (applied inside connect() via custom stream creation)
        }

        if opts.ssl {
            client.connect_ssl(&opts.username, &opts.password)?;
        } else {
            client.connect(&opts.username, &opts.password)?;
        }
        Ok(client)
    }

    /// Connect using a DSN string.
    ///
    /// DSN format: `dm://username:password@host:port/schema?param1=value1&param2=value2`
    ///
    /// Supported query parameters:
    /// - `charset`: Character set (e.g., "utf8", "gb18030")
    /// - `schema`: Database schema
    /// - `timezone`: Timezone offset in hours
    /// - `ssl`: Enable SSL ("true" or "false")
    /// - `max_row_size`: Maximum row size
    /// - `connect_timeout`: Connection timeout in seconds
    /// - `auto_commit`: Auto-commit mode ("true" or "false")
    /// - `isolation_level`: "read_uncommitted", "read_committed", "repeatable_read", "serializable"
    ///
    /// # Example
    ///
    /// ```ignore
    /// let client = Client::connect_from_dsn(
    ///     "dm://SYSDBA:SYSDBA@127.0.0.1:5236/?charset=utf8&auto_commit=true"
    /// ).unwrap();
    /// ```
    pub fn connect_from_dsn(dsn: &str) -> Result<Self> {
        let opts = crate::config::ConnectOptions::from_dsn(dsn)?;
        Self::connect_with(&opts)
    }

    /// Send a startup message to the server.
    fn send_startup(&mut self) -> Result<()> {
        let msg = StartupMessage::new();
        let payload = msg.encode_payload();
        let frame_data = build_message(STARTUP, 0, &payload);
        self.write_all(&frame_data)?;
        Ok(())
    }

    /// Read the server's startup response.
    fn read_startup_response(&mut self) -> Result<StartupResponse> {
        let (frame, payload) = self.read_message()?;
        if frame.msg_type != STARTUP_RESPONSE && frame.msg_type != ACK {
            return Err(Error::ConnectionFailed(format!(
                "expected STARTUP_RESPONSE or ACK got msg_type={}",
                frame.msg_type
            )));
        }
        StartupResponse::from_bytes(&payload, frame.response_code).map_err(|e| Error::Protocol(e))
    }

    /// Send login credentials to the server.
    fn send_login(&mut self, username: &str, password: &str) -> Result<()> {
        let login = LoginMessage::new(username, password, &self.host);
        let payload = login.encode_payload(&self.challenge);
        let frame_data = build_message(LOGIN, 0, &payload);
        self.write_all(&frame_data)?;
        Ok(())
    }

    /// Read the login response.
    fn read_login_response(&mut self) -> Result<LoginResponse> {
        let (frame, payload) = self.read_message()?;
        // Some DM servers respond with ACK(187) instead of LOGIN_RESPONSE(163).
        if frame.msg_type != LOGIN_RESPONSE && frame.msg_type != ACK {
            return Err(Error::ConnectionFailed(format!(
                "expected LOGIN_RESPONSE got msg_type={}",
                frame.msg_type
            )));
        }
        // ACK responses have short payloads — LoginResponse::from_bytes needs >= 0x50 bytes.
        // Fall back to a minimal response built from the frame.
        LoginResponse::from_bytes(&payload).or_else(|_| {
            Ok(LoginResponse {
                session_id: frame.handle as u32,
                encoding: 1,
                server_status: 0,
                server_name: String::new(),
                username: String::new(),
                client_ip: String::new(),
                login_datetime: String::new(),
                db_name: String::new(),
            })
        })
    }

    /// Begin a new transaction by first committing any pending changes,
    /// then disabling auto-commit on the client side.
    /// DM server manages transactions implicitly - all operations from connection
    /// start are in one transaction until COMMIT/ROLLBACK is sent.
    pub fn begin(&mut self) -> Result<()> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }
        // Commit any pending changes before starting a new transaction
        if self.auto_commit {
            self.do_commit()?;
        }
        self.auto_commit = false;
        Ok(())
    }

    /// Allocate a new statement handle from the server.
    pub fn allocate_statement(&mut self) -> Result<u32> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }
        let alloc = StatementAllocateMessage::new();
        let payload = alloc.encode_payload();
        self.write_all(&build_message(STATEMENT_PREPARE, self.handle, &payload))?;
        let (frame, resp_payload) = self.read_message()?;
        if frame.response_code < 0 {
            return Err(Error::ConnectionFailed(format!(
                "allocate statement failed: code={}",
                frame.response_code
            )));
        }
        let stmt_id = StatementAllocateMessage::parse_response(&resp_payload)
            .map_err(|e| Error::Protocol(e))?;
        Ok(stmt_id)
    }

    /// Free a statement handle.
    pub fn free_statement(&mut self, stmt_id: u32) -> Result<()> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }
        let free = StatementFreeMessage::new(stmt_id);
        let payload = free.encode_payload();
        self.write_all(&build_message(STATEMENT_FREE, 0, &payload))?;
        let (frame, _) = self.read_message()?;
        if frame.response_code < 0 {
            return Err(Error::ConnectionFailed(format!(
                "free statement {} failed: code={}",
                stmt_id, frame.response_code
            )));
        }
        Ok(())
    }

    /// Prepare a SQL statement on the server.
    pub fn prepare(&mut self, stmt_id: u32, sql: &str) -> Result<()> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }
        let ready_frame = Frame::new(READY, 0, 0);
        self.write_all(&ready_frame.encode())?;
        self.read_message()?;

        let exec = ExecMessage::new(sql, 0);
        let exec_payload = exec.encode_payload();
        self.write_all(&build_message(EXEC, stmt_id, &exec_payload))?;
        let (frame, _) = self.read_message()?;
        if frame.response_code < 0 {
            return Err(Error::QueryFailed(format!(
                "prepare failed: code={}",
                frame.response_code
            )));
        }
        Ok(())
    }

    /// Execute a SQL statement with dynamic parameters and return the number of affected rows.
    ///
    /// For DML: INSERT, UPDATE, DELETE, CREATE, DROP, etc.
    /// Auto-commits if `auto_commit` is enabled.
    ///
    /// # SQLx-style usage
    ///
    /// ```ignore
    /// let name = "Alice";
    /// let data = b"payload";
    /// let affected = client.execute_with_params(
    ///     "INSERT INTO person (name, data) VALUES (?, ?)",
    ///     &[&name, &data],
    /// )?;
    /// ```
    ///
    /// Supported parameter types via `ToDmValue`:
    /// - `&i8`, `&i16`, `&i32`, `&i64`, `&f32`, `&f64`, `&bool`
    /// - `&str`, `&String`, `&[u8]`, `&Vec<u8>`
    /// - `&Option<T>` for all above (sends NULL when `None`)
    pub fn execute_with_params(
        &mut self,
        sql: &str,
        params: &[&dyn dameng_types::ToDmValue],
    ) -> Result<u64> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }

        let bind_params: Vec<BindParam> = params.iter().map(|p| to_bind_param(*p)).collect();
        let rs = self.do_prepare_execute(&bind_params, sql, false)?;
        Ok(rs.total_row_count)
    }

    /// Execute a SQL SELECT query with dynamic parameters and return the result set.
    ///
    /// For SELECT statements only. Does NOT auto-commit.
    ///
    /// # SQLx-style usage
    ///
    /// ```ignore
    /// let id: i32 = 1;
    /// let age: i32 = 18;
    /// let rows = client.query_with_params(
    ///     "SELECT * FROM person WHERE id > ? AND age > ?",
    ///     &[&id, &age],
    /// )?;
    /// ```
    pub fn query_with_params(
        &mut self,
        sql: &str,
        params: &[&dyn dameng_types::ToDmValue],
    ) -> Result<ResultSet> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }

        let bind_params: Vec<BindParam> = params.iter().map(|p| to_bind_param(*p)).collect();
        self.do_prepare_execute(&bind_params, sql, true)
    }

    /// Internal: execute SQL with pre-built BindParams (shared by sqlx/query builder modules).
    #[allow(unused)]
    pub(crate) fn do_execute_with_bind_params(
        &mut self,
        sql: &str,
        has_result_set: bool,
        params: &[BindParam],
    ) -> Result<ResultSet> {
        self.do_prepare_execute(params, sql, has_result_set)
    }

    /// Substitute ? placeholders with SQL literal values.
    fn substitute_params(sql: &str, params: &[BindParam]) -> String {
        let mut result = String::with_capacity(sql.len() + params.len() * 16);
        let mut pi = 0;
        for b in sql.bytes() {
            if b == b'?' && pi < params.len() {
                let lit = Self::bind_param_literal(&params[pi]);
                result.push_str(&lit);
                pi += 1;
            } else {
                result.push(b as char);
            }
        }
        result
    }

    /// Convert a BindParam to a SQL literal string.
    fn bind_param_literal(p: &BindParam) -> String {
        match &p.value {
            None => "NULL".to_string(),
            Some(v) => match p.type_code {
                // BIT
                1 => format!("{}", v.first().copied().unwrap_or(0)),
                // VARCHAR, CLOB — quoted (match before numeric range 2..=6)
                3 | 14 => {
                    let s = String::from_utf8_lossy(v);
                    format!("'{}'", s.replace('\'', "''"))
                }
                // Numeric: TINYINT(2)/SMALLINT(6)/INT(4)/BIGINT(5)
                2 | 6 | 4 | 5 => {
                    if v.len() <= 8 {
                        let mut buf = [0u8; 8];
                        buf[..v.len()].copy_from_slice(v);
                        match v.len() {
                            1 => format!("{}", buf[0] as i8),
                            2 => format!("{}", i16::from_le_bytes([buf[0], buf[1]])),
                            4 => {
                                format!("{}", i32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]))
                            }
                            8 => format!("{}", i64::from_le_bytes(buf)),
                            _ => String::from_utf8_lossy(v).to_string(),
                        }
                    } else {
                        String::from_utf8_lossy(v).to_string()
                    }
                }
                // FLOAT(7)/DOUBLE(8)
                7 | 8 => {
                    if v.len() == 4 {
                        format!("{}", f32::from_le_bytes([v[0], v[1], v[2], v[3]]))
                    } else if v.len() == 8 {
                        format!(
                            "{}",
                            f64::from_le_bytes([v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]])
                        )
                    } else {
                        String::from_utf8_lossy(v).to_string()
                    }
                }
                // DECIMAL (sent as string)
                9 => String::from_utf8_lossy(v).to_string(),
                // DATE, TIME, TIMESTAMP — quoted string
                10 | 11 | 12 => {
                    let s = String::from_utf8_lossy(v);
                    format!("'{}'", s.replace('\'', "''"))
                }
                // BLOB, VARBINARY — hex
                13 | 18 => {
                    let h: String = v.iter().map(|b| format!("{:02x}", b)).collect();
                    format!("0x{}", h)
                }
                _ => {
                    let h: String = v.iter().map(|b| format!("{:02x}", b)).collect();
                    format!("0x{}", h)
                }
            },
        }
    }

    /// Core execution: READY → OPTIMIZED_PREPARE_EXEC (OPE(91)) for no params,
    /// or text substitution + OPE(91) for params.
    ///
    /// All SQL execution flows through this single method. The `params` slice
    /// may be empty (no parameters) or contain bound parameters. The `has_result_set`
    /// flag controls whether the server returns rows (SELECT) or affected count (DML).
    fn do_prepare_execute(
        &mut self,
        params: &[BindParam],
        sql: &str,
        has_result_set: bool,
    ) -> Result<ResultSet> {
        // No params: use OPE(91) fast path — single message, prepare + execute.
        if params.is_empty() {
            let ready_frame = Frame::new(READY, 0, 0);
            self.write_all(&ready_frame.encode())?;
            self.read_message()?;

            let exec = ExecMessage::new(sql, 0);
            self.write_all(&build_message(
                OPTIMIZED_PREPARE_EXEC,
                0,
                &exec.encode_payload(),
            ))?;

            let rs = match self.read_exec_response(has_result_set) {
                Ok(r) => r,
                Err(e) => {
                    // On DML error, send ROLLBACK to clean up connection state
                    if !has_result_set {
                        let _ = self.rollback();
                    }
                    return Err(e);
                }
            };

            if self.auto_commit && !has_result_set {
                self.do_commit()?;
            }
            return Ok(rs);
        }

        // With params: use text substitution + OPE(91) no-params path.
        // DM 8.1.3.62 does NOT support OPE(91) with embedded params or BIND_EXEC2
        // inline data — substitute values into SQL text and use the OPE(91) no-params path.
        let substituted = Self::substitute_params(sql, params);
        self.write_all(&Frame::new(READY, 0, 0).encode())?;
        self.read_message()?;
        let exec = ExecMessage::new(&substituted, 0);
        self.write_all(&build_message(
            OPTIMIZED_PREPARE_EXEC,
            0,
            &exec.encode_payload(),
        ))?;
        let rs = self.read_exec_response(has_result_set)?;
        if self.auto_commit && !has_result_set {
            self.do_commit()?;
        }
        return Ok(rs);
    }

    /// Stream LOB data for off-row params (BLOB/CLOB > 2048 bytes).
    #[allow(unused)]
    fn stream_lob_params(&mut self, stmt_id: u32, params: &[BindParam]) -> Result<()> {
        let off_row_params: Vec<usize> = params
            .iter()
            .enumerate()
            .filter(|(_, p)| {
                let is_lob = p.type_code == 13 || p.type_code == 14;
                is_lob && p.value.as_ref().map_or(false, |v| v.len() > 2048)
            })
            .map(|(i, _)| i)
            .collect();

        for &param_idx in &off_row_params {
            let param = &params[param_idx];
            if let Some(ref data) = param.value {
                for chunk in &split_lob_data(data) {
                    let lob_msg = LobDataMessage::new(param_idx as i16, chunk.clone());
                    let lob_payload = lob_msg.encode_payload(self.new_lob_flag);
                    self.write_all(&build_message(DM_LOB_DATA_MSG_TYPE, stmt_id, &lob_payload))?;
                    let (lob_frame, _) = self.read_message()?;
                    if lob_frame.response_code < 0 {
                        return Err(Error::QueryFailed(format!(
                            "LOB stream failed for param {}: code={}",
                            param_idx, lob_frame.response_code
                        )));
                    }
                }
            }
        }

        Ok(())
    }

    /// Clone params, clearing value for off-row LOB placeholders.
    #[allow(unused)]
    fn clear_off_row_placeholders(&self, params: &[BindParam]) -> Vec<BindParam> {
        let off_row_params: Vec<usize> = params
            .iter()
            .enumerate()
            .filter(|(_, p)| {
                let is_lob = p.type_code == 13 || p.type_code == 14;
                is_lob && p.value.as_ref().map_or(false, |v| v.len() > 2048)
            })
            .map(|(i, _)| i)
            .collect();

        params
            .iter()
            .enumerate()
            .map(|(i, p)| {
                if off_row_params.contains(&i) {
                    let mut modified = p.clone();
                    modified.value = Some(vec![]);
                    modified
                } else {
                    p.clone()
                }
            })
            .collect()
    }

    /// Fetch all rows from a BIND_EXEC2 result using FETCH protocol.
    ///
    /// When BIND_EXEC2 returns col_count=0 but total_row_count > 0,
    /// the data must be retrieved via FETCH messages.
    #[allow(unused)]
    fn fetch_from_bind_exec(&mut self, stmt_id: u32, total_rows: u64) -> Result<ResultSet> {
        let mut all_columns = Vec::new();
        let mut all_rows = Vec::new();

        let mut start_row: i64 = 0;
        let prefetch = 65536i32;

        loop {
            let fetch = FetchMessage::new(start_row, 0, prefetch);
            let fetch_payload = fetch.encode_payload();
            // Use connection handle (self.handle), not stmt_id, matching fetch_more()
            self.write_all(&build_message(FETCH, self.handle, &fetch_payload))?;

            let (frame, payload) = self.read_message()?;
            if frame.response_code < 0 {
                let msg = String::from_utf8_lossy(&payload);
                return Err(Error::QueryFailed(format!(
                    "fetch failed: code={} type={} payload={}",
                    frame.response_code, frame.msg_type, msg
                )));
            }

            let fetch_resp = FetchResponse::from_bytes(&payload, self.server_encoding)
                .map_err(|e| Error::Protocol(e))?;

            // Collect columns from first fetch response
            if all_columns.is_empty() && !fetch_resp.columns.is_empty() {
                all_columns = fetch_resp.columns;
            }

            let fetched_rows = fetch_resp.rows;
            let fetched_count = fetched_rows.len();
            all_rows.extend(fetched_rows);
            start_row += fetched_count as i64;

            if start_row >= fetch_resp.total_row_count as i64 || fetched_count == 0 {
                break;
            }
        }

        Ok(ResultSet::with_data(all_columns, all_rows, 0, total_rows))
    }

    /// Set transaction isolation level.
    ///
    /// Sends a SET_ISOLATION (type 52) message to the DM server.
    /// Supported levels: ReadUncommitted, ReadCommitted, RepeatableRead, Serializable.
    pub fn set_isolation(&mut self, level: IsolationLevel) -> Result<()> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }
        let msg = SetIsolationMessage::new(level);
        let frame = msg.encode_frame(self.handle);
        self.write_all(&frame)?;
        let (frame, payload) = self.read_message()?;
        if frame.response_code < 0 {
            let msg = decode_error_msg(self.server_encoding, &payload);
            return Err(Error::QueryFailed(format!(
                "set isolation failed: code={} type={} payload={}",
                frame.response_code, frame.msg_type, msg
            )));
        }
        self.isolation_level = level;
        Ok(())
    }

    /// Get current transaction isolation level.
    pub fn get_isolation_level(&self) -> IsolationLevel {
        self.isolation_level
    }

    /// Execute a SQL statement and return the number of affected rows.
    /// Use for DML: INSERT, UPDATE, DELETE, CREATE, DROP, COMMIT, ROLLBACK.
    /// When auto_commit is true (default), a COMMIT is sent after each statement.
    pub fn execute(&mut self, sql: &str) -> Result<u64> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }
        let rs = self.do_prepare_execute(&[], sql, false)?;
        Ok(rs.total_row_count)
    }

    /// Internal commit - sends the COMMIT protocol message.
    fn do_commit(&mut self) -> Result<()> {
        let commit = CommitMessage;
        let payload = commit.encode_payload();
        self.write_all(&build_message(COMMIT, self.handle, &payload))?;
        let (frame, _payload) = self.read_message()?;
        if frame.msg_type != ACK && frame.msg_type != EXEC_RESPONSE {
            return Err(Error::ConnectionFailed(format!(
                "expected ACK/EXEC_RESPONSE for COMMIT got msg_type={}",
                frame.msg_type
            )));
        }
        if frame.response_code < 0 {
            return Err(Error::ConnectionFailed(format!(
                "COMMIT failed with resp_code={}",
                frame.response_code
            )));
        }
        Ok(())
    }

    /// Commit with affected rows - sends COMMIT and reads queued EXEC_RESPONSE first.
    /// After OPE(91) DML, DM queues the EXEC_RESPONSE and sends it when we issue the
    #[allow(unused)]
    fn do_commit_with_affected(&mut self) -> Result<u64> {
        // Send READY to trigger the server to flush queued EXEC_RESPONSE
        let ready_frame = Frame::new(READY, 0, 0);
        self.write_all(&ready_frame.encode())?;

        // Read ALL messages until we find an EXEC_RESPONSE or get nothing
        let mut affected = 0u64;
        loop {
            match self.try_read_message(std::time::Duration::from_millis(200)) {
                Some(Ok((frame, payload))) => {
                    if frame.response_code < 0 {
                        return Err(Error::QueryFailed(format!(
                            "response_code={}",
                            frame.response_code
                        )));
                    }

                    // EXEC_RESPONSE(0) or type 160 contains the actual result data
                    if frame.msg_type == EXEC_RESPONSE || frame.msg_type == 160 {
                        if payload.len() >= 16 {
                            // offset 12 = row_count in EXEC_RESPONSE payload
                            affected = u32::from_le_bytes([
                                payload[12],
                                payload[13],
                                payload[14],
                                payload[15],
                            ]) as u64;
                        }
                        break;
                    }

                    // ACK(187) with data might also contain result
                    if frame.msg_type == ACK && payload.len() >= 16 {
                        // Check if this looks like EXEC_RESPONSE data
                        affected = u32::from_le_bytes([
                            payload[12],
                            payload[13],
                            payload[14],
                            payload[15],
                        ]) as u64;
                    }
                    // Empty ACK means we're done
                    if frame.msg_type == ACK && payload.is_empty() {
                        break;
                    }
                }
                Some(Err(e)) => return Err(e),
                None => break,
            }
        }

        // Now send actual COMMIT
        let commit = CommitMessage;
        let payload = commit.encode_payload();
        self.write_all(&build_message(COMMIT, self.handle, &payload))?;

        // Read COMMIT response
        let (frame2, _p2) = self.read_message()?;
        if frame2.response_code < 0 {
            return Err(Error::ConnectionFailed(format!(
                "COMMIT failed with resp_code={}",
                frame2.response_code
            )));
        }

        Ok(affected)
    }

    /// Read an EXEC_RESPONSE and parse into Rows.
    ///
    /// For OPE(91) the server may send a sequence of messages:
    ///   ACK(187) with data → ACK(187) empty → EXEC_RESPONSE(0) with data
    /// We consume all of them and extract affected row count / result data.
    ///
    /// `has_result_set` indicates whether this is a SELECT query (true) or DML (false).
    /// For SELECT queries via OPE(91), the server returns a single ACK with inline
    /// data — no trailing messages to consume.
    /// For DML via OPE(91), the server returns an empty ACK (update_count in header)
    /// with no trailing messages either.
    /// For BIND_EXEC2 SELECT queries, the server returns col_count=0 and we should
    /// not try to parse inline data — it must be fetched via FETCH.
    fn read_exec_response(&mut self, has_result_set: bool) -> Result<ResultSet> {
        let (frame, payload) = self.read_message()?;

        // Check for error response (negative response_code)
        if frame.response_code < 0 {
            let mut error_detail = format!("response_code={}", frame.response_code);
            if payload.len() >= 16 {
                let msg_len = u32::from_le_bytes([
                    payload[12],
                    payload.get(13).copied().unwrap_or(0),
                    payload.get(14).copied().unwrap_or(0),
                    payload.get(15).copied().unwrap_or(0),
                ]) as usize;
                if msg_len > 0 && payload.len() >= 16 + msg_len {
                    let msg = decode_error_msg(self.server_encoding, &payload[16..16 + msg_len]);
                    error_detail = format!("{}: {}", frame.response_code, msg);
                }
            }
            return Err(Error::QueryFailed(error_detail));
        }

        if frame.msg_type == EXPLAIN_RESPONSE {
            let response = ExplainResponse::from_bytes(&payload, self.server_encoding)?;
            let display_size = u32::try_from(response.plan.len()).unwrap_or(u32::MAX);
            let columns = vec![Column {
                name: "PLAN".to_string(),
                type_code: dm_type::VARCHAR,
                type_name: "VARCHAR".to_string(),
                precision: display_size,
                scale: 0,
                nullable: false,
                display_size,
                table_name: String::new(),
                schema_name: String::new(),
                lob_tab_id: 0,
                lob_col_id: 0,
            }];
            let rows = vec![Row {
                row_id: 0,
                values: vec![Some(response.plan.into_bytes())],
            }];
            return Ok(ResultSet::with_data(columns, rows, 0, 1));
        }

        if frame.msg_type == ACK && payload.is_empty() {
            // OPE(91) DML: empty ACK with affected rows in header reserved area at offset 24.
            let affected = frame.update_count;
            return Ok(ResultSet::with_data(Vec::new(), Vec::new(), 0, affected));
        }

        if frame.msg_type == ACK {
            // OPE(91) SELECT: ACK with inline row data in payload.
            // For SELECT queries this is the complete response — no trailing messages.
            // For DML queries there may be trailing messages, handled after parsing.
            let resp = ExecResponse::from_bytes(&payload, self.server_encoding)?;
            // OPE offset 12 describes result metadata, not the number of rows. It
            // remains nonzero for an empty SELECT, which would otherwise trigger
            // an invalid FETCH against a response that is already complete.
            let mut total = resp.rows.len() as u64;
            if !has_result_set {
                // DML with trailing messages (rare path)
                let trailing = self.consume_remaining_ope_messages()?;
                if total == 0 {
                    total = trailing;
                }
            }
            return Ok(ResultSet::with_data(resp.columns, resp.rows, 0, total));
        }

        if frame.msg_type == EXEC_RESPONSE || frame.msg_type == 160 {
            let resp = ExecResponse::from_bytes(&payload, self.server_encoding)?;

            // For BIND_EXEC2 SELECT queries: server returns col_count=0.
            // Do NOT parse inline data (it's garbage) — let the caller use FETCH.
            if has_result_set && resp.col_count == 0 && !resp.columns.is_empty() {
                // This shouldn't happen if guard is correct, but be safe.
                // Fall through to normal path.
            } else if has_result_set && resp.col_count == 0 && resp.columns.is_empty() {
                // BIND_EXEC2 SELECT: no inline data, will be fetched via FETCH.
                return Ok(ResultSet::with_data(
                    Vec::new(),
                    Vec::new(),
                    0,
                    resp.row_count as u64,
                ));
            }

            return Ok(ResultSet::with_data(
                resp.columns,
                resp.rows,
                0,
                resp.row_count as u64,
            ));
        }

        Err(Error::ConnectionFailed(format!(
            "unexpected response msg_type={}",
            frame.msg_type
        )))
    }

    /// Consume remaining messages after an OPE(91) response.
    /// The server may send trailing ACK(empty) and/or EXEC_RESPONSE messages
    /// that need to be consumed to keep the connection in sync.
    /// Returns the affected row count from the frame header if found.
    fn consume_remaining_ope_messages(&mut self) -> Result<u64> {
        let mut affected = 0u64;

        // Try to read one more message with a short timeout
        if let Some(Ok((frame, payload))) =
            self.try_read_message(std::time::Duration::from_millis(2000))
        {
            if frame.response_code < 0 {
                return Err(Error::QueryFailed(format!(
                    "response_code={}",
                    frame.response_code
                )));
            }
            // If we got an empty ACK, try one more (EXEC_RESPONSE with affected rows in frame header)
            if frame.msg_type == ACK && payload.is_empty() {
                if let Some(Ok((f3, _p3))) =
                    self.try_read_message(std::time::Duration::from_millis(2000))
                {
                    if f3.response_code < 0 {
                        return Err(Error::QueryFailed(format!(
                            "response_code={}",
                            f3.response_code
                        )));
                    }
                    // Affected rows in frame header offset 14-17
                    affected = f3.affected_rows as u64;
                }
            }
            // Also check if this message itself has affected rows in frame header
            if frame.msg_type == EXEC_RESPONSE {
                affected = frame.affected_rows as u64;
            }
        }

        Ok(affected)
    }

    /// Try to read a single message with polling.
    /// The `timeout` is the maximum time to wait for data.
    /// Returns None if no message arrives within the timeout.
    /// Some(Ok(...)) on success, Some(Err(...)) on error.
    fn try_read_message(
        &mut self,
        timeout: std::time::Duration,
    ) -> Option<Result<(Frame, Vec<u8>)>> {
        use std::io::ErrorKind;

        let stream = self.stream.as_mut()?;
        let deadline = std::time::Instant::now() + timeout;
        let mut buf = BytesMut::with_capacity(FRAME_HEADER_SIZE + 4096);

        // Read frame header with polling
        loop {
            if buf.len() >= FRAME_HEADER_SIZE {
                break;
            }
            if std::time::Instant::now() > deadline {
                return None;
            }
            let needed = FRAME_HEADER_SIZE - buf.len();
            let mut tmp = vec![0u8; needed];
            match stream.read(&mut tmp) {
                Ok(0) => return None,
                Ok(n) => buf.extend_from_slice(&tmp[..n]),
                Err(e) if e.kind() == ErrorKind::WouldBlock || e.raw_os_error() == Some(35) => {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                Err(e) => return Some(Err(Error::Io(e))),
            }
        }

        let frame = match Frame::parse(&mut buf) {
            Ok(f) => f,
            Err(_) => return None,
        };

        // Read payload with polling
        let body_len = match checked_response_body_len(frame.body_len) {
            Ok(length) => length,
            Err(error) => return Some(Err(error)),
        };
        while buf.len() < body_len {
            if std::time::Instant::now() > deadline {
                return None;
            }
            let needed = body_len - buf.len();
            let mut tmp = vec![0u8; needed.min(4096)];
            match stream.read(&mut tmp) {
                Ok(0) => {
                    return Some(Err(Error::ConnectionFailed(
                        "connection closed during payload read".to_string(),
                    )))
                }
                Ok(n) => buf.extend_from_slice(&tmp[..n]),
                Err(e) if e.kind() == ErrorKind::WouldBlock || e.raw_os_error() == Some(35) => {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                Err(e) => return Some(Err(Error::Io(e))),
            }
        }

        Some(Ok((frame, buf[..body_len].to_vec())))
    }

    /// Execute a SQL SELECT query and return the result set.
    ///
    /// Does NOT auto-commit (SELECT queries should not trigger commits).
    pub fn query(&mut self, sql: &str) -> Result<ResultSet> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }
        self.do_prepare_execute(&[], sql, true)
    }

    /// Fetch more rows from a result set using the FETCH protocol (msg_type=7).
    ///
    /// # Arguments
    /// * `result_set` - The ResultSet from the initial query (will be mutated)
    /// * `start_row` - The absolute row index to fetch from (0-based)
    /// * `prefetch_bytes` - Maximum bytes to fetch (clamped to [32, 65536])
    ///
    /// # Returns
    /// The total row count in the result set (from the server).
    ///
    /// # Example
    /// ```ignore
    /// let mut rs = client.query("SELECT * FROM large_table")?;
    /// let batch_size = 100;
    /// while rs.rows.len() < rs.total_row_count as usize {
    ///     let fetched = client.fetch_more(&mut rs, rs.rows.len(), 8192)?;
    ///     // Process new rows from rs.rows[previous_len..]
    /// }
    /// ```
    pub fn fetch_more(
        &mut self,
        result_set: &mut ResultSet,
        start_row: usize,
        prefetch_bytes: i32,
    ) -> Result<u64> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }

        // Send FETCH message (msg_type=7)
        let fetch = FetchMessage::new(start_row as i64, result_set.cursor_id, prefetch_bytes);
        let fetch_payload = fetch.encode_payload();
        self.write_all(&build_message(FETCH, self.handle, &fetch_payload))?;

        let (frame, payload) = self.read_message()?;
        if frame.response_code < 0 {
            let msg = String::from_utf8_lossy(&payload);
            return Err(Error::QueryFailed(format!(
                "fetch failed: code={} type={} payload={}",
                frame.response_code, frame.msg_type, msg
            )));
        }

        // Parse FETCH response
        let fetch_resp = FetchResponse::from_bytes(&payload, self.server_encoding)
            .map_err(|e| Error::Protocol(e))?;

        // Append new rows to the result set
        result_set.rows.extend(fetch_resp.rows);

        // Update total row count from server response
        result_set.total_row_count = fetch_resp.total_row_count as u64;

        // Merge columns if fetch response includes column metadata
        if result_set.columns.is_empty() && !fetch_resp.columns.is_empty() {
            result_set.columns = fetch_resp.columns;
        }

        Ok(result_set.total_row_count)
    }

    /// Send a READY keepalive and read the ACK.
    pub fn ready(&mut self) -> Result<()> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }
        let ready = ReadyMessage::new();
        let payload = ready.encode_payload();
        self.write_all(&build_message(READY, self.handle, &payload))?;
        let (frame, _) = self.read_message()?;
        if frame.msg_type != ACK {
            return Err(Error::ConnectionFailed(format!(
                "expected ACK for READY got msg_type={}",
                frame.msg_type
            )));
        }
        Ok(())
    }

    /// Commit the current transaction and re-enable auto-commit.
    pub fn commit(&mut self) -> Result<()> {
        self.do_commit()?;
        self.auto_commit = true;
        // COMMIT may also invalidate the server-side statement handle.
        // Reset to 0 so the next execute() will allocate a fresh one.
        self.handle = 0;
        Ok(())
    }

    /// Rollback the current transaction and re-enable auto-commit.
    pub fn rollback(&mut self) -> Result<()> {
        let rollback = RollbackMessage;
        let payload = rollback.encode_payload();
        self.write_all(&build_message(ROLLBACK, self.handle, &payload))?;
        let (frame, _) = self.read_message()?;
        if frame.msg_type != ACK && frame.msg_type != EXEC_RESPONSE {
            return Err(Error::ConnectionFailed(format!(
                "expected ACK/EXEC_RESPONSE for ROLLBACK got msg_type={}",
                frame.msg_type
            )));
        }
        if frame.response_code < 0 {
            return Err(Error::ConnectionFailed(format!(
                "ROLLBACK failed with resp_code={}",
                frame.response_code
            )));
        }
        self.auto_commit = true;
        // ROLLBACK invalidates the server-side statement handle (-2106).
        // Reset to 0 so the next execute() will allocate a fresh one.
        self.handle = 0;
        Ok(())
    }

    /// Read a complete message (frame + payload) from the stream.
    /// Reads exactly one frame at a time — never over-reads past the current
    /// frame boundary, because over-read data would be silently dropped.
    fn read_message(&mut self) -> Result<(Frame, Vec<u8>)> {
        use std::io::ErrorKind;

        let stream = self.stream.as_mut().ok_or(Error::NotConnected)?;
        let mut buf = BytesMut::with_capacity(FRAME_HEADER_SIZE + 4096);

        // Read header using BytesMut chunk for zero-copy
        while buf.len() < FRAME_HEADER_SIZE {
            let needed = FRAME_HEADER_SIZE - buf.len();
            buf.reserve(needed);
            let chunk = buf.chunk_mut();
            // SAFETY: we will write to these bytes, making them initialized
            let dst = unsafe { std::slice::from_raw_parts_mut(chunk.as_mut_ptr(), chunk.len()) };
            let cap = dst.len().min(needed);
            let n = loop {
                match stream.read(&mut dst[..cap]) {
                    Ok(n) => break n,
                    Err(e) if e.kind() == ErrorKind::WouldBlock || e.raw_os_error() == Some(35) => {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                        continue;
                    }
                    Err(e) => return Err(Error::Io(e)),
                }
            };
            if n == 0 {
                return Err(Error::ConnectionFailed("connection closed".to_string()));
            }
            // SAFETY: we just read n bytes into the chunk
            unsafe {
                buf.advance_mut(n);
            }
        }

        let frame = Frame::parse(&mut buf)?;

        // Read payload using same zero-copy approach
        let body_len = checked_response_body_len(frame.body_len)?;
        while buf.len() < body_len {
            let needed = body_len - buf.len();
            buf.reserve(needed);
            let chunk = buf.chunk_mut();
            // SAFETY: we will write to these bytes, making them initialized
            let dst = unsafe { std::slice::from_raw_parts_mut(chunk.as_mut_ptr(), chunk.len()) };
            let cap = dst.len().min(needed);
            let n = loop {
                match stream.read(&mut dst[..cap]) {
                    Ok(n) => break n,
                    Err(e) if e.kind() == ErrorKind::WouldBlock || e.raw_os_error() == Some(35) => {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                        continue;
                    }
                    Err(e) => return Err(Error::Io(e)),
                }
            };
            if n == 0 {
                return Err(Error::ConnectionFailed(
                    "connection closed during payload read".to_string(),
                ));
            }
            unsafe {
                buf.advance_mut(n);
            }
        }

        let payload = buf[..body_len].to_vec();
        Ok((frame, payload))
    }

    /// Write data to the stream.
    fn write_all(&mut self, data: &[u8]) -> Result<()> {
        let stream = self.stream.as_mut().ok_or(Error::NotConnected)?;
        let total = data.len();
        let mut written = 0;
        while written < total {
            let n = stream.write(&data[written..])?;
            if n == 0 {
                return Err(Error::ConnectionFailed("broken pipe".to_string()));
            }
            written += n;
        }
        Ok(())
    }

    /// Gracefully close the connection to the server.
    ///
    /// Sends a CLOSE message to release server resources,
    /// then shuts down the TCP connection.
    pub fn close(&mut self) -> Result<()> {
        if !matches!(self.state, State::Ready) {
            return Ok(());
        }
        let close = CloseMessage;
        let payload = close.encode_payload();
        let _ = self.write_all(&build_message(CLOSE, self.handle, &payload));
        let _ = self.read_message();
        self.state = State::Closed;
        Ok(())
    }

    /// Read output parameter values after executing a stored procedure.
    ///
    /// When a stored procedure is executed with OUTPUT or INPUT_OUTPUT parameters,
    /// the server returns the output values in the EXEC_RESPONSE frame. This method
    /// extracts those raw byte values so they can be decoded with
    /// `parse_output_param_value()`.
    ///
    /// # Arguments
    /// * `params` - The original `BindParam` slice used in the execute call.
    ///              Only parameters with `direction` of `Output` or `InputOutput` are included.
    ///
    /// # Returns
    /// A vector of `(type_code, raw_bytes)` tuples, one per output parameter,
    /// in the same order as the input parameters. Empty byte vectors indicate NULL.
    pub fn read_output_params(&self, params: &[BindParam]) -> Vec<(i32, Vec<u8>)> {
        params
            .iter()
            .filter(|p| {
                p.direction == dameng_protocol::message::bind::ParameterDirection::Output
                    || p.direction
                        == dameng_protocol::message::bind::ParameterDirection::InputOutput
            })
            .map(|p| {
                let raw = p.value.clone().unwrap_or_default();
                (p.type_code, raw)
            })
            .collect()
    }

    /// Read the full content of a LOB (CLOB/BLOB) identified by a locator.
    ///
    /// This method first gets the LOB length via LOBGETLEN (msg_type=31),
    /// then reads the content in chunks via LOBREAD (msg_type=32).
    ///
    /// Returns `Ok(String)` for CLOB or `Ok(Vec<u8>)` for BLOB.
    ///
    /// **Important**: The LOB locator is only valid within the current transaction.
    /// If auto_commit is enabled, the locator may be invalidated after the query
    /// that produced it is committed. In that case, disable auto_commit before
    /// calling this method.
    pub fn read_lob(&mut self, locator: &dameng_types::LobLocator) -> Result<Vec<u8>> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }

        // Step 1: Get LOB length via LOBGETLEN (msg_type=31)
        let getlen_msg = LobGetLenMessage::new(locator.clone());
        let getlen_payload = getlen_msg.encode_payload(self.new_lob_flag);
        self.write_all(&build_message(LOB_GETLEN, self.handle, &getlen_payload))?;
        let (getlen_frame, getlen_resp_payload) = self.read_message()?;
        if getlen_frame.response_code < 0 {
            return Err(Error::QueryFailed(format!(
                "LOBGETLEN failed: code={} type={}",
                getlen_frame.response_code, getlen_frame.msg_type
            )));
        }
        let getlen_resp = LobGetLenResponse::from_bytes(&getlen_resp_payload)?;
        let total_len = checked_lob_len(getlen_resp.length)?;

        if total_len == 0 {
            return Ok(vec![]);
        }

        // Apply new_blob_id from server if provided (matching Go driver)
        let mut cur_locator = locator.clone();
        if let Some(new_id) = getlen_resp.new_blob_id {
            // Update blob_id in the raw NBLOB_HEAD (offset 1, 8 bytes)
            if cur_locator.raw.len() >= 9 {
                cur_locator.raw[1..9].copy_from_slice(&new_id.to_le_bytes());
            }
        }
        cur_locator.init_cursor();

        // Step 2: Read LOB data in chunks via LOBREAD (msg_type=32)
        // Max chunk: 16384 bytes for BLOB, 8192 chars for CLOB
        let max_chunk = if locator.is_clob { 8192 } else { 16384 };

        let mut result = Vec::with_capacity(total_len);
        let mut position: i32 = 0;
        cur_locator.init_cursor();

        while (position as usize) < total_len {
            let remaining = total_len - position as usize;
            let chunk_size = std::cmp::min(remaining, max_chunk) as i32;

            // Send LOBREAD
            let read_msg =
                LobReadMessage::new(cur_locator.clone(), position, chunk_size, self.new_lob_flag);
            let read_payload = read_msg.encode_payload();
            self.write_all(&build_message(LOB_READ, self.handle, &read_payload))?;
            let (read_frame, read_resp_payload) = self.read_message()?;
            if read_frame.response_code < 0 {
                return Err(Error::QueryFailed(format!(
                    "LOBREAD failed at pos {}: code={} type={}",
                    position, read_frame.response_code, read_frame.msg_type
                )));
            }
            let read_resp = LobReadResponse::from_bytes(&read_resp_payload)?;

            if read_resp.data.is_empty() {
                break;
            }

            if result.len().saturating_add(read_resp.data.len()) > MAX_LOB_BYTES {
                return Err(Error::Protocol(dameng_protocol::Error::InvalidFrame(
                    format!("LOB content exceeds {MAX_LOB_BYTES} bytes"),
                )));
            }
            result.extend_from_slice(&read_resp.data);

            // For CLOB: advance by character count (charLen if available)
            if locator.is_clob && read_resp.char_len > 0 {
                position += read_resp.char_len as i32;
            } else {
                position += read_resp.data.len() as i32;
            }

            // Update cursor state from response for next LOBREAD
            cur_locator.update_cursor(
                read_resp.cur_file_id,
                read_resp.cur_page_no,
                read_resp.total_offset,
            );

            if read_resp.read_over {
                break;
            }
        }

        Ok(result)
    }

    /// Free a LOB locator on the server via LOBFREE (msg_type=29).
    ///
    /// After reading a LOB's data, this releases the server-side LOB handle.
    /// This is especially important for long-lived connections where LOB
    /// handles could accumulate on the server.
    pub fn free_lob(&mut self, locator: &dameng_types::LobLocator) -> Result<()> {
        if !matches!(self.state, State::Ready) {
            return Err(Error::NotConnected);
        }

        let free_msg = LobFreeMessage::new(locator.clone());
        let free_payload = free_msg.encode_payload(self.new_lob_flag);
        self.write_all(&build_message(LOB_FREE, self.handle, &free_payload))?;
        let (free_frame, _) = self.read_message()?;
        if free_frame.response_code < 0 {
            return Err(Error::QueryFailed(format!(
                "LOBFREE failed: code={} type={}",
                free_frame.response_code, free_frame.msg_type
            )));
        }

        Ok(())
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        if matches!(self.state, State::Ready) {
            let _ = self.close();
        }
        if let Some(mut stream) = self.stream.take() {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
        self.state = State::Closed;
    }
}

/// Build a complete message (frame + payload).
pub fn build_message(msg_type: u8, handle: u32, payload: &[u8]) -> Vec<u8> {
    let frame = Frame::new(msg_type, handle, payload.len() as i32);
    let mut result = frame.encode().to_vec();
    result.extend_from_slice(payload);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_client_new() {
        let client = Client::new("localhost", 5236);
        assert_eq!(client.host, "localhost");
        assert_eq!(client.port, 5236);
        assert_eq!(client.state, State::Closed);
    }

    #[test]
    fn test_build_message_size() {
        let msg = build_message(5, 1, b"SELECT 1");
        assert_eq!(msg.len(), FRAME_HEADER_SIZE + 8);
    }

    #[test]
    fn test_build_message_frame() {
        let msg = build_message(200, 0, &[0u8; 10]);
        let mut buf = BytesMut::from(&msg[..]);
        let frame = Frame::parse(&mut buf).unwrap();
        assert_eq!(frame.msg_type, 200);
        assert_eq!(frame.handle, 0);
        assert_eq!(frame.body_len, 10);
    }

    #[test]
    fn test_state_transitions() {
        let client = Client::new("test", 5236);
        assert_eq!(client.state, State::Closed);
    }

    #[test]
    fn test_execute_not_connected() {
        let mut client = Client::new("test", 5236);
        let result = client.execute("SELECT 1");
        assert!(matches!(result, Err(Error::NotConnected)));
    }

    #[test]
    fn test_ready_not_connected() {
        let mut client = Client::new("test", 5236);
        let result = client.ready();
        assert!(matches!(result, Err(Error::NotConnected)));
    }

    #[test]
    fn test_lob_length_is_bounded() {
        assert_eq!(
            checked_lob_len(MAX_LOB_BYTES as i64).unwrap(),
            MAX_LOB_BYTES
        );
        assert!(checked_lob_len(-1).is_err());
        assert!(checked_lob_len(MAX_LOB_BYTES as i64 + 1).is_err());
    }
}
