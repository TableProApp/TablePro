//! With `XDG_RUNTIME_DIR` unset, as under some display managers and in a
//! plain `ssh -X` login, GLib answers the cache directory, so the SSH
//! control sockets go under `$XDG_CACHE_HOME/app/<id>`, which nothing
//! else creates.
//!
//! GLib reads the variables once per process, which is why this is a test
//! binary of its own with one test, and why they are set before GLib is
//! asked anything.

use tablepro_storage::StoragePaths;

#[test]
fn an_unset_runtime_dir_falls_back_to_the_cache_dir() {
    let cache = tempfile::tempdir().expect("a directory");
    // SAFETY: the harness runs this binary's one test alone, and nothing
    // in it reads the environment yet.
    unsafe {
        std::env::remove_var("XDG_RUNTIME_DIR");
        std::env::set_var("XDG_CACHE_HOME", cache.path());
    }

    let paths = StoragePaths::from_glib("tablepro", "app.tablepro.TablePro");

    assert_eq!(paths.runtime, cache.path().join("app").join("app.tablepro.TablePro"));
}
