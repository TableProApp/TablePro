//! A SQL file the user chose to import, opened for the core's reader.

use std::fs::File;
use std::path::Path;

pub fn open_import_file_blocking(path: &Path) -> std::io::Result<File> {
    File::open(path)
}
