use std::env;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::process::ExitCode;

use zeroize::Zeroizing;

const MAX_FRAME: usize = 65_536;
const ANSWER: u8 = 0x00;
const SOCKET_ENV: &str = "TABLEPRO_ASKPASS_SOCKET";

fn main() -> ExitCode {
    let Some(answer) = request_answer() else {
        return ExitCode::FAILURE;
    };
    let mut stdout = std::io::stdout().lock();
    let written = stdout
        .write_all(answer.get(1..).unwrap_or_default())
        .and_then(|()| stdout.write_all(b"\n"))
        .and_then(|()| stdout.flush());
    match written {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::FAILURE,
    }
}

fn request_answer() -> Option<Zeroizing<Vec<u8>>> {
    let socket = env::var_os(SOCKET_ENV)?;
    let hint = env::var_os("SSH_ASKPASS_PROMPT").unwrap_or_default();
    let prompt = env::args_os().nth(1).unwrap_or_default();

    let mut stream = UnixStream::connect(socket).ok()?;
    write_frame(&mut stream, hint.as_bytes())?;
    write_frame(&mut stream, prompt.as_bytes())?;
    let reply = read_frame(&mut stream)?;
    (reply.first() == Some(&ANSWER)).then_some(reply)
}

fn write_frame(stream: &mut UnixStream, bytes: &[u8]) -> Option<()> {
    if bytes.len() > MAX_FRAME {
        return None;
    }
    let length = u32::try_from(bytes.len()).ok()?;
    stream.write_all(&length.to_be_bytes()).ok()?;
    stream.write_all(bytes).ok()
}

fn read_frame(stream: &mut UnixStream) -> Option<Zeroizing<Vec<u8>>> {
    let mut length = [0u8; 4];
    stream.read_exact(&mut length).ok()?;
    let length = usize::try_from(u32::from_be_bytes(length)).ok()?;
    if length > MAX_FRAME {
        return None;
    }
    let mut frame = Zeroizing::new(vec![0u8; length]);
    stream.read_exact(&mut frame).ok()?;
    Some(frame)
}
