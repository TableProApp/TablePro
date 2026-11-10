use std::ffi::OsString;
use std::io::Write;

use clap_complete::aot::Generator;

use crate::command_error::CommandError;
use crate::command_line::{self, Command, Shell};
use crate::commands;
use crate::console::Console;
use crate::exit::Exit;
use crate::host::Host;

pub fn run(
    args: Vec<OsString>,
    host: &(impl Host + Clone + Send + Sync + 'static),
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Exit {
    let mut console = Console::new(out, err, host.terminal());
    let version = host.app_version();
    let cli = match command_line::parse(args, &version) {
        Ok(cli) => cli,
        Err(error) => return console.parse_failed(&error),
    };
    match cli.command {
        None | Some(Command::Open(_)) => console.fail(&CommandError::OpensInApp),
        Some(Command::Completion(arguments)) => completion(arguments.shell, &version, &mut console),
        Some(command) => commands::execute(command, host, &mut console),
    }
}

fn completion(shell: Shell, version: &str, console: &mut Console<'_>) -> Exit {
    let mut command = command_line::command(version);
    command.build();
    let mut script = Vec::new();
    let written = shell
        .generator()
        .try_generate(&command, &mut script)
        .map_err(CommandError::Output)
        .and_then(|()| console.write_out(&script));
    match written {
        Ok(()) => Exit::Success,
        Err(error) => console.fail(&error),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::io::Read;
    use std::net::SocketAddr;
    use std::sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    };

    use super::*;
    use crate::host::{HostError, Terminal};

    #[derive(Clone)]
    pub(crate) struct Offline {
        running: bool,
        enabled: bool,
        terminal: Terminal,
    }

    impl Host for Offline {
        fn app_version(&self) -> String {
            "1.2.3".to_owned()
        }

        fn app_running(&self) -> bool {
            self.running
        }

        fn server_enabled(&self) -> Result<bool, HostError> {
            Ok(self.enabled)
        }

        fn server_port(&self) -> Result<u16, HostError> {
            Ok(1)
        }

        fn verify_peer(&self, _peer: SocketAddr, _local: SocketAddr) -> Result<(), HostError> {
            Ok(())
        }

        fn token(&self) -> Result<Option<String>, HostError> {
            Ok(None)
        }

        fn terminal(&self) -> Terminal {
            self.terminal
        }
    }

    pub(crate) const STOPPED: Offline = Offline {
        running: false,
        enabled: true,
        terminal: Terminal {
            stdin: false,
            stdout: false,
            stderr: false,
        },
    };

    // Counts each keyring read, and can find its port held by another user's program.
    #[derive(Clone)]
    struct Counted {
        running: bool,
        enabled: bool,
        ours: Arc<AtomicBool>,
        peer_checks: Arc<AtomicUsize>,
        port: u16,
        token: Option<&'static str>,
        token_reads: Arc<AtomicUsize>,
    }

    impl Counted {
        fn new(running: bool, enabled: bool, ours: bool, port: u16, token: Option<&'static str>) -> Self {
            Self {
                running,
                enabled,
                ours: Arc::new(AtomicBool::new(ours)),
                peer_checks: Arc::new(AtomicUsize::new(0)),
                port,
                token,
                token_reads: Arc::new(AtomicUsize::new(0)),
            }
        }
    }

    impl Host for Counted {
        fn app_version(&self) -> String {
            "1.2.3".to_owned()
        }

        fn app_running(&self) -> bool {
            self.running
        }

        fn server_enabled(&self) -> Result<bool, HostError> {
            Ok(self.enabled)
        }

        fn server_port(&self) -> Result<u16, HostError> {
            Ok(self.port)
        }

        fn verify_peer(&self, peer: SocketAddr, _local: SocketAddr) -> Result<(), HostError> {
            self.peer_checks.fetch_add(1, Ordering::SeqCst);
            match self.ours.load(Ordering::SeqCst) {
                true => Ok(()),
                false => Err(HostError::ForeignServer { port: peer.port() }),
            }
        }

        fn token(&self) -> Result<Option<String>, HostError> {
            self.token_reads.fetch_add(1, Ordering::SeqCst);
            Ok(self.token.map(str::to_owned))
        }

        fn terminal(&self) -> Terminal {
            Terminal::default()
        }
    }

    fn invoke(host: &(impl Host + Clone + Send + Sync + 'static), words: &[&str]) -> (Exit, String, String) {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let exit = run(words.iter().map(OsString::from).collect(), host, &mut out, &mut err);
        (
            exit,
            String::from_utf8(out).expect("UTF-8"),
            String::from_utf8(err).expect("UTF-8"),
        )
    }

    #[test]
    fn help_and_version_print_to_standard_output() {
        let (exit, out, err) = invoke(&STOPPED, &["tablepro", "--help"]);
        assert_eq!(exit, Exit::Success);
        assert!(out.contains("Usage: tablepro"), "{out}");
        assert!(out.contains("query"), "{out}");
        assert!(err.is_empty(), "{err}");

        let (exit, out, _) = invoke(&STOPPED, &["tablepro", "--version"]);
        assert_eq!((exit, out.as_str()), (Exit::Success, "tablepro 1.2.3\n"));
    }

    #[test]
    fn a_usage_error_goes_to_standard_error_with_status_two() {
        let (exit, out, err) = invoke(&STOPPED, &["tablepro", "query", "--format", "xml", "SELECT 1"]);

        assert_eq!(exit, Exit::Usage);
        assert!(out.is_empty(), "{out}");
        assert!(err.starts_with("error:"), "{err}");
    }

    #[test]
    fn each_shell_gets_its_completion_script() {
        for (shell, start) in [("zsh", "#compdef tablepro"), ("bash", "_tablepro()"), ("fish", "")] {
            let (exit, out, _) = invoke(&STOPPED, &["tablepro", "completion", shell]);
            assert_eq!(exit, Exit::Success, "{shell}");
            assert!(out.starts_with(start), "{shell}: {out}");
            assert!(out.contains("query"), "{shell}");
        }
    }

    #[test]
    fn a_stopped_app_or_a_server_turned_off_is_reported_before_any_request() {
        let (exit, _, err) = invoke(&STOPPED, &["tablepro", "connections"]);
        assert_eq!(exit, Exit::Failure);
        assert_eq!(
            err,
            "tablepro: TablePro is not running. Start it, then run the command again.\n"
        );

        let off = Offline {
            running: true,
            enabled: false,
            ..STOPPED
        };
        let (exit, _, err) = invoke(&off, &["tablepro", "connections"]);
        assert_eq!(exit, Exit::Refused);
        assert!(err.contains("Enable MCP Server"), "{err}");

        let started = Offline { enabled: true, ..off };
        let (exit, _, err) = invoke(&started, &["tablepro", "connections"]);
        assert_eq!(exit, Exit::Failure);
        assert!(err.contains("has not started"), "{err}");
    }

    #[test]
    fn missing_sql_on_a_terminal_is_a_usage_error_before_the_app_is_asked() {
        let typing = Offline {
            terminal: Terminal {
                stdin: true,
                ..Terminal::default()
            },
            ..STOPPED
        };

        let (exit, _, err) = invoke(&typing, &["tablepro", "query", "-c", "Staging"]);

        assert_eq!(exit, Exit::Usage);
        assert!(err.contains("Pass the SQL"), "{err}");
    }

    #[test]
    fn opening_is_left_to_the_app() {
        let (exit, _, _) = invoke(&STOPPED, &["tablepro", "app.db"]);

        assert_eq!(exit, Exit::Usage);
    }

    #[test]
    fn status_reports_every_reading_and_exits_as_a_command_would() {
        let (exit, out, err) = invoke(&STOPPED, &["tablepro", "status", "--format", "csv"]);

        assert_eq!(exit, Exit::Failure);
        assert_eq!(
            out,
            "version,running,server_enabled,port,token_found,server_version,ready\n1.2.3,false,true,1,,,false\n"
        );
        assert!(err.contains("not running"), "{err}");
    }

    #[test]
    fn status_reads_the_token_only_when_a_command_would() {
        for (host, reads, token_found) in [
            (Counted::new(false, true, true, 1, None), 0, ""),
            (Counted::new(true, false, true, 1, None), 0, ""),
            (Counted::new(true, true, false, 1, None), 1, "false"),
            (Counted::new(true, true, true, 1, None), 1, "false"),
        ] {
            let (_, out, _) = invoke(&host, &["tablepro", "status", "--format", "csv"]);

            assert_eq!(host.token_reads.load(Ordering::SeqCst), reads, "{out}");
            let row = out.lines().nth(1).unwrap_or_default();
            assert_eq!(row.split(',').nth(4), Some(token_found), "{row}");
        }
    }

    #[test]
    fn a_port_another_program_holds_never_gets_the_token() {
        let squatter = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        squatter.set_nonblocking(true).expect("a non-blocking listener");
        let port = squatter.local_addr().expect("an address").port();
        let host = Counted::new(true, true, false, port, Some("tp_secret"));

        let (exit, _, err) = invoke(&host, &["tablepro", "connections"]);

        assert_eq!(exit, Exit::Failure);
        assert_eq!(
            err,
            format!(
                "tablepro: Another program holds port {port}, so the command did not send it TablePro's token. \
                 Quit that program, or pick another port in Preferences > MCP.\n"
            )
        );
        assert_eq!(host.token_reads.load(Ordering::SeqCst), 1);
        let (mut stream, _) = squatter.accept().expect("the connection being verified");
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(1)))
            .expect("a deadline");
        let mut bytes = Vec::new();
        stream.read_to_end(&mut bytes).expect("a closed connection");
        assert!(bytes.is_empty(), "the refused peer received request bytes");
    }

    #[tokio::test]
    async fn reused_connections_stay_verified_and_new_connections_are_checked_again() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("a port");
        let address = listener.local_addr().expect("an address");
        let host = Counted::new(true, true, true, address.port(), Some("tp_secret"));
        let http = crate::peer_verification::http_client(&host, address.port()).expect("a client");
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("a verified connection");
            for close in [false, true] {
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") {
                    request.push(stream.read_u8().await.expect("request headers"));
                }
                assert!(
                    String::from_utf8(request)
                        .expect("HTTP headers")
                        .contains("Bearer tp_secret")
                );
                let response = if close {
                    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                };
                stream.write_all(response.as_bytes()).await.expect("a response");
            }
            drop(stream);
            let (mut refused, _) = listener.accept().await.expect("a new connection");
            let mut bytes = Vec::new();
            refused
                .read_to_end(&mut bytes)
                .await
                .expect("the refused connection closes");
            assert!(bytes.is_empty(), "a new unverified connection received bytes");
        });
        let exchange = async {
            for _ in 0..2 {
                http.get(format!("http://{address}/mcp"))
                    .bearer_auth("tp_secret")
                    .send()
                    .await
                    .expect("a verified request")
                    .bytes()
                    .await
                    .expect("the response body");
            }
            assert_eq!(host.peer_checks.load(Ordering::SeqCst), 1);
            host.ours.store(false, Ordering::SeqCst);
            assert!(
                http.get(format!("http://{address}/mcp"))
                    .bearer_auth("tp_secret")
                    .send()
                    .await
                    .is_err()
            );
            assert_eq!(host.peer_checks.load(Ordering::SeqCst), 2);
            server.await.expect("the listener saw no refused bytes");
        };
        tokio::time::timeout(std::time::Duration::from_secs(5), exchange)
            .await
            .expect("bounded exchanges");
    }
}
