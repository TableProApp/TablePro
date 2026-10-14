use std::future::Future;
use std::path::Path;
use std::time::{Duration, SystemTime};

use super::*;
use crate::test_support::{finish_on_main, wait_until};

const WAIT: Duration = Duration::from_secs(10);

fn run<T: 'static>(future: impl Future<Output = T> + 'static) -> T {
    finish_on_main(WAIT, future).expect("the file operation to end")
}

fn open(path: &Path) -> ReplaceFileWriter {
    let file = gio::File::for_path(path);
    run(async move { ReplaceFileWriter::open(&file).await }).expect("the writer")
}

fn write(writer: ReplaceFileWriter, chunks: &[&str]) -> ReplaceFileWriter {
    let chunks: Vec<Vec<u8>> = chunks.iter().map(|chunk| chunk.as_bytes().to_vec()).collect();
    run(async move {
        for chunk in chunks {
            writer.write(chunk).await.expect("a written chunk");
        }
        writer
    })
}

fn entries(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .expect("the directory")
        .map(|entry| entry.expect("an entry").file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// A file last changed long ago, so a write now changes its tag.
fn seed(path: &Path, content: &str) {
    std::fs::write(path, content).expect("seed");
    std::fs::File::options()
        .write(true)
        .open(path)
        .and_then(|file| file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000)))
        .expect("an old modification time");
}

#[gtk4::test]
fn writer_creates_new_file_and_finish_keeps_it() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");

    let writer = write(open(&path), &["a,b\n", "1,2\n"]);
    run(async move { writer.finish().await }).expect("closed");

    assert_eq!(std::fs::read_to_string(&path).expect("read back"), "a,b\n1,2\n");
    assert_eq!(entries(dir.path()), ["export.csv"]);
}

#[gtk4::test]
fn abort_after_create_removes_new_file() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");

    let writer = write(open(&path), &["a,b\n"]);
    let outcome = run(async move { writer.abort().await });

    assert_eq!(outcome, AbortOutcome::Removed);
    assert!(entries(dir.path()).is_empty(), "{:?}", entries(dir.path()));
}

#[gtk4::test]
fn abort_on_regular_file_leaves_content_and_reports_untouched() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");
    seed(&path, "old");

    let writer = write(open(&path), &["new and partial"]);
    let outcome = run(async move { writer.abort().await });

    assert_eq!(outcome, AbortOutcome::Untouched);
    assert_eq!(std::fs::read_to_string(&path).expect("read back"), "old");
    assert_eq!(
        entries(dir.path()),
        ["export.csv"],
        "the temporary file was left behind"
    );
}

/// GLib renames its temporary file over the destination as the stream
/// closes. With that file gone the rename fails after every chunk was
/// written, the way a close on a full or network disk does.
#[gtk4::test]
fn failed_finish_on_regular_file_reports_untouched() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");
    seed(&path, "old");

    let writer = write(open(&path), &["new"]);
    let temporary = entries(dir.path())
        .into_iter()
        .find(|name| name != "export.csv")
        .expect("the temporary file");
    std::fs::remove_file(dir.path().join(temporary)).expect("the temporary file removed");
    let failed = run(async move { writer.finish().await }).expect_err("the rename to fail");

    assert_eq!(failed.file, AbortOutcome::Untouched);
    assert_eq!(std::fs::read_to_string(&path).expect("read back"), "old");
    assert_eq!(entries(dir.path()), ["export.csv"]);
}

#[gtk4::test]
fn file_made_by_export_whose_close_failed_is_removed() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");
    std::fs::write(&path, "partial").expect("a partial file");
    let file = gio::File::for_path(&path);

    let outcome = run(async move {
        let made = FileIdentity::at_path(&file).await;
        assert!(made.is_some(), "a local file has an inode");
        left_behind(&file, &Strategy::Created { made }).await
    });

    assert_eq!(outcome, AbortOutcome::Removed);
    assert!(entries(dir.path()).is_empty(), "{:?}", entries(dir.path()));
}

#[gtk4::test]
fn file_whose_identity_is_unknown_is_kept() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");
    std::fs::write(&path, "partial").expect("a partial file");
    let file = gio::File::for_path(&path);

    let outcome = run(async move { left_behind(&file, &Strategy::Created { made: None }).await });

    assert_eq!(outcome, AbortOutcome::Incomplete);
    assert_eq!(entries(dir.path()), ["export.csv"]);
}

#[gtk4::test]
fn finish_through_symlink_keeps_link_and_writes_target() {
    let dir = tempfile::tempdir().expect("tempdir");
    let target = dir.path().join("target.csv");
    let link = dir.path().join("link.csv");
    seed(&target, "old");
    std::os::unix::fs::symlink(&target, &link).expect("a link");

    let writer = write(open(&link), &["new"]);
    run(async move { writer.finish().await }).expect("closed");

    assert!(
        std::fs::symlink_metadata(&link)
            .expect("the link")
            .file_type()
            .is_symlink(),
        "the link was replaced by a file"
    );
    assert_eq!(std::fs::read_to_string(&target).expect("read back"), "new");
}

#[gtk4::test]
fn abort_through_symlink_reports_incomplete() {
    let dir = tempfile::tempdir().expect("tempdir");
    let target = dir.path().join("target.csv");
    let link = dir.path().join("link.csv");
    seed(&target, "old");
    std::os::unix::fs::symlink(&target, &link).expect("a link");

    let writer = write(open(&link), &["partial"]);
    let outcome = run(async move { writer.abort().await });

    assert_eq!(outcome, AbortOutcome::Incomplete);
}

#[gtk4::test]
fn dropping_unfinished_writer_leaves_existing_file_untouched() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");
    seed(&path, "old");

    let writer = write(open(&path), &["new and partial"]);
    assert_eq!(entries(dir.path()).len(), 2, "no temporary file to write into");
    drop(writer);

    wait_until(WAIT, || entries(dir.path()).len() == 1).expect("the temporary file to go");
    crate::test_support::drain_main_context();
    assert_eq!(std::fs::read_to_string(&path).expect("read back"), "old");
}

/// A directory's permissions do not stop root, which the CI container
/// runs as, so a folder that is not there stands in for one the user
/// cannot write to.
#[gtk4::test]
fn writer_error_on_missing_directory_reports_glib_error() {
    let dir = tempfile::tempdir().expect("tempdir");
    let file = gio::File::for_path(dir.path().join("missing").join("export.csv"));

    let error = run(async move { ReplaceFileWriter::open(&file).await.map(drop) }).expect_err("nowhere to write");

    assert!(
        matches!(&error, OpenError::File(error) if error.matches(gio::IOErrorEnum::NotFound)),
        "{error}"
    );
}

/// GLib's replace renames its temporary file over the path, as another
/// program's save does. The export's own file is gone then, and the
/// one at the path is not its to remove.
#[gtk4::test]
fn abort_after_create_keeps_a_file_put_at_the_path_since() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");
    let writer = write(open(&path), &["partial"]);
    let theirs = dir.path().join("theirs.tmp");
    std::fs::write(&theirs, "finished elsewhere").expect("their file");
    std::fs::rename(&theirs, &path).expect("their file renamed over the export");

    let outcome = run(async move { writer.abort().await });

    assert_eq!(outcome, AbortOutcome::Removed);
    assert_eq!(
        std::fs::read_to_string(&path).expect("their file"),
        "finished elsewhere"
    );
}

#[gtk4::test]
fn a_second_writer_to_a_file_being_written_is_refused() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");
    let first = write(open(&path), &["first"]);
    let try_open = || {
        let file = gio::File::for_path(&path);
        run(async move { ReplaceFileWriter::open(&file).await.map(drop) })
    };

    let refused = try_open();
    let refused_again = try_open();
    run(async move { first.finish().await }).expect("closed");

    assert!(matches!(refused, Err(OpenError::InUse)), "{refused:?}");
    assert!(
        matches!(refused_again, Err(OpenError::InUse)),
        "a refused open let go of the first writer's claim: {refused_again:?}"
    );
    assert_eq!(std::fs::read_to_string(&path).expect("read back"), "first");
    let again = write(open(&path), &["again"]);
    run(async move { again.finish().await }).expect("the file is free once the first closed");
    assert_eq!(std::fs::read_to_string(&path).expect("read back"), "again");
}

#[gtk4::test]
fn a_dropped_writer_frees_its_file_once_cleaned_up() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("export.csv");

    drop(write(open(&path), &["partial"]));
    wait_until(WAIT, || entries(dir.path()).is_empty()).expect("the abandoned file to go");
    crate::test_support::drain_main_context();

    let writer = write(open(&path), &["next"]);
    run(async move { writer.finish().await }).expect("closed");
    assert_eq!(std::fs::read_to_string(&path).expect("read back"), "next");
}
