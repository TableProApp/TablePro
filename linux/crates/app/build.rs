use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

#[path = "src/application/metainfo_release.rs"]
mod metainfo_release;

const METAINFO_TEMPLATE: &str = "../../data/app.tablepro.TablePro.metainfo.xml.in.in";
const SOURCE_COMMIT: &str = "../../build-aux/source-commit";
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
    let (rendered, source) = match env::var_os("TABLEPRO_METAINFO") {
        Some(merged) => {
            let merged = PathBuf::from(merged);
            println!("cargo::rerun-if-changed={}", merged.display());
            let text =
                fs::read_to_string(&merged).map_err(|error| format!("could not read {}: {error}", merged.display()))?;
            (text, merged)
        }
        None => (render_template()?, PathBuf::from(METAINFO_TEMPLATE)),
    };

    let dir = PathBuf::from(out_dir).join("metainfo");
    fs::create_dir_all(&dir).map_err(|error| format!("could not create {}: {error}", dir.display()))?;
    let path = dir.join("metainfo.xml");
    // compile_resources makes this file a rerun-if-changed input, which
    // cargo compares with the time this script last started. A rewrite, even
    // of the same bytes, or a first write stamped now runs the script again
    // on the next build, and the new GResource rebuilds the crate; the
    // source's time is older than this run.
    if fs::read_to_string(&path).ok().as_deref() != Some(rendered.as_str()) {
        fs::write(&path, rendered).map_err(|error| format!("could not write {}: {error}", path.display()))?;
        let modified = fs::metadata(&source)
            .and_then(|metadata| metadata.modified())
            .map_err(|error| format!("could not read the time of {}: {error}", source.display()))?;
        fs::File::options()
            .write(true)
            .open(&path)
            .and_then(|file| file.set_modified(modified))
            .map_err(|error| format!("could not set the time of {}: {error}", path.display()))?;
    }
    Ok(dir)
}

fn render_template() -> Result<String, String> {
    println!("cargo::rerun-if-changed={METAINFO_TEMPLATE}");
    println!("cargo::rerun-if-changed={SOURCE_COMMIT}");
    println!("cargo::rerun-if-env-changed=TABLEPRO_APP_ID");
    let app_id = env::var("TABLEPRO_APP_ID").unwrap_or_else(|_| DEFAULT_APP_ID.to_owned());
    let package = env::var("CARGO_PKG_NAME").map_err(|error| format!("CARGO_PKG_NAME: {error}"))?;
    let template = fs::read_to_string(METAINFO_TEMPLATE)
        .map_err(|error| format!("could not read {METAINFO_TEMPLATE}: {error}"))?;
    let source_commit =
        fs::read_to_string(SOURCE_COMMIT).map_err(|error| format!("could not read {SOURCE_COMMIT}: {error}"))?;
    let version = metainfo_release::newest_release(&template)
        .ok_or_else(|| format!("{METAINFO_TEMPLATE} lists no release with a version"))?;
    let rendered = template
        .replace("@app-id@", &app_id)
        .replace("@gettext-package@", &package)
        .replace("@version@", &metainfo_release::tag_version(version))
        .replace(
            "@screenshots-ref@",
            &metainfo_release::screenshots_ref(&source_commit, version),
        );
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
