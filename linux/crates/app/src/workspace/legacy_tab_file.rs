use std::io;
use std::path::Path;

/// The one tab file builds before per-session workspaces kept in the
/// state directory. Editor tabs wrote their SQL into it, and nothing
/// reads it any more, so it would keep that SQL on disk for good.
const LEGACY_TAB_FILE: &str = "workspace_state.json";

/// Removes the tab file an older build left in `state_dir`, and nothing
/// else there. Nothing writes the file any more, so the first start
/// after the upgrade is the one that finds it.
pub(crate) fn remove_legacy_tab_file(state_dir: &Path) -> io::Result<bool> {
    match std::fs::remove_file(state_dir.join(LEGACY_TAB_FILE)) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_legacy_tab_file_goes_and_the_rest_of_the_state_directory_stays() {
        let state = tempfile::tempdir().expect("a state directory");
        let kept = ["history.db", "workspace_state.json.tmp", "workspaces/abc.json"];
        std::fs::create_dir(state.path().join("workspaces")).expect("the workspaces directory");
        for name in kept {
            std::fs::write(state.path().join(name), b"kept").expect("a kept file");
        }
        std::fs::write(
            state.path().join(LEGACY_TAB_FILE),
            br#"{"connections":{"c":{"tabs":[{"kind":"editor","query":"SELECT 1"}]}}}"#,
        )
        .expect("the legacy file");

        let first = remove_legacy_tab_file(state.path()).expect("the removal");
        let second = remove_legacy_tab_file(state.path()).expect("a second start");

        assert!(first);
        assert!(!second, "a start without the file found one");
        assert!(!state.path().join(LEGACY_TAB_FILE).exists());
        for name in kept {
            assert!(state.path().join(name).exists(), "{name} was removed");
        }
    }

    #[test]
    fn a_missing_state_directory_has_nothing_to_remove() {
        let root = tempfile::tempdir().expect("a root");

        assert!(!remove_legacy_tab_file(&root.path().join("never-created")).expect("no error"));
    }
}
