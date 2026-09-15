use std::path::Path;
use std::process::Command;
use std::rc::Rc;

use tablepro_storage::AppSettings;

/// The schema compiled into a `TempDir` behind a memory backend, so a
/// test never reads or writes the developer's own dconf database.
pub(crate) struct MemorySettings {
    _dir: tempfile::TempDir,
    settings: Rc<AppSettings>,
}

impl MemorySettings {
    pub(crate) fn new() -> Self {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../data")
            .join("app.tablepro.TablePro.gschema.xml");
        std::fs::copy(&source, dir.path().join("app.tablepro.TablePro.gschema.xml")).expect("copy the schema");
        let output = Command::new("glib-compile-schemas")
            .arg(dir.path())
            .output()
            .expect("run glib-compile-schemas");
        assert!(
            output.status.success(),
            "glib-compile-schemas: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let settings = AppSettings::with_backend(
            crate::config::SCHEMA_ID,
            dir.path(),
            &gio::memory_settings_backend_new(),
        )
        .expect("open the compiled schema");
        Self {
            _dir: dir,
            settings: Rc::new(settings),
        }
    }

    pub(crate) fn get(&self) -> &Rc<AppSettings> {
        &self.settings
    }
}
