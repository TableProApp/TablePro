use std::io::Read as _;
use std::path::{Path, PathBuf};

// An offline file is one token, a few kilobytes.
const LIMIT: u64 = 64 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum OfflineFileError {
    #[error("cannot read {}: {source}", path.display())]
    Read { path: PathBuf, source: std::io::Error },
    #[error("{} is too large to be an offline file", path.display())]
    TooLarge { path: PathBuf },
}

// The token for Account::import_offline_file. Reads no further than the limit.
pub fn read_offline_file_blocking(path: &Path) -> Result<String, OfflineFileError> {
    let read = |source| OfflineFileError::Read {
        path: path.to_owned(),
        source,
    };
    let file = std::fs::File::open(path).map_err(read)?;
    let mut token = String::new();
    file.take(LIMIT + 1).read_to_string(&mut token).map_err(read)?;
    if token.len() as u64 > LIMIT {
        return Err(OfflineFileError::TooLarge { path: path.to_owned() });
    }
    Ok(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_token_and_refuses_what_cannot_be_one() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("offline.jwt");
        std::fs::write(&path, "header.claims.signature\n").expect("the file");
        let large = dir.path().join("large.jwt");
        std::fs::write(&large, vec![b'a'; 64 * 1024 + 1]).expect("the file");
        let binary = dir.path().join("binary.jwt");
        std::fs::write(&binary, [0xff, 0xfe]).expect("the file");

        let token = read_offline_file_blocking(&path).expect("a token");
        let missing = read_offline_file_blocking(&dir.path().join("absent.jwt"));
        let too_large = read_offline_file_blocking(&large);
        let not_text = read_offline_file_blocking(&binary);

        assert_eq!(token, "header.claims.signature\n");
        assert!(matches!(missing, Err(OfflineFileError::Read { .. })));
        assert!(matches!(too_large, Err(OfflineFileError::TooLarge { path: named }) if named == large));
        assert!(matches!(not_text, Err(OfflineFileError::Read { .. })));
    }
}
