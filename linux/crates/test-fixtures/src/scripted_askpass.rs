use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use crate::FixtureError;

pub struct ScriptedAskpass {
    _dir: TempDir,
    path: PathBuf,
}

impl ScriptedAskpass {
    pub const ANSWER_VARIABLE: &'static str = "TABLEPRO_TEST_ASKPASS_ANSWER";

    pub fn new() -> Result<Self, FixtureError> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("askpass");
        let mut script = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o700)
            .open(&path)?;
        script.write_all(format!("#!/bin/sh\nprintf '%s\\n' \"${}\"\n", Self::ANSWER_VARIABLE).as_bytes())?;
        script.sync_all()?;
        Ok(Self { _dir: dir, path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;

    use super::*;

    #[test]
    fn scripted_askpass_is_0700_and_prints_the_answer() {
        let askpass = ScriptedAskpass::new().unwrap();

        let mode = std::fs::metadata(askpass.path()).unwrap().permissions().mode() & 0o777;
        let output = Command::new(askpass.path())
            .arg("tablepro@localhost's password: ")
            .env(ScriptedAskpass::ANSWER_VARIABLE, "s3cret value")
            .output()
            .unwrap();

        assert_eq!(mode, 0o700);
        assert!(output.status.success());
        assert_eq!(output.stdout, b"s3cret value\n");
    }
}
