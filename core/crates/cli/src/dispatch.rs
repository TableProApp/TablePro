use std::ffi::{OsStr, OsString};
use std::path::Path;

use crate::command_line::SUBCOMMANDS;
use crate::output::escape_lines;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Dispatch {
    Command,
    Gui(Vec<OsString>),
    // The whole line for standard error, without its line break.
    Invalid(String),
}

// The GUI keeps every argument it reads today: files, URLs, -n and GApplication's own options.
// Only a word this crate owns is taken from it.
pub fn classify(args: &[OsString]) -> Dispatch {
    let Some(first) = args.get(1) else {
        return Dispatch::Gui(args.to_vec());
    };
    match first.to_str() {
        Some("-h" | "--help" | "--version" | "help") => Dispatch::Command,
        Some("open") => {
            let rest = args.get(2..).unwrap_or_default();
            if asks_for_help(rest) {
                return Dispatch::Command;
            }
            checked(args.iter().take(1).chain(rest).cloned().collect())
        }
        Some(word) if SUBCOMMANDS.contains(&word) => Dispatch::Command,
        _ => checked(args.to_vec()),
    }
}

fn asks_for_help(args: &[OsString]) -> bool {
    args.iter()
        .take_while(|&arg| arg != "--")
        .any(|arg| arg == "-h" || arg == "--help")
}

// A word that is neither a link nor a file is most likely a mistyped command, never something to open.
fn checked(args: Vec<OsString>) -> Dispatch {
    let mut options_ended = false;
    for arg in args.iter().skip(1) {
        if !options_ended {
            if arg == "--" {
                options_ended = true;
                continue;
            }
            if is_option(arg) {
                continue;
            }
        }
        if !has_scheme(arg) && !Path::new(arg).exists() {
            return Dispatch::Invalid(format!(
                "tablepro: No command or file named “{}”. Run tablepro --help to list the commands.",
                escape_lines(&arg.to_string_lossy())
            ));
        }
    }
    Dispatch::Gui(args)
}

fn is_option(arg: &OsStr) -> bool {
    let bytes = arg.as_encoded_bytes();
    bytes.len() > 1 && bytes.starts_with(b"-")
}

// RFC 3986 scheme. One letter is left out: on Windows it is a drive, as in C:\data.db.
fn has_scheme(arg: &OsStr) -> bool {
    let Some((scheme, _)) = arg.to_str().and_then(|text| text.split_once(':')) else {
        return false;
    };
    let mut characters = scheme.chars();
    scheme.len() > 1
        && characters.next().is_some_and(|first| first.is_ascii_alphabetic())
        && characters.all(|character| character.is_ascii_alphanumeric() || matches!(character, '+' | '-' | '.'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(words: &[&str]) -> Vec<OsString> {
        words.iter().map(OsString::from).collect()
    }

    fn classified(words: &[&str]) -> Dispatch {
        classify(&line(words))
    }

    #[test]
    fn a_command_word_goes_to_the_command_line() {
        for words in [
            &["tablepro", "query", "-c", "S", "SELECT 1"][..],
            &["tablepro", "connections"],
            &["tablepro", "databases"],
            &["tablepro", "schemas"],
            &["tablepro", "tables"],
            &["tablepro", "describe"],
            &["tablepro", "export"],
            &["tablepro", "status"],
            &["tablepro", "completion", "zsh"],
            &["tablepro", "help"],
            &["tablepro", "-h"],
            &["tablepro", "--help"],
            &["tablepro", "--version"],
            &["tablepro", "open", "--help"],
            &["tablepro", "open", "-n", "-h"],
        ] {
            assert_eq!(classified(words), Dispatch::Command, "{words:?}");
        }
    }

    #[test]
    fn the_gui_gets_its_own_arguments_unchanged() {
        for words in [
            &["tablepro"][..],
            &["tablepro", "-n"],
            &["tablepro", "--new-window"],
            &["tablepro", "--gapplication-service"],
            &["tablepro", "--help-all"],
            &["tablepro", "--help-gapplication"],
            &["tablepro", "postgresql://ada@db.example.com:5432/shop"],
            &["tablepro", "mongodb+srv://cluster.example.com/app"],
            &["tablepro", "jdbc:sqlserver://h:1433;databaseName=x"],
        ] {
            assert_eq!(classified(words), Dispatch::Gui(line(words)), "{words:?}");
        }
    }

    #[test]
    fn open_is_taken_off_and_files_pass_when_they_exist() {
        let dir = tempfile::tempdir().expect("a directory");
        let file = dir.path().join("query");
        std::fs::write(&file, "").expect("a file");
        let path = file.to_str().expect("a UTF-8 path");

        assert_eq!(
            classified(&["tablepro", "open", "-n", path]),
            Dispatch::Gui(line(&["tablepro", "-n", path]))
        );
        assert_eq!(
            classified(&["tablepro", path]),
            Dispatch::Gui(line(&["tablepro", path]))
        );
        assert_eq!(classified(&["tablepro", "open"]), Dispatch::Gui(line(&["tablepro"])));
    }

    #[test]
    fn a_word_that_is_neither_link_nor_file_is_refused() {
        for words in [
            &["tablepro", "querry"][..],
            &["tablepro", "version"],
            &["tablepro", "-n", "missing.db"],
            &["tablepro", "open", "query"],
            &["tablepro", "open", "--", "-missing.sql"],
            &["tablepro", "C:missing"],
        ] {
            assert!(matches!(classified(words), Dispatch::Invalid(_)), "{words:?}");
        }
    }

    #[test]
    fn the_refusal_names_the_word() {
        assert_eq!(
            classified(&["tablepro", "querry"]),
            Dispatch::Invalid(
                "tablepro: No command or file named “querry”. Run tablepro --help to list the commands.".to_owned()
            )
        );
    }
}
