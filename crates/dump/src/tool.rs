use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use tokio::process::Command;

use crate::DumpError;

const SEARCH_DIRS: [&str; 2] = ["/usr/bin", "/usr/local/bin"];
const VERSION_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientTool {
    pub(crate) name: String,
    pub(crate) path: PathBuf,
    pub(crate) major: u32,
}

impl ClientTool {
    pub async fn locate(name: &str, configured: Option<&Path>) -> Result<Self, DumpError> {
        let missing = || DumpError::ToolMissing { tool: name.to_owned() };
        let path = match configured {
            Some(path) => executable(path).then(|| path.to_path_buf()).ok_or_else(missing)?,
            None => SEARCH_DIRS
                .iter()
                .map(|dir| Path::new(dir).join(name))
                .find(|path| executable(path))
                .ok_or_else(missing)?,
        };
        let major = read_major(name, &path).await?;
        Ok(Self {
            name: name.to_owned(),
            path,
            major,
        })
    }

    pub fn major(&self) -> u32 {
        self.major
    }

    pub(crate) fn require_at_least(&self, server_major: u32) -> Result<(), DumpError> {
        if self.major >= server_major {
            return Ok(());
        }
        Err(DumpError::ToolTooOld {
            tool: self.name.clone(),
            tool_major: self.major,
            server_major,
        })
    }

    pub(crate) fn require_at_most(&self, server_major: u32) -> Result<(), DumpError> {
        if self.major <= server_major {
            return Ok(());
        }
        Err(DumpError::ToolTooNew {
            tool: self.name.clone(),
            tool_major: self.major,
            server_major,
        })
    }
}

fn executable(path: &Path) -> bool {
    path.is_absolute()
        && std::fs::metadata(path).is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

async fn read_major(name: &str, path: &Path) -> Result<u32, DumpError> {
    let unknown = || DumpError::ToolVersionUnknown { tool: name.to_owned() };
    let output = Command::new(path)
        .arg("--version")
        .env_clear()
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(VERSION_TIMEOUT, output)
        .await
        .map_err(|_| unknown())??;
    parse_major(&String::from_utf8_lossy(&output.stdout)).ok_or_else(unknown)
}

fn parse_major(version: &str) -> Option<u32> {
    let rest = version.split_once("(PostgreSQL)")?.1.trim_start();
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_major_version_is_read_from_the_version_line() {
        assert_eq!(parse_major("pg_dump (PostgreSQL) 18.6\n"), Some(18));
        assert_eq!(parse_major("pg_dump (PostgreSQL) 17beta1"), Some(17));
        assert_eq!(parse_major("pg_dump (PostgreSQL) 12.20 (Debian 12.20-1)"), Some(12));
        assert_eq!(parse_major("mysqldump  Ver 10.19"), None);
    }

    #[test]
    fn a_relative_or_missing_path_is_not_executable() {
        assert!(!executable(Path::new("pg_dump")));
        assert!(!executable(Path::new("/nonexistent/pg_dump")));
    }

    #[test]
    fn client_and_server_versions_must_be_compatible() {
        let tool = ClientTool {
            name: "pg_dump".into(),
            path: PathBuf::from("/usr/bin/pg_dump"),
            major: 16,
        };
        assert!(tool.require_at_least(16).is_ok());
        assert!(matches!(tool.require_at_least(17), Err(DumpError::ToolTooOld { .. })));
        assert!(tool.require_at_most(16).is_ok());
        assert!(matches!(tool.require_at_most(15), Err(DumpError::ToolTooNew { .. })));
    }
}
