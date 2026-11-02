use std::io;
use std::path::Path;

/// Make a rename or a new file in `directory` last a power cut, which it
/// does only once the directory that records it is on disk.
#[cfg(unix)]
pub fn sync_directory(directory: &Path) -> io::Result<()> {
    std::fs::File::open(directory)?.sync_all()
}

/// Windows opens no directory as a file, and NTFS journals the rename.
#[cfg(windows)]
pub fn sync_directory(_directory: &Path) -> io::Result<()> {
    Ok(())
}
