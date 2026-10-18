use gettextrs::{LocaleCategory, bind_textdomain_codeset, bindtextdomain, setlocale, textdomain};
use thiserror::Error;

use crate::config;

pub use gettextrs::{gettext, ngettext, npgettext, pgettext};

#[derive(Debug, Error)]
pub enum I18nError {
    #[error("could not bind text domain {package} to {dir}: {source}")]
    BindTextDomain {
        package: &'static str,
        dir: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("could not set the text domain codeset to UTF-8: {0}")]
    Codeset(#[source] std::io::Error),
    #[error("could not select text domain {package}: {source}")]
    TextDomain {
        package: &'static str,
        #[source]
        source: std::io::Error,
    },
}

/// # Safety
///
/// `setlocale` mutates process-global locale state that other threads read
/// without synchronisation, so this must run before any other thread exists.
pub unsafe fn init() -> Result<(), I18nError> {
    unsafe {
        setlocale(LocaleCategory::LcAll, "");
    }
    bindtextdomain(config::GETTEXT_PACKAGE, config::LOCALEDIR).map_err(|source| I18nError::BindTextDomain {
        package: config::GETTEXT_PACKAGE,
        dir: config::LOCALEDIR,
        source,
    })?;
    bind_textdomain_codeset(config::GETTEXT_PACKAGE, "UTF-8").map_err(I18nError::Codeset)?;
    textdomain(config::GETTEXT_PACKAGE).map_err(|source| I18nError::TextDomain {
        package: config::GETTEXT_PACKAGE,
        source,
    })?;
    Ok(())
}

/// Translate, then fill `{name}` placeholders. Named rather than
/// positional so a translator can reorder them, and single-pass so a
/// value that itself contains braces is never expanded again.
pub fn gettext_f(msgid: &str, args: &[(&str, &str)]) -> String {
    substitute(&gettext(msgid), args)
}

pub fn ngettext_f(msgid: &str, plural: &str, n: u32, args: &[(&str, &str)]) -> String {
    substitute(&ngettext(msgid, plural, n), args)
}

pub fn pgettext_f(context: &str, msgid: &str, args: &[(&str, &str)]) -> String {
    substitute(&pgettext(context, msgid), args)
}

fn substitute(text: &str, args: &[(&str, &str)]) -> String {
    if args.is_empty() {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find('{') {
        let Some(close_offset) = rest[open..].find('}') else {
            break;
        };
        let close = open + close_offset;
        let name = &rest[open + 1..close];
        out.push_str(&rest[..open]);
        match args.iter().find(|(key, _)| *key == name) {
            Some((_, value)) => out.push_str(value),
            // An unknown placeholder stays literal: a translator typo
            // should show up in the string, not swallow it.
            None => out.push_str(&rest[open..=close]),
        }
        rest = &rest[close + 1..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substitute_fills_named_placeholders() {
        assert_eq!(
            substitute("{greeting}, {name}!", &[("greeting", "Hello"), ("name", "Dat")]),
            "Hello, Dat!"
        );
    }

    #[test]
    fn substitute_lets_a_translator_reorder_placeholders() {
        let args = [("first", "one"), ("second", "two")];

        assert_eq!(substitute("{first} {second}", &args), "one two");
        assert_eq!(substitute("{second} {first}", &args), "two one");
    }

    #[test]
    fn substitute_never_re_expands_a_value() {
        let filled = substitute("{outer}", &[("outer", "{inner}"), ("inner", "boom")]);

        assert_eq!(filled, "{inner}");
    }

    #[test]
    fn substitute_keeps_an_unknown_placeholder_literal() {
        assert_eq!(substitute("{known} {typo}", &[("known", "ok")]), "ok {typo}");
    }

    #[test]
    fn substitute_with_no_args_is_the_identity() {
        assert_eq!(substitute("{n} rows", &[]), "{n} rows");
        assert_eq!(substitute("plain", &[]), "plain");
    }

    #[test]
    fn substitute_leaves_an_unclosed_brace_alone() {
        assert_eq!(substitute("100% {of", &[("of", "x")]), "100% {of");
    }

    #[test]
    fn ngettext_f_picks_singular_or_plural_in_the_c_locale() {
        assert_eq!(ngettext_f("{n} row", "{n} rows", 1, &[("n", "1")]), "1 row");
        assert_eq!(ngettext_f("{n} row", "{n} rows", 4, &[("n", "4")]), "4 rows");
    }

    #[test]
    fn i18n_error_display() {
        let error = I18nError::BindTextDomain {
            package: "tablepro",
            dir: "/usr/share/locale",
            source: std::io::Error::from(std::io::ErrorKind::NotFound),
        };

        let message = error.to_string();

        assert!(message.contains("tablepro"));
        assert!(message.contains("/usr/share/locale"));
    }

    #[test]
    fn i18n_error_keeps_the_io_source() {
        let error = I18nError::Codeset(std::io::Error::from(std::io::ErrorKind::InvalidInput));

        assert!(std::error::Error::source(&error).is_some());
        assert!(error.to_string().contains("UTF-8"));
    }
}
