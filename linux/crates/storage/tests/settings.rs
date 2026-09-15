use std::error::Error;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use tablepro_core::export::{CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote};
use tablepro_storage::settings::keys;
use tablepro_storage::{AppSettings, EditorFont, SettingsError, WindowGeometry};

type TestResult = Result<(), Box<dyn Error>>;

const SCHEMA_ID: &str = "app.tablepro.TablePro";

struct Fixture {
    _dir: tempfile::TempDir,
    settings: AppSettings,
}

impl Fixture {
    fn new() -> Result<Self, Box<dyn Error>> {
        let dir = compile_schemas()?;
        let settings = AppSettings::with_backend(SCHEMA_ID, dir.path(), &gio::memory_settings_backend_new())?;
        Ok(Self { _dir: dir, settings })
    }
}

fn source_schema_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data")
}

fn compile_schemas() -> Result<tempfile::TempDir, Box<dyn Error>> {
    let dir = tempfile::tempdir()?;
    let schema = source_schema_dir().join("app.tablepro.TablePro.gschema.xml");
    std::fs::copy(&schema, dir.path().join("app.tablepro.TablePro.gschema.xml"))?;
    let output = Command::new("glib-compile-schemas").arg(dir.path()).output()?;
    if !output.status.success() {
        return Err(format!("glib-compile-schemas: {}", String::from_utf8_lossy(&output.stderr)).into());
    }
    Ok(dir)
}

#[test]
fn defaults_match_schema() -> TestResult {
    let fixture = Fixture::new()?;

    assert_eq!(fixture.settings.default_page_size(), 1_000);
    assert!(fixture.settings.confirm_destructive());
    assert_eq!(fixture.settings.history_retention_days(), 30);
    assert_eq!(fixture.settings.query_timeout(), Some(Duration::from_secs(60)));
    assert_eq!(fixture.settings.style_scheme(), "Adwaita");
    assert_eq!(fixture.settings.csv_options(), CsvOptions::default());
    Ok(())
}

#[test]
fn csv_options_round_trip() -> TestResult {
    let fixture = Fixture::new()?;
    let options = CsvOptions {
        null_to_empty: false,
        line_break_to_space: true,
        header_row: false,
        sanitize_formulas: false,
        delimiter: CsvDelimiter::Pipe,
        quote: CsvQuote::Always,
        line_break: CsvLineBreak::CrLf,
        decimal: CsvDecimal::Comma,
    };

    fixture.settings.set_csv_options(&options)?;

    assert_eq!(fixture.settings.csv_options(), options);
    Ok(())
}

#[test]
fn reset_csv_options_restores_defaults() -> TestResult {
    let fixture = Fixture::new()?;
    fixture.settings.set_csv_options(&CsvOptions {
        delimiter: CsvDelimiter::Tab,
        header_row: false,
        ..CsvOptions::default()
    })?;

    fixture.settings.reset_csv_options();

    assert_eq!(fixture.settings.csv_options(), CsvOptions::default());
    Ok(())
}

#[test]
fn window_geometry_round_trip() -> TestResult {
    let fixture = Fixture::new()?;
    let geometry = WindowGeometry {
        width: 1440,
        height: 900,
        maximized: true,
    };

    fixture.settings.set_window_geometry(geometry)?;

    assert_eq!(fixture.settings.window_geometry(), geometry);
    Ok(())
}

#[test]
fn range_rejects_out_of_bounds() -> TestResult {
    let fixture = Fixture::new()?;

    for (key, result) in [
        (keys::DEFAULT_PAGE_SIZE, fixture.settings.set_default_page_size(99)),
        (keys::DEFAULT_PAGE_SIZE, fixture.settings.set_default_page_size(100_001)),
        (
            keys::HISTORY_RETENTION_DAYS,
            fixture.settings.set_history_retention_days(366),
        ),
        (keys::QUERY_TIMEOUT_SECS, fixture.settings.set_query_timeout_secs(3_601)),
    ] {
        let Err(error) = result else {
            return Err(format!("{key} accepted an out-of-range value").into());
        };
        assert!(matches!(error, SettingsError::Write { .. }), "{key}: {error}");
    }

    assert_eq!(fixture.settings.default_page_size(), 1_000);
    Ok(())
}

#[test]
fn query_timeout_zero_is_none() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.set_query_timeout_secs(0)?;

    assert_eq!(fixture.settings.query_timeout(), None);
    Ok(())
}

#[test]
fn editor_font_defaults_to_system() -> TestResult {
    let fixture = Fixture::new()?;
    assert_eq!(fixture.settings.editor_font(), EditorFont::System);

    fixture
        .settings
        .set_editor_font(&EditorFont::Custom("Fira Code 13".to_owned()))?;

    assert_eq!(
        fixture.settings.editor_font(),
        EditorFont::Custom("Fira Code 13".to_owned())
    );
    Ok(())
}

#[test]
fn missing_schema_is_schema_not_found() -> TestResult {
    let dir = compile_schemas()?;

    let result = AppSettings::with_backend("app.tablepro.Absent", dir.path(), &gio::memory_settings_backend_new());

    let Err(error) = result else {
        return Err("an uninstalled schema id must not open".into());
    };
    assert!(matches!(error, SettingsError::SchemaNotFound(id) if id == "app.tablepro.Absent"));
    Ok(())
}

#[test]
fn nonexistent_dir_is_schema_directory() -> TestResult {
    let dir = tempfile::tempdir()?;
    let missing = dir.path().join("absent");

    let result = AppSettings::with_backend(SCHEMA_ID, &missing, &gio::memory_settings_backend_new());

    let Err(error) = result else {
        return Err("a directory with no compiled schemas must not open".into());
    };
    assert!(matches!(error, SettingsError::SchemaDirectory { path, .. } if path == missing));
    Ok(())
}
