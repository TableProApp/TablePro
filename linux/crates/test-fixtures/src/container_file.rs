use testcontainers::{ContainerRequest, CopyTargetOptions, Image, ImageExt};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerFile {
    target: String,
    contents: Vec<u8>,
    mode: u32,
}

impl ContainerFile {
    pub const READABLE: u32 = 0o644;
    pub const EXECUTABLE: u32 = 0o755;
    pub const PRIVATE: u32 = 0o600;

    pub fn readable(target: impl Into<String>, contents: impl Into<Vec<u8>>) -> Self {
        Self::with_mode(target, contents, Self::READABLE)
    }

    pub fn executable(target: impl Into<String>, contents: impl Into<Vec<u8>>) -> Self {
        Self::with_mode(target, contents, Self::EXECUTABLE)
    }

    pub fn private(target: impl Into<String>, contents: impl Into<Vec<u8>>) -> Self {
        Self::with_mode(target, contents, Self::PRIVATE)
    }

    fn with_mode(target: impl Into<String>, contents: impl Into<Vec<u8>>, mode: u32) -> Self {
        Self {
            target: target.into(),
            contents: contents.into(),
            mode,
        }
    }

    pub fn target(&self) -> &str {
        &self.target
    }

    pub fn contents(&self) -> &[u8] {
        &self.contents
    }

    pub fn mode(&self) -> u32 {
        self.mode
    }
}

pub(crate) fn with_files<I: Image>(request: ContainerRequest<I>, files: Vec<ContainerFile>) -> ContainerRequest<I> {
    files.into_iter().fold(request, |request, file| {
        request.with_copy_to(CopyTargetOptions::new(file.target).with_mode(file.mode), file.contents)
    })
}

#[cfg(test)]
mod tests {
    use crate::{ClickHouseFixture, MssqlFixture, MysqlFixture, TestPki};

    use super::*;

    #[test]
    fn other_engines_copy_at_0644() {
        let pki = TestPki::generate().unwrap();
        let files = [
            MysqlFixture::files(&pki, "secret").unwrap(),
            MssqlFixture::files(&pki).unwrap(),
            ClickHouseFixture::files(&pki, "secret").unwrap(),
        ]
        .concat();

        assert!(!files.is_empty());
        for file in &files {
            assert_eq!(file.mode(), ContainerFile::READABLE, "{}", file.target());
        }
    }
}
