use clap::ValueEnum;
use serde::Serialize;

use crate::host::Terminal;

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum OutputFormat {
    Csv,
    Tsv,
    Json,
    Jsonl,
    Table,
}

impl OutputFormat {
    // A person reads a terminal; a pipe or a file is read by a program.
    pub(crate) fn or_default(format: Option<Self>, terminal: Terminal) -> Self {
        match (format, terminal.stdout) {
            (Some(format), _) => format,
            (None, true) => Self::Table,
            (None, false) => Self::Csv,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ExportFormat {
    Csv,
    Json,
    Sql,
}
