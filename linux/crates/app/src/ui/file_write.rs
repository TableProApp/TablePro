use gtk4::glib;
use gtk4::prelude::*;

/// Replace `file` with `contents`. GIO writes a local file on its own
/// worker thread, so a slow disk or a network mount never stalls the
/// window that asked.
///
/// A new file is the user's alone, as a row export is: the connection
/// export names every host, user and key path. A replaced file keeps
/// the mode it had.
pub(crate) async fn replace_file(file: &gio::File, contents: Vec<u8>) -> Result<(), glib::Error> {
    file.replace_contents_future(contents, None, false, gio::FileCreateFlags::PRIVATE)
        .await
        .map(drop)
        .map_err(|(_, error)| error)
}

/// Write `contents` to a file of that name only when none exists, so a
/// file that appears meanwhile is an `Exists` error and is left alone.
/// New, so private, as `replace_file` makes one.
pub(crate) async fn create_file(file: &gio::File, contents: Vec<u8>) -> Result<(), glib::Error> {
    let stream = file
        .create_future(gio::FileCreateFlags::PRIVATE, glib::Priority::DEFAULT)
        .await?;
    match stream.write_all_future(contents, glib::Priority::DEFAULT).await {
        Ok((_, _, None)) => stream.close_future(glib::Priority::DEFAULT).await,
        Ok((_, _, Some(error))) | Err((_, error)) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn replace(file: gio::File, contents: &[u8]) -> Result<(), glib::Error> {
        let contents = contents.to_vec();
        crate::test_support::finish_on_main(
            Duration::from_secs(10),
            async move { replace_file(&file, contents).await },
        )
        .expect("the write to end")
    }

    #[gtk4::test]
    fn a_file_is_replaced_whole() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("export.csv");
        std::fs::write(&path, "an older, longer export\n").expect("seed");

        replace(gio::File::for_path(&path), b"a,b\n").expect("written");

        assert_eq!(std::fs::read(&path).expect("read back"), b"a,b\n");
    }

    #[gtk4::test]
    fn a_new_file_is_readable_by_its_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("tablepro-connections.json");

        replace(gio::File::for_path(&path), b"{}").expect("written");

        let mode = std::fs::metadata(&path).expect("the file").permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "{mode:o}");
    }

    #[gtk4::test]
    fn a_replaced_file_keeps_its_mode() {
        use std::os::unix::fs::PermissionsExt;

        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("tablepro-connections.json");
        std::fs::write(&path, "{}").expect("seed");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).expect("a mode");

        replace(gio::File::for_path(&path), b"{\"connections\":[]}").expect("written");

        let mode = std::fs::metadata(&path).expect("the file").permissions().mode();
        assert_eq!(mode & 0o777, 0o640, "{mode:o}");
    }

    fn create(file: gio::File, contents: &[u8]) -> Result<(), glib::Error> {
        let contents = contents.to_vec();
        crate::test_support::finish_on_main(
            Duration::from_secs(10),
            async move { create_file(&file, contents).await },
        )
        .expect("the write to end")
    }

    #[gtk4::test]
    fn a_new_file_is_created_with_its_contents_for_its_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("weekly.sql");

        create(gio::File::for_path(&path), b"SELECT 1;").expect("written");

        assert_eq!(std::fs::read(&path).expect("read back"), b"SELECT 1;");
        let mode = std::fs::metadata(&path).expect("the file").permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "{mode:o}");
    }

    #[gtk4::test]
    fn creating_leaves_a_file_already_there_alone() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("weekly.sql");
        std::fs::write(&path, "SELECT 7;").expect("seed");

        let error = create(gio::File::for_path(&path), b"SELECT 1;").expect_err("a file is there");

        assert!(error.matches(gio::IOErrorEnum::Exists), "{error}");
        assert_eq!(std::fs::read(&path).expect("read back"), b"SELECT 7;");
    }

    #[gtk4::test]
    fn a_folder_that_is_not_there_is_an_error() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = gio::File::for_path(root.path().join("missing").join("export.csv"));

        let error = replace(file, b"a,b\n").expect_err("no folder to write into");

        assert!(error.matches(gio::IOErrorEnum::NotFound), "{error}");
    }
}
