use std::borrow::Cow;
use std::io::{self, Write};

use crate::command_error::CommandError;
use crate::exit::Exit;
use crate::host::Terminal;
use crate::output::{OutputFormat, Table, escape_lines, render};

pub(crate) struct Console<'a> {
    out: &'a mut dyn Write,
    err: &'a mut dyn Write,
    terminal: Terminal,
}

impl<'a> Console<'a> {
    pub(crate) fn new(out: &'a mut dyn Write, err: &'a mut dyn Write, terminal: Terminal) -> Self {
        Self { out, err, terminal }
    }

    pub(crate) fn terminal(&self) -> Terminal {
        self.terminal
    }

    pub(crate) fn write_out(&mut self, bytes: &[u8]) -> Result<(), CommandError> {
        self.out
            .write_all(bytes)
            .and_then(|()| self.out.flush())
            .map_err(CommandError::Output)
    }

    pub(crate) fn text(&mut self, text: &str) -> Result<(), CommandError> {
        let text = match self.terminal.stdout {
            true => escape_lines(text),
            false => Cow::Borrowed(text),
        };
        self.write_out(text.as_bytes())
    }

    pub(crate) fn tables(&mut self, tables: &[Table], format: Option<OutputFormat>) -> Result<(), CommandError> {
        let text = render(tables, OutputFormat::or_default(format, self.terminal));
        self.text(&text)
    }

    pub(crate) fn note(&mut self, text: &str) {
        self.line(&format!("tablepro: {text}"));
    }

    // Server text can carry escape sequences, and a terminal would run them.
    pub(crate) fn line(&mut self, text: &str) {
        let text = match self.terminal.stderr {
            true => escape_lines(text),
            false => Cow::Borrowed(text),
        };
        // Standard error is the last place to report to; a failed write has nowhere to go.
        let _ = writeln!(self.err, "{text}");
    }

    pub(crate) fn fail(&mut self, error: &CommandError) -> Exit {
        tracing::debug!(code = error.code(), "the command failed");
        // The reader stopped reading, as `| head` does; that is not the command failing.
        if let CommandError::Output(cause) = error
            && cause.kind() == io::ErrorKind::BrokenPipe
        {
            return Exit::Success;
        }
        self.note(&error.to_string());
        error.exit()
    }

    pub(crate) fn parse_failed(&mut self, error: &clap::Error) -> Exit {
        let text = error.render().to_string();
        if !error.use_stderr() {
            return match self.write_out(text.as_bytes()) {
                Ok(()) => Exit::Success,
                Err(failure) => self.fail(&failure),
            };
        }
        let text = match self.terminal.stderr {
            true => escape_lines(&text),
            false => Cow::Borrowed(text.as_str()),
        };
        let _ = self.err.write_all(text.as_bytes());
        Exit::Usage
    }
}
