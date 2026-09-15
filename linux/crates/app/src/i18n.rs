use gettextrs::{LocaleCategory, bind_textdomain_codeset, bindtextdomain, setlocale, textdomain};
use thiserror::Error;

use crate::config;

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

#[macro_export]
macro_rules! tr {
    ($s:expr $(,)?) => {
        ::gettextrs::gettext($s)
    };
}

#[cfg(test)]
mod tests {
    use super::*;

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
