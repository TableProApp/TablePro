use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

#[path = "src/application/metainfo_release.rs"]
mod metainfo_release;

const METAINFO_TEMPLATE: &str = "../../data/app.tablepro.TablePro.metainfo.xml.in.in";
/// The fallback `config::APP_ID` takes when Meson sets nothing.
const DEFAULT_APP_ID: &str = "app.tablepro.TablePro.Devel";

fn main() -> ExitCode {
    let metainfo_dir = match render_metainfo() {
        Ok(dir) => dir,
        Err(message) => {
            println!("cargo::error={message}");
            return ExitCode::FAILURE;
        }
    };
    glib_build_tools::compile_resources(
        &[PathBuf::from("../../data/resources"), metainfo_dir],
        "../../data/resources/resources.gresource.xml",
        "tablepro.gresource",
    );
    ExitCode::SUCCESS
}

/// The About dialog reads the metainfo from the GResource. A Meson build
/// passes the copy it installs, translations merged; a plain cargo build
/// renders the template with the same values, untranslated.
fn render_metainfo() -> Result<PathBuf, String> {
    println!("cargo::rerun-if-env-changed=TABLEPRO_METAINFO");
    let out_dir = env::var_os("OUT_DIR").ok_or("OUT_DIR is not set")?;
    let rendered = match env::var_os("TABLEPRO_METAINFO") {
        Some(merged) => {
            let merged = PathBuf::from(merged);
            println!("cargo::rerun-if-changed={}", merged.display());
            fs::read_to_string(&merged).map_err(|error| format!("could not read {}: {error}", merged.display()))?
        }
        None => render_template()?,
    };

    let dir = PathBuf::from(out_dir).join("metainfo");
    fs::create_dir_all(&dir).map_err(|error| format!("could not create {}: {error}", dir.display()))?;
    let path = dir.join("metainfo.xml");
    // A rewrite, even of the same bytes, makes cargo run this script and
    // rebuild the crate on every later build.
    if fs::read_to_string(&path).ok().as_deref() != Some(rendered.as_str()) {
        fs::write(&path, rendered).map_err(|error| format!("could not write {}: {error}", path.display()))?;
    }
    Ok(dir)
}

fn render_template() -> Result<String, String> {
    println!("cargo::rerun-if-changed={METAINFO_TEMPLATE}");
    println!("cargo::rerun-if-env-changed=TABLEPRO_APP_ID");
    let app_id = env::var("TABLEPRO_APP_ID").unwrap_or_else(|_| DEFAULT_APP_ID.to_owned());
    let package = env::var("CARGO_PKG_NAME").map_err(|error| format!("CARGO_PKG_NAME: {error}"))?;
    let template = fs::read_to_string(METAINFO_TEMPLATE)
        .map_err(|error| format!("could not read {METAINFO_TEMPLATE}: {error}"))?;
    let version = metainfo_release::newest_release(&template)
        .ok_or_else(|| format!("{METAINFO_TEMPLATE} lists no release with a version"))?;
    let rendered = template
        .replace("@app-id@", &app_id)
        .replace("@gettext-package@", &package)
        .replace("@version@", version);
    if let Some(name) = unfilled_placeholder(&rendered) {
        return Err(format!(
            "{METAINFO_TEMPLATE} uses @{name}@, which build.rs does not fill"
        ));
    }
    Ok(rendered)
}

/// The name of a Meson `@name@` placeholder still in `text`.
fn unfilled_placeholder(text: &str) -> Option<&str> {
    let mut rest = text;
    while let Some(start) = rest.find('@') {
        let after = &rest[start + 1..];
        let length = after
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
            .unwrap_or(after.len());
        if length > 0 && after[length..].starts_with('@') {
            return Some(&after[..length]);
        }
        rest = after;
    }
    None
}
