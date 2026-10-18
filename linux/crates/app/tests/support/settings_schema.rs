use std::path::Path;
use std::process::Command;

const TEMPLATE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../data/app.tablepro.TablePro.gschema.xml.in"
));

/// Renders the schema for each ID the way data/meson.build does and
/// compiles them together into `dir`.
pub fn compile(dir: &Path, app_ids: &[&str]) -> Result<(), String> {
    for app_id in app_ids {
        let path = format!("/{}/", app_id.replace('.', "/"));
        let schema = TEMPLATE.replace("@app-id@", app_id).replace("@schema-path@", &path);
        let file = dir.join(format!("{app_id}.gschema.xml"));
        std::fs::write(&file, schema).map_err(|error| format!("could not write {}: {error}", file.display()))?;
    }
    let output = Command::new("glib-compile-schemas")
        .arg("--strict")
        .arg(dir)
        .output()
        .map_err(|error| format!("could not run glib-compile-schemas: {error}"))?;
    if output.status.success() {
        return Ok(());
    }
    Err(format!(
        "glib-compile-schemas failed: {}",
        String::from_utf8_lossy(&output.stderr)
    ))
}
