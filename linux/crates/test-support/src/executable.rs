use std::io::{self, Write};
use std::path::Path;
use std::process::Command;

/// Write `contents` to `path` as a program with permission bits `mode`.
///
/// Linux refuses to run a file any process holds open for writing
/// (ETXTBSY), and a child that another test thread forks while this
/// process has the file open keeps that handle until the child execs.
/// So `install` writes the program from a staged copy: this process
/// never holds `path` open for writing, and no fork can carry it off.
pub fn write_executable(path: &Path, contents: &[u8], mode: u32) -> io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut staged = tempfile::NamedTempFile::new_in(dir)?;
    staged.write_all(contents)?;
    staged.flush()?;
    let status = Command::new("install")
        .arg("-m")
        .arg(format!("{mode:o}"))
        .arg(staged.path())
        .arg(path)
        .status()?;
    if !status.success() {
        return Err(io::Error::other(format!("install exited with {status}")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn the_program_runs_at_once_with_its_mode() {
        let dir = tempfile::tempdir().unwrap();
        let program = dir.path().join("hello");

        write_executable(&program, b"#!/bin/sh\necho hello\n", 0o700).unwrap();

        let mode = std::fs::metadata(&program).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);
        let output = Command::new(&program).output().unwrap();
        assert_eq!(output.stdout, b"hello\n");
        assert_eq!(
            std::fs::read_dir(dir.path()).unwrap().count(),
            1,
            "the staged copy was left behind"
        );
    }
}
