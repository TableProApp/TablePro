mod editor_font;
mod error;
pub mod keys;
mod window_geometry;

use std::path::Path;
use std::time::Duration;

use gio::prelude::SettingsExt;
use tablepro_core::export::{CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote};

pub use editor_font::EditorFont;
pub use error::SettingsError;
pub use window_geometry::WindowGeometry;

pub struct AppSettings {
    settings: gio::Settings,
}

impl AppSettings {
    /// Opens the installed schema. `gio::Settings::new` aborts the
    /// process when the schema is missing, so the lookup happens first
    /// and a missing schema comes back as an error.
    pub fn open(schema_id: &str) -> Result<Self, SettingsError> {
        let source =
            gio::SettingsSchemaSource::default().ok_or_else(|| SettingsError::SchemaNotFound(schema_id.to_owned()))?;
        let schema = source
            .lookup(schema_id, true)
            .ok_or_else(|| SettingsError::SchemaNotFound(schema_id.to_owned()))?;
        Ok(Self {
            settings: gio::Settings::new_full(&schema, gio::SettingsBackend::NONE, None),
        })
    }

    /// Opens a schema compiled somewhere other than the system path,
    /// against a caller-supplied backend. Tests use it with a memory
    /// backend so they never touch the user's dconf database.
    pub fn with_backend(
        schema_id: &str,
        schema_dir: &Path,
        backend: &gio::SettingsBackend,
    ) -> Result<Self, SettingsError> {
        let source = gio::SettingsSchemaSource::from_directory(schema_dir, None, true).map_err(|source| {
            SettingsError::SchemaDirectory {
                path: schema_dir.to_owned(),
                source,
            }
        })?;
        let schema = source
            .lookup(schema_id, true)
            .ok_or_else(|| SettingsError::SchemaNotFound(schema_id.to_owned()))?;
        Ok(Self {
            settings: gio::Settings::new_full(&schema, Some(backend), None),
        })
    }

    /// The underlying settings, for `bind` on a preference row.
    pub fn gio(&self) -> &gio::Settings {
        &self.settings
    }

    pub fn default_page_size(&self) -> u32 {
        self.settings.uint(keys::DEFAULT_PAGE_SIZE)
    }

    pub fn set_default_page_size(&self, rows: u32) -> Result<(), SettingsError> {
        self.set_uint(keys::DEFAULT_PAGE_SIZE, rows)
    }

    pub fn confirm_destructive(&self) -> bool {
        self.settings.boolean(keys::CONFIRM_DESTRUCTIVE)
    }

    pub fn set_confirm_destructive(&self, confirm: bool) -> Result<(), SettingsError> {
        self.set_boolean(keys::CONFIRM_DESTRUCTIVE, confirm)
    }

    pub fn history_retention_days(&self) -> u32 {
        self.settings.uint(keys::HISTORY_RETENTION_DAYS)
    }

    pub fn set_history_retention_days(&self, days: u32) -> Result<(), SettingsError> {
        self.set_uint(keys::HISTORY_RETENTION_DAYS, days)
    }

    /// `None` when the user turned the timeout off, so callers cannot
    /// mistake a zero-second deadline for "no deadline".
    pub fn query_timeout(&self) -> Option<Duration> {
        match self.settings.uint(keys::QUERY_TIMEOUT_SECS) {
            0 => None,
            seconds => Some(Duration::from_secs(u64::from(seconds))),
        }
    }

    pub fn set_query_timeout_secs(&self, seconds: u32) -> Result<(), SettingsError> {
        self.set_uint(keys::QUERY_TIMEOUT_SECS, seconds)
    }

    pub fn editor_font(&self) -> EditorFont {
        if self.settings.boolean(keys::USE_SYSTEM_FONT) {
            EditorFont::System
        } else {
            EditorFont::Custom(self.settings.string(keys::CUSTOM_FONT).into())
        }
    }

    pub fn set_editor_font(&self, font: &EditorFont) -> Result<(), SettingsError> {
        match font {
            EditorFont::System => self.set_boolean(keys::USE_SYSTEM_FONT, true),
            EditorFont::Custom(description) => {
                self.set_string(keys::CUSTOM_FONT, description)?;
                self.set_boolean(keys::USE_SYSTEM_FONT, false)
            }
        }
    }

    pub fn style_scheme(&self) -> String {
        self.settings.string(keys::STYLE_SCHEME).into()
    }

    pub fn set_style_scheme(&self, scheme: &str) -> Result<(), SettingsError> {
        self.set_string(keys::STYLE_SCHEME, scheme)
    }

    /// The driver the connect dialog opens on. Remembered so the
    /// common case is one click, not a combo hunt every time.
    pub fn connect_dialog_driver(&self) -> String {
        self.settings.string(keys::CONNECT_DIALOG_DRIVER).into()
    }

    pub fn set_connect_dialog_driver(&self, driver_id: &str) -> Result<(), SettingsError> {
        self.set_string(keys::CONNECT_DIALOG_DRIVER, driver_id)
    }

    pub fn csv_options(&self) -> CsvOptions {
        CsvOptions {
            null_to_empty: self.settings.boolean(keys::CSV_NULL_TO_EMPTY),
            line_break_to_space: self.settings.boolean(keys::CSV_LINE_BREAK_TO_SPACE),
            header_row: self.settings.boolean(keys::CSV_HEADER_ROW),
            sanitize_formulas: self.settings.boolean(keys::CSV_SANITIZE_FORMULAS),
            delimiter: delimiter_from(&self.settings.string(keys::CSV_DELIMITER)),
            quote: quote_from(&self.settings.string(keys::CSV_QUOTE)),
            line_break: line_break_from(&self.settings.string(keys::CSV_LINE_BREAK)),
            decimal: decimal_from(&self.settings.string(keys::CSV_DECIMAL)),
        }
    }

    pub fn set_csv_options(&self, options: &CsvOptions) -> Result<(), SettingsError> {
        self.set_boolean(keys::CSV_NULL_TO_EMPTY, options.null_to_empty)?;
        self.set_boolean(keys::CSV_LINE_BREAK_TO_SPACE, options.line_break_to_space)?;
        self.set_boolean(keys::CSV_HEADER_ROW, options.header_row)?;
        self.set_boolean(keys::CSV_SANITIZE_FORMULAS, options.sanitize_formulas)?;
        self.set_string(keys::CSV_DELIMITER, delimiter_nick(options.delimiter))?;
        self.set_string(keys::CSV_QUOTE, quote_nick(options.quote))?;
        self.set_string(keys::CSV_LINE_BREAK, line_break_nick(options.line_break))?;
        self.set_string(keys::CSV_DECIMAL, decimal_nick(options.decimal))
    }

    pub fn reset_csv_options(&self) {
        for key in keys::CSV_KEYS {
            self.settings.reset(key);
        }
    }

    pub fn window_geometry(&self) -> WindowGeometry {
        WindowGeometry {
            width: self.settings.int(keys::WINDOW_WIDTH),
            height: self.settings.int(keys::WINDOW_HEIGHT),
            maximized: self.settings.boolean(keys::IS_MAXIMIZED),
        }
    }

    pub fn set_window_geometry(&self, geometry: WindowGeometry) -> Result<(), SettingsError> {
        self.set_int(keys::WINDOW_WIDTH, geometry.width)?;
        self.set_int(keys::WINDOW_HEIGHT, geometry.height)?;
        self.set_boolean(keys::IS_MAXIMIZED, geometry.maximized)
    }

    fn set_boolean(&self, key: &'static str, value: bool) -> Result<(), SettingsError> {
        self.settings
            .set_boolean(key, value)
            .map_err(|source| SettingsError::Write { key, source })
    }

    fn set_uint(&self, key: &'static str, value: u32) -> Result<(), SettingsError> {
        self.settings
            .set_uint(key, value)
            .map_err(|source| SettingsError::Write { key, source })
    }

    fn set_int(&self, key: &'static str, value: i32) -> Result<(), SettingsError> {
        self.settings
            .set_int(key, value)
            .map_err(|source| SettingsError::Write { key, source })
    }

    fn set_string(&self, key: &'static str, value: &str) -> Result<(), SettingsError> {
        self.settings
            .set_string(key, value)
            .map_err(|source| SettingsError::Write { key, source })
    }
}

fn delimiter_nick(delimiter: CsvDelimiter) -> &'static str {
    match delimiter {
        CsvDelimiter::Comma => "comma",
        CsvDelimiter::Semicolon => "semicolon",
        CsvDelimiter::Tab => "tab",
        CsvDelimiter::Pipe => "pipe",
    }
}

fn delimiter_from(nick: &str) -> CsvDelimiter {
    match nick {
        "semicolon" => CsvDelimiter::Semicolon,
        "tab" => CsvDelimiter::Tab,
        "pipe" => CsvDelimiter::Pipe,
        _ => CsvDelimiter::Comma,
    }
}

fn quote_nick(quote: CsvQuote) -> &'static str {
    match quote {
        CsvQuote::Always => "always",
        CsvQuote::IfNeeded => "if-needed",
        CsvQuote::Never => "never",
    }
}

fn quote_from(nick: &str) -> CsvQuote {
    match nick {
        "always" => CsvQuote::Always,
        "never" => CsvQuote::Never,
        _ => CsvQuote::IfNeeded,
    }
}

fn line_break_nick(line_break: CsvLineBreak) -> &'static str {
    match line_break {
        CsvLineBreak::Lf => "lf",
        CsvLineBreak::CrLf => "crlf",
        CsvLineBreak::Cr => "cr",
    }
}

fn line_break_from(nick: &str) -> CsvLineBreak {
    match nick {
        "crlf" => CsvLineBreak::CrLf,
        "cr" => CsvLineBreak::Cr,
        _ => CsvLineBreak::Lf,
    }
}

fn decimal_nick(decimal: CsvDecimal) -> &'static str {
    match decimal {
        CsvDecimal::Period => "period",
        CsvDecimal::Comma => "comma",
    }
}

fn decimal_from(nick: &str) -> CsvDecimal {
    match nick {
        "comma" => CsvDecimal::Comma,
        _ => CsvDecimal::Period,
    }
}
