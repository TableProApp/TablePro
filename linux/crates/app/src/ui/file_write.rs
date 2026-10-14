use gtk4::glib;
use gtk4::prelude::*;

/// Replace `file` with `contents`. GIO writes a local file on its own
/// worker thread, so a slow disk or a network mount never stalls the
/// window that asked.
pub(crate) async fn replace_file(file: &gio::File, contents: Vec<u8>) -> Result<(), glib::Error> {
    file.replace_contents_future(contents, None, false, gio::FileCreateFlags::NONE)
        .await
        .map(drop)
        .map_err(|(_, error)| error)
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
    fn a_folder_that_is_not_there_is_an_error() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = gio::File::for_path(root.path().join("missing").join("export.csv"));

        let error = replace(file, b"a,b\n").expect_err("no folder to write into");

        assert!(error.matches(gio::IOErrorEnum::NotFound), "{error}");
    }
}
