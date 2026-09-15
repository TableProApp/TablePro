pub const DEFAULT_PAGE_SIZE: &str = "default-page-size";
pub const CONFIRM_DESTRUCTIVE: &str = "confirm-destructive";
pub const HISTORY_RETENTION_DAYS: &str = "history-retention-days";
pub const QUERY_TIMEOUT_SECS: &str = "query-timeout-secs";
pub const USE_SYSTEM_FONT: &str = "use-system-font";
pub const CUSTOM_FONT: &str = "custom-font";
pub const STYLE_SCHEME: &str = "style-scheme";

pub const CSV_NULL_TO_EMPTY: &str = "csv-null-to-empty";
pub const CSV_LINE_BREAK_TO_SPACE: &str = "csv-line-break-to-space";
pub const CSV_HEADER_ROW: &str = "csv-header-row";
pub const CSV_SANITIZE_FORMULAS: &str = "csv-sanitize-formulas";
pub const CSV_DELIMITER: &str = "csv-delimiter";
pub const CSV_QUOTE: &str = "csv-quote";
pub const CSV_LINE_BREAK: &str = "csv-line-break";
pub const CSV_DECIMAL: &str = "csv-decimal";

pub(crate) const WINDOW_WIDTH: &str = "window-width";
pub(crate) const WINDOW_HEIGHT: &str = "window-height";
pub(crate) const IS_MAXIMIZED: &str = "is-maximized";

pub(crate) const CSV_KEYS: [&str; 8] = [
    CSV_NULL_TO_EMPTY,
    CSV_LINE_BREAK_TO_SPACE,
    CSV_HEADER_ROW,
    CSV_SANITIZE_FORMULAS,
    CSV_DELIMITER,
    CSV_QUOTE,
    CSV_LINE_BREAK,
    CSV_DECIMAL,
];
