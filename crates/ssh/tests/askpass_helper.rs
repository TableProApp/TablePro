#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

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

fn exchange(reply: Vec<u8>, hint: Option<&str>, prompt: &str) -> (Output, Vec<Vec<u8>>) {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("askpass");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = thread::spawn(move || serve_once(&listener, &reply));
    let output = run_helper(&socket, hint, prompt).unwrap();
    let frames = server.join().unwrap().unwrap_or_default();
    (output, frames)
}

#[test]
fn an_answer_is_printed_with_a_newline_and_exit_0() {
    let (output, frames) = exchange(b"\x00s3cret".to_vec(), None, "deploy@bastion's password: ");
    assert!(output.status.success());
    assert_eq!(output.stdout, b"s3cret\n");
    assert_eq!(frames, [b"".to_vec(), b"deploy@bastion's password: ".to_vec()]);
}

#[test]
fn a_cancel_exits_1_with_nothing_printed() {
    let (output, frames) = exchange(
        b"\x01".to_vec(),
        Some("confirm"),
        "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert_eq!(frames[0], b"confirm");
}

#[test]
fn an_oversized_reply_is_refused() {
    let mut reply = vec![0u8];
    reply.resize(65_537 + 1, b'a');
    let (output, _) = exchange(reply, None, "Password: ");
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
}

#[test]
fn a_missing_socket_exits_1() {
    let temp = tempfile::tempdir().unwrap();
    let output = run_helper(&temp.path().join("absent"), None, "Password: ").unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
}

#[test]
fn no_socket_variable_exits_1() {
    let output = Command::new(HELPER)
        .arg("Password: ")
        .env_remove("TABLEPRO_ASKPASS_SOCKET")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
}
