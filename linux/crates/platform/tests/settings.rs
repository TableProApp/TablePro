use std::error::Error;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use tablepro_core::AiProvider;
use tablepro_core::export::{CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote};
use tablepro_linux_platform::settings::keys;
use tablepro_linux_platform::{AppSettings, EditorFont, SettingsError, WindowGeometry};

type TestResult = Result<(), Box<dyn Error>>;

const SCHEMA_ID: &str = "app.tablepro.TablePro";

// GSettings captures the thread-default context, so every test owns one through glib::async_test.
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

fn compile_schemas() -> Result<tempfile::TempDir, Box<dyn Error>> {
    let dir = tempfile::tempdir()?;
    let template = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data/app.tablepro.TablePro.gschema.xml.in");
    let schema = std::fs::read_to_string(template)?
        .replace("@app-id@", SCHEMA_ID)
        .replace("@schema-path@", "/app/tablepro/TablePro/");
    std::fs::write(dir.path().join(format!("{SCHEMA_ID}.gschema.xml")), schema)?;
    let output = Command::new("glib-compile-schemas").arg(dir.path()).output()?;
    if !output.status.success() {
        return Err(format!("glib-compile-schemas: {}", String::from_utf8_lossy(&output.stderr)).into());
    }
    Ok(dir)
}

#[glib::async_test]
async fn defaults_match_schema() -> TestResult {
    let fixture = Fixture::new()?;

    assert_eq!(fixture.settings.default_page_size(), 1_000);
    assert!(fixture.settings.confirm_bulk_delete());
    assert!(fixture.settings.show_alternate_rows());
    assert_eq!(fixture.settings.history_retention_days(), 30);
    assert_eq!(fixture.settings.query_timeout(), Some(Duration::from_secs(60)));
    assert_eq!(fixture.settings.style_scheme(), "Adwaita");
    assert_eq!(fixture.settings.csv_options(), CsvOptions::default());
    assert!(fixture.settings.restore_session());
    assert!(fixture.settings.save_query_history());
    assert!(!fixture.settings.vim_keybindings());
    assert!(!fixture.settings.mcp_server_enabled());
    assert_eq!(fixture.settings.mcp_server_port(), 23508);
    assert_eq!(fixture.settings.usage_days(), 0);
    assert!(fixture.settings.share_usage_data());
    assert_eq!(fixture.settings.license_ask_day(), "");
    Ok(())
}

#[glib::async_test]
async fn usage_data_turns_off_and_on_again() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.set_share_usage_data(false)?;
    let off = fixture.settings.share_usage_data();
    fixture.settings.set_share_usage_data(true)?;

    assert!(!off);
    assert!(fixture.settings.share_usage_data());
    Ok(())
}

#[glib::async_test]
async fn a_day_of_use_counts_once() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.record_usage_day("2026-11-05")?;
    fixture.settings.record_usage_day("2026-11-05")?;
    fixture.settings.record_usage_day("2026-11-06")?;
    fixture.settings.set_license_asked("2026-11-06")?;

    assert_eq!(fixture.settings.usage_days(), 2);
    assert_eq!(fixture.settings.last_usage_day(), "2026-11-06");
    assert_eq!(fixture.settings.license_ask_day(), "2026-11-06");
    Ok(())
}

#[glib::async_test]
async fn vim_keybindings_round_trip() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.set_vim_keybindings(true)?;
    assert!(fixture.settings.vim_keybindings());
    fixture.settings.set_vim_keybindings(false)?;
    assert!(!fixture.settings.vim_keybindings());
    Ok(())
}

#[glib::async_test]
async fn mcp_server_round_trip_and_port_range() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.set_mcp_server_enabled(true)?;
    fixture.settings.set_mcp_server_port(40_000)?;

    assert!(fixture.settings.mcp_server_enabled());
    assert_eq!(fixture.settings.mcp_server_port(), 40_000);
    // A port below 1024 belongs to a system service, never to the app.
    assert!(fixture.settings.set_mcp_server_port(80).is_err());
    assert_eq!(fixture.settings.mcp_server_port(), 40_000);
    Ok(())
}

#[glib::async_test]
async fn the_assistant_starts_off_and_keeps_each_providers_model() -> TestResult {
    let fixture = Fixture::new()?;
    assert_eq!(fixture.settings.ai_provider(), None);
    assert!(!fixture.settings.ai_inline_suggestions());
    assert_eq!(fixture.settings.ai_model(AiProvider::Anthropic), "claude-opus-5-5");
    assert_eq!(fixture.settings.ai_model(AiProvider::OpenAi), "");
    assert_eq!(
        fixture.settings.ai_base_url(AiProvider::OpenAiCompatible),
        "http://localhost:11434/v1"
    );

    fixture.settings.set_ai_provider(Some(AiProvider::OpenAiCompatible))?;
    fixture
        .settings
        .set_ai_model(AiProvider::OpenAiCompatible, " llama3.2 ")?;
    fixture.settings.set_ai_compatible_url("http://gpu-box:11434/v1")?;
    fixture.settings.set_ai_inline_suggestions(true)?;

    assert_eq!(fixture.settings.ai_provider(), Some(AiProvider::OpenAiCompatible));
    assert_eq!(fixture.settings.ai_model(AiProvider::OpenAiCompatible), "llama3.2");
    assert_eq!(fixture.settings.ai_model(AiProvider::Anthropic), "claude-opus-5-5");
    assert_eq!(
        fixture.settings.ai_base_url(AiProvider::OpenAiCompatible),
        "http://gpu-box:11434/v1"
    );
    assert_eq!(
        fixture.settings.ai_base_url(AiProvider::OpenAi),
        "https://api.openai.com/v1"
    );
    assert!(fixture.settings.ai_inline_suggestions());

    fixture.settings.set_ai_provider(None)?;
    assert_eq!(fixture.settings.ai_provider(), None);
    Ok(())
}

#[glib::async_test]
async fn restore_session_round_trip() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.set_restore_session(false)?;

    assert!(!fixture.settings.restore_session());
    Ok(())
}

#[glib::async_test]
async fn last_seen_version_starts_empty_and_round_trips() -> TestResult {
    let fixture = Fixture::new()?;
    assert_eq!(fixture.settings.last_seen_version(), "");

    fixture.settings.set_last_seen_version("0.2.0")?;

    assert_eq!(fixture.settings.last_seen_version(), "0.2.0");
    Ok(())
}

#[glib::async_test]
async fn confirm_bulk_delete_round_trip() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.set_confirm_bulk_delete(false)?;
    assert!(!fixture.settings.confirm_bulk_delete());
    fixture.settings.set_confirm_bulk_delete(true)?;
    assert!(fixture.settings.confirm_bulk_delete());
    Ok(())
}

#[glib::async_test]
async fn show_alternate_rows_round_trip() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.set_show_alternate_rows(false)?;
    assert!(!fixture.settings.show_alternate_rows());
    fixture.settings.set_show_alternate_rows(true)?;
    assert!(fixture.settings.show_alternate_rows());
    Ok(())
}

#[glib::async_test]
async fn save_query_history_round_trip() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.set_save_query_history(false)?;

    assert!(!fixture.settings.save_query_history());
    Ok(())
}

#[glib::async_test]
async fn csv_options_round_trip() -> TestResult {
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

#[glib::async_test]
async fn reset_csv_options_restores_defaults() -> TestResult {
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

#[glib::async_test]
async fn window_geometry_round_trip() -> TestResult {
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

#[glib::async_test]
async fn range_rejects_out_of_bounds() -> TestResult {
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

#[glib::async_test]
async fn query_timeout_zero_is_none() -> TestResult {
    let fixture = Fixture::new()?;

    fixture.settings.set_query_timeout_secs(0)?;

    assert_eq!(fixture.settings.query_timeout(), None);
    Ok(())
}

#[glib::async_test]
async fn editor_font_defaults_to_system() -> TestResult {
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

#[glib::async_test]
async fn missing_schema_is_schema_not_found() -> TestResult {
    let dir = compile_schemas()?;

    let result = AppSettings::with_backend("app.tablepro.Absent", dir.path(), &gio::memory_settings_backend_new());

    let Err(error) = result else {
        return Err("an uninstalled schema id must not open".into());
    };
    assert!(matches!(error, SettingsError::SchemaNotFound(id) if id == "app.tablepro.Absent"));
    Ok(())
}

#[glib::async_test]
async fn nonexistent_dir_is_schema_directory() -> TestResult {
    let dir = tempfile::tempdir()?;
    let missing = dir.path().join("absent");

    let result = AppSettings::with_backend(SCHEMA_ID, &missing, &gio::memory_settings_backend_new());

    let Err(error) = result else {
        return Err("a directory with no compiled schemas must not open".into());
    };
    assert!(matches!(error, SettingsError::SchemaDirectory { path, .. } if path == missing));
    Ok(())
}

#[glib::async_test]
async fn grid_preferences_start_from_schema_and_keep_one_model() -> TestResult {
    use tablepro_linux_platform::settings::{GridPreferenceValues, GridPreferences};

    let fixture = Fixture::new()?;
    let preferences = fixture.settings.grid_preferences();
    assert_eq!(preferences.snapshot().as_ref(), &GridPreferenceValues::default());
    assert_eq!(preferences, fixture.settings.grid_preferences());
    assert_eq!(GridPreferences::default().snapshot(), preferences.snapshot());
    Ok(())
}

#[glib::async_test]
async fn every_grid_preference_observer_reads_the_updated_snapshot() -> TestResult {
    use std::cell::RefCell;
    use std::rc::Rc;

    use tablepro_linux_platform::settings::GridRowHeight;

    let fixture = Fixture::new()?;
    let preferences = fixture.settings.grid_preferences();
    let original = preferences.snapshot();
    let first = Rc::new(RefCell::new(Vec::new()));
    let second = Rc::new(RefCell::new(Vec::new()));
    for observed in [&first, &second] {
        let observed = observed.clone();
        preferences.connect_changed(move |preferences| observed.borrow_mut().push(preferences.snapshot()));
    }

    fixture.settings.set_show_row_numbers(false)?;
    fixture.settings.set_show_alternate_rows(false)?;
    fixture.settings.set_grid_row_height("spacious")?;
    fixture.settings.set_null_display("Missing")?;

    assert_eq!(first.borrow().len(), 4);
    assert_eq!(*first.borrow(), *second.borrow());
    let current = preferences.snapshot();
    assert!(!current.show_row_numbers);
    assert!(!current.show_alternate_rows);
    assert_eq!(current.row_height, GridRowHeight::Spacious);
    assert_eq!(current.null_display, "Missing");
    assert!(original.show_row_numbers);
    assert_eq!(original.null_display, "NULL");
    Ok(())
}

#[glib::async_test]
async fn grid_preference_backends_stay_independent() -> TestResult {
    let first = Fixture::new()?;
    let second = Fixture::new()?;
    let first_preferences = first.settings.grid_preferences();
    let second_preferences = second.settings.grid_preferences();

    first.settings.set_null_display("Missing")?;
    second.settings.set_grid_row_height("compact")?;

    assert_eq!(first_preferences.snapshot().null_display, "Missing");
    assert_eq!(second_preferences.snapshot().null_display, "NULL");
    assert_eq!(first_preferences.snapshot().row_height.nick(), "normal");
    assert_eq!(second_preferences.snapshot().row_height.nick(), "compact");
    Ok(())
}

#[glib::async_test]
async fn null_display_is_bounded_even_for_external_settings_writes() -> TestResult {
    use gio::prelude::SettingsExt;

    let fixture = Fixture::new()?;
    let preferences = fixture.settings.grid_preferences();
    fixture.settings.gio().set_string(keys::NULL_DISPLAY, "\n\t\r")?;
    assert_eq!(preferences.snapshot().null_display, "NULL");
    fixture.settings.gio().set_string(keys::NULL_DISPLAY, "  ")?;
    assert_eq!(preferences.snapshot().null_display, "NULL");
    fixture.settings.gio().set_string(keys::NULL_DISPLAY, "no\nvalue\t")?;
    assert_eq!(preferences.snapshot().null_display, "novalue");
    fixture
        .settings
        .gio()
        .set_string(keys::NULL_DISPLAY, &"界".repeat(25))?;
    assert_eq!(preferences.snapshot().null_display, "界".repeat(20));
    Ok(())
}

#[glib::async_test]
async fn grid_preference_changes_ignore_unrelated_and_equivalent_values() -> TestResult {
    use std::cell::Cell;
    use std::rc::Rc;

    let fixture = Fixture::new()?;
    let calls = Rc::new(Cell::new(0));
    let observed = calls.clone();
    fixture
        .settings
        .grid_preferences()
        .connect_changed(move |_| observed.set(observed.get() + 1));

    fixture.settings.set_default_page_size(500)?;
    fixture.settings.set_null_display("")?;
    fixture.settings.set_null_display("NULL")?;

    assert_eq!(calls.get(), 0);
    assert!(fixture.settings.set_grid_row_height("unknown").is_err());
    assert_eq!(fixture.settings.grid_row_height(), "normal");
    Ok(())
}

#[glib::async_test]
async fn dropping_grid_preferences_disconnects_the_settings_handler() -> TestResult {
    use gio::prelude::*;

    let fixture = Fixture::new()?;
    let settings = fixture.settings.gio().clone();
    let preferences = fixture.settings.grid_preferences().downgrade();
    let changed = glib::subclass::SignalId::lookup("changed", gio::Settings::static_type()).expect("changed signal");
    assert!(glib::signal::signal_has_handler_pending(
        &settings, changed, None, false
    ));

    drop(fixture);

    assert!(preferences.upgrade().is_none());
    assert!(!glib::signal::signal_has_handler_pending(
        &settings, changed, None, false
    ));
    settings.set_boolean(keys::SHOW_ROW_NUMBERS, false)?;
    Ok(())
}

#[glib::async_test]
async fn settings_observers_run_while_another_thread_owns_the_global_context() -> TestResult {
    use std::cell::Cell;
    use std::rc::Rc;
    use std::sync::mpsc;

    let fixture = Fixture::new()?;
    let preferences = fixture.settings.grid_preferences();
    let calls = Rc::new(Cell::new(0));
    let observed = calls.clone();
    preferences.connect_changed(move |_| observed.set(observed.get() + 1));

    let (ready, started) = mpsc::sync_channel(0);
    let (release, released) = mpsc::channel();
    let owner = std::thread::spawn(move || {
        let context = glib::MainContext::default();
        let _guard = context.acquire().expect("only this worker uses the global context");
        ready.send(()).expect("the test waits for context ownership");
        let _ = released.recv();
    });
    started.recv()?;

    let changed = fixture.settings.set_show_row_numbers(false);
    let notifications = calls.get();
    let snapshot = preferences.snapshot();
    drop(release);
    owner.join().expect("the context owner exits");
    changed?;

    assert_eq!(notifications, 1);
    assert!(!snapshot.show_row_numbers);
    Ok(())
}

#[glib::async_test]
async fn grid_font_uses_the_shared_snapshot_and_preserves_the_editor_font() -> TestResult {
    use std::cell::Cell;
    use std::rc::Rc;

    let fixture = Fixture::new()?;
    let preferences = fixture.settings.grid_preferences();
    let calls = Rc::new(Cell::new(0));
    let observed = calls.clone();
    preferences.connect_changed(move |_| observed.set(observed.get() + 1));
    let editor_font = fixture.settings.editor_font();
    let custom = EditorFont::Custom("Sans Bold Italic 15".into());

    fixture.settings.set_grid_font(&custom)?;
    assert_eq!(preferences.snapshot().font, custom);
    assert_eq!(fixture.settings.grid_font(), custom);
    assert_eq!(calls.get(), 1);
    assert_eq!(fixture.settings.editor_font(), editor_font);

    fixture.settings.set_grid_font(&EditorFont::System)?;
    assert_eq!(preferences.snapshot().font, EditorFont::System);
    assert_eq!(calls.get(), 2);
    fixture.settings.set_grid_font(&custom)?;
    assert_eq!(preferences.snapshot().font, custom);
    assert_eq!(calls.get(), 3);
    Ok(())
}

#[glib::async_test]
async fn row_copy_format_publishes_every_format_through_the_shared_model() -> TestResult {
    use std::cell::RefCell;
    use std::rc::Rc;
    use tablepro_linux_platform::settings::RowCopyFormat;

    let fixture = Fixture::new()?;
    let preferences = fixture.settings.grid_preferences();
    let original = preferences.snapshot();
    let observed = Rc::new(RefCell::new(Vec::new()));
    let updates = observed.clone();
    preferences.connect_changed(move |preferences| updates.borrow_mut().push(preferences.snapshot().row_copy_format));

    assert_eq!(fixture.settings.row_copy_format(), RowCopyFormat::Rows);
    for format in RowCopyFormat::ALL {
        fixture.settings.set_row_copy_format(format.nick())?;
        assert_eq!(fixture.settings.row_copy_format(), format);
        assert_eq!(preferences.snapshot().row_copy_format, format);
        assert_eq!(RowCopyFormat::from_nick(format.nick()), format);
    }
    assert_eq!(observed.borrow().as_slice(), &RowCopyFormat::ALL[1..]);
    assert_eq!(original.row_copy_format, RowCopyFormat::Rows);
    assert_eq!(RowCopyFormat::from_nick("unknown"), RowCopyFormat::Rows);
    Ok(())
}

#[glib::async_test]
async fn automatic_details_preference_is_published_in_the_shared_snapshot() -> TestResult {
    use gio::prelude::SettingsExt;
    use std::cell::RefCell;
    use std::rc::Rc;

    let fixture = Fixture::new()?;
    let preferences = fixture.settings.grid_preferences();
    let original = preferences.snapshot();
    let observed = Rc::new(RefCell::new(Vec::new()));
    let changes = observed.clone();
    preferences.connect_changed(move |preferences| {
        changes.borrow_mut().push(preferences.snapshot().auto_show_inspector);
    });
    assert!(!fixture.settings.auto_show_inspector());

    fixture.settings.set_auto_show_inspector(true)?;
    assert!(fixture.settings.auto_show_inspector());
    fixture.settings.gio().set_boolean(keys::AUTO_SHOW_INSPECTOR, false)?;
    assert!(!fixture.settings.auto_show_inspector());
    assert_eq!(observed.borrow().as_slice(), &[true, false]);
    assert!(!original.auto_show_inspector);
    Ok(())
}

#[glib::async_test]
async fn default_sort_choices_and_direction_share_the_grid_snapshot() -> TestResult {
    use tablepro_linux_platform::settings::{DefaultSort, GridSortDirection};

    let fixture = Fixture::new()?;
    let preferences = fixture.settings.grid_preferences();
    assert_eq!(preferences.snapshot().default_sort, DefaultSort::None);
    assert_eq!(
        preferences.snapshot().default_sort_direction,
        GridSortDirection::Ascending
    );
    for choice in DefaultSort::ALL {
        fixture.settings.set_default_sort(choice.nick())?;
        assert_eq!(preferences.snapshot().default_sort, choice);
    }
    for direction in GridSortDirection::ALL {
        fixture.settings.set_default_sort_direction(direction.nick())?;
        assert_eq!(preferences.snapshot().default_sort_direction, direction);
    }
    assert!(fixture.settings.set_default_sort("unknown").is_err());
    assert!(fixture.settings.set_default_sort_direction("sideways").is_err());
    Ok(())
}
