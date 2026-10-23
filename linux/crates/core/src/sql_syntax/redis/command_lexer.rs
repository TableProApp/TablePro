use std::ops::Range;

use thiserror::Error;

/// Why a command's text has no arguments to send.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CommandSyntaxError {
    #[error("there is no command")]
    Empty,
    /// A quote never closes, or a closing quote runs straight into more
    /// text, which redis-cli refuses too.
    #[error("a quote in the command is not closed where an argument ends")]
    UnbalancedQuotes,
    #[error("the text holds more than one command")]
    SeveralCommands,
}

/// How one argument was written.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ArgumentForm {
    Bare,
    Quoted,
    /// A quote opened and never closed, so the argument runs to the end
    /// of the text.
    Unterminated,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LexedArgument {
    pub range: Range<usize>,
    pub form: ArgumentForm,
    /// Where the first quote of the argument opened, for a diagnostic.
    pub quote_start: Option<usize>,
}

/// One command: the arguments on one line, a quoted line break aside.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LexedCommand {
    /// From the first argument's first byte to the last argument's last.
    pub range: Range<usize>,
    pub arguments: Vec<LexedArgument>,
    /// The bytes each argument stands for, or why they cannot be sent.
    pub values: Result<Vec<Vec<u8>>, CommandSyntaxError>,
}

/// Every command in `text`, one per line, read as redis-cli's
/// `sdssplitargs` reads a line: blanks part arguments, `"..."` takes the
/// C escapes and `\xHH`, `'...'` takes only `\'`, and a quote may open in
/// the middle of an argument. A line break outside quotes ends a command.
pub fn split_commands(text: &str) -> Vec<LexedCommand> {
    let mut lexer = Lexer {
        bytes: text.as_bytes(),
        at: 0,
    };
    let mut commands = Vec::new();
    while let Some(command) = lexer.next_command() {
        commands.push(command);
    }
    commands
}

/// The arguments of the one command `text` holds.
pub fn split_command(text: &str) -> Result<Vec<Vec<u8>>, CommandSyntaxError> {
    let mut commands = split_commands(text).into_iter();
    let Some(command) = commands.next() else {
        return Err(CommandSyntaxError::Empty);
    };
    if commands.next().is_some() {
        return Err(CommandSyntaxError::SeveralCommands);
    }
    command.values
}

struct Lexer<'a> {
    bytes: &'a [u8],
    at: usize,
}

struct Argument {
    value: Vec<u8>,
    form: ArgumentForm,
    quote_start: Option<usize>,
    balanced: bool,
}

impl Lexer<'_> {
    fn next_command(&mut self) -> Option<LexedCommand> {
        let mut arguments = Vec::new();
        let mut values = Vec::new();
        let mut balanced = true;
        while let Some(&byte) = self.bytes.get(self.at) {
            if ends_line(byte) {
                self.at += 1;
                if !arguments.is_empty() {
                    break;
                }
                continue;
            }
            if is_blank(byte) {
                self.at += 1;
                continue;
            }
            let start = self.at;
            let argument = self.argument();
            balanced &= argument.balanced;
            arguments.push(LexedArgument {
                range: start..self.at,
                form: argument.form,
                quote_start: argument.quote_start,
            });
            values.push(argument.value);
        }
        let first = arguments.first()?.range.start;
        let last = arguments.last().map_or(first, |argument| argument.range.end);
        Some(LexedCommand {
            range: first..last,
            arguments,
            values: if balanced {
                Ok(values)
            } else {
                Err(CommandSyntaxError::UnbalancedQuotes)
            },
        })
    }

    fn argument(&mut self) -> Argument {
        let mut argument = Argument {
            value: Vec::new(),
            form: ArgumentForm::Bare,
            quote_start: None,
            balanced: true,
        };
        while let Some(&byte) = self.bytes.get(self.at) {
            match byte {
                b'"' | b'\'' => {
                    argument.form = ArgumentForm::Quoted;
                    argument.quote_start.get_or_insert(self.at);
                    self.at += 1;
                    let closed = match byte {
                        b'"' => self.double_quoted(&mut argument.value),
                        _ => self.single_quoted(&mut argument.value),
                    };
                    if !closed {
                        argument.form = ArgumentForm::Unterminated;
                        argument.balanced = false;
                        return argument;
                    }
                    // redis-cli takes a closing quote only where an
                    // argument ends.
                    if self.bytes.get(self.at).is_some_and(|&next| !ends_bare(next)) {
                        argument.balanced = false;
                    }
                }
                _ if ends_bare(byte) => return argument,
                _ => {
                    argument.value.push(byte);
                    self.at += 1;
                }
            }
        }
        argument
    }

    /// Read past the closing `"`, or to the end of the text when there is
    /// none.
    fn double_quoted(&mut self, value: &mut Vec<u8>) -> bool {
        while let Some(&byte) = self.bytes.get(self.at) {
            match byte {
                b'"' => {
                    self.at += 1;
                    return true;
                }
                b'\\' => {
                    let escaped = self.bytes.get(self.at + 1).copied();
                    let hex = self.hex_byte(self.at + 2);
                    match (escaped, hex) {
                        (Some(b'x'), Some(decoded)) => {
                            value.push(decoded);
                            self.at += 4;
                        }
                        (Some(escaped), _) => {
                            value.push(unescaped(escaped));
                            self.at += 2;
                        }
                        (None, _) => {
                            value.push(b'\\');
                            self.at += 1;
                        }
                    }
                }
                _ => {
                    value.push(byte);
                    self.at += 1;
                }
            }
        }
        false
    }

    fn single_quoted(&mut self, value: &mut Vec<u8>) -> bool {
        while let Some(&byte) = self.bytes.get(self.at) {
            match byte {
                b'\'' => {
                    self.at += 1;
                    return true;
                }
                b'\\' if self.bytes.get(self.at + 1) == Some(&b'\'') => {
                    value.push(b'\'');
                    self.at += 2;
                }
                _ => {
                    value.push(byte);
                    self.at += 1;
                }
            }
        }
        false
    }

    fn hex_byte(&self, at: usize) -> Option<u8> {
        let high = hex_value(*self.bytes.get(at)?)?;
        let low = hex_value(*self.bytes.get(at + 1)?)?;
        Some(high << 4 | low)
    }
}

fn ends_line(byte: u8) -> bool {
    matches!(byte, b'\n' | b'\r')
}

/// `sdssplitargs` skips every `isspace` byte between arguments.
fn is_blank(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | 0x0B | 0x0C)
}

/// But only these end an argument that is not quoted.
fn ends_bare(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | b'\r' | 0)
}

fn unescaped(byte: u8) -> u8 {
    match byte {
        b'n' => b'\n',
        b'r' => b'\r',
        b't' => b'\t',
        b'b' => 0x08,
        b'a' => 0x07,
        other => other,
    }
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn values(text: &str) -> Vec<Result<Vec<Vec<u8>>, CommandSyntaxError>> {
        split_commands(text).into_iter().map(|command| command.values).collect()
    }

    fn args(parts: &[&[u8]]) -> Result<Vec<Vec<u8>>, CommandSyntaxError> {
        Ok(parts.iter().map(|part| part.to_vec()).collect())
    }

    #[test]
    fn each_line_is_a_command() {
        assert_eq!(
            values("SET a 1\n\nGET a\r\nDEL a"),
            vec![
                args(&[b"SET", b"a", b"1"]),
                args(&[b"GET", b"a"]),
                args(&[b"DEL", b"a"])
            ]
        );
    }

    #[test]
    fn a_semicolon_is_part_of_an_argument() {
        assert_eq!(values("SET k a;b"), vec![args(&[b"SET", b"k", b"a;b"])]);
    }

    #[test]
    fn double_quotes_take_escapes_and_hex_bytes() {
        assert_eq!(
            values(r#"SET "my key" "tab\there\x41\xff\"q""#),
            vec![args(&[b"SET", b"my key", b"tab\there\x41\xff\"q"])]
        );
    }

    #[test]
    fn single_quotes_take_only_an_escaped_quote() {
        assert_eq!(
            values(r"SET k 'it\'s \n raw'"),
            vec![args(&[b"SET", b"k", br"it's \n raw"])]
        );
    }

    #[test]
    fn a_quoted_line_break_stays_in_its_argument() {
        let commands = split_commands("SET k \"two\nlines\"\nGET k");

        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].values, args(&[b"SET", b"k", b"two\nlines"]));
    }

    #[test]
    fn a_quote_can_open_inside_an_argument() {
        assert_eq!(values(r#"GET user:"a b""#), vec![args(&[b"GET", b"user:a b"])]);
    }

    #[test]
    fn a_quote_that_never_closes_runs_to_the_end() {
        let commands = split_commands("GET \"open\nGET b");

        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].values, Err(CommandSyntaxError::UnbalancedQuotes));
        assert_eq!(commands[0].arguments[1].form, ArgumentForm::Unterminated);
        assert_eq!(commands[0].arguments[1].quote_start, Some(4));
    }

    #[test]
    fn a_closing_quote_must_end_its_argument() {
        assert_eq!(values(r#"GET "a"b"#), vec![Err(CommandSyntaxError::UnbalancedQuotes)]);
    }

    #[test]
    fn a_command_spans_its_arguments() {
        let commands = split_commands("  GET  key  \n");

        assert_eq!(commands[0].range, 2..10);
    }

    #[test]
    fn one_command_is_read_alone() {
        assert_eq!(split_command(" PING "), args(&[b"PING"]));
        assert_eq!(split_command("  \n "), Err(CommandSyntaxError::Empty));
        assert_eq!(split_command("PING\nPING"), Err(CommandSyntaxError::SeveralCommands));
    }
}
