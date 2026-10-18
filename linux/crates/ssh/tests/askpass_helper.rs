use std::io::{self, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Command, Output};
use std::thread;

const HELPER: &str = env!("CARGO_BIN_EXE_tablepro-askpass");

fn read_frame(stream: &mut UnixStream) -> io::Result<Vec<u8>> {
    let mut length = [0u8; 4];
    stream.read_exact(&mut length)?;
    let mut frame = vec![0u8; u32::from_be_bytes(length) as usize];
    stream.read_exact(&mut frame)?;
    Ok(frame)
}

fn write_frame(stream: &mut UnixStream, bytes: &[u8]) -> io::Result<()> {
    let length = u32::try_from(bytes.len()).map_err(io::Error::other)?;
    stream.write_all(&length.to_be_bytes())?;
    stream.write_all(bytes)
}

fn serve_once(listener: &UnixListener, reply: &[u8]) -> io::Result<Vec<Vec<u8>>> {
    let (mut stream, _) = listener.accept()?;
    let frames = vec![read_frame(&mut stream)?, read_frame(&mut stream)?];
    write_frame(&mut stream, reply)?;
    Ok(frames)
}

fn run_helper(socket: &Path, hint: Option<&str>, prompt: &str) -> io::Result<Output> {
    let mut command = Command::new(HELPER);
    command.arg(prompt).env("TABLEPRO_ASKPASS_SOCKET", socket);
    match hint {
        Some(hint) => command.env("SSH_ASKPASS_PROMPT", hint),
        None => command.env_remove("SSH_ASKPASS_PROMPT"),
    };
    command.output()
}

#[test]
fn answer_printed_with_newline_exit_0() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("askpass");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = thread::spawn(move || serve_once(&listener, b"\x00s3cret"));

    let output = run_helper(&socket, None, "deploy@bastion's password: ").unwrap();
    let frames = server.join().unwrap().unwrap();

    assert!(output.status.success());
    assert_eq!(output.stdout, b"s3cret\n");
    assert_eq!(frames, [b"".to_vec(), b"deploy@bastion's password: ".to_vec()]);
}

#[test]
fn cancel_exits_1() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("askpass");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = thread::spawn(move || serve_once(&listener, b"\x01"));

    let output = run_helper(
        &socket,
        Some("confirm"),
        "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
    )
    .unwrap();
    let frames = server.join().unwrap().unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert_eq!(frames[0], b"confirm");
}

#[test]
fn missing_socket_exits_1() {
    let temp = tempfile::tempdir().unwrap();
    let output = run_helper(&temp.path().join("absent"), None, "Password: ").unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
}
