use gettextrs::{LocaleCategory, bind_textdomain_codeset, bindtextdomain, setlocale, textdomain};

pub const DOMAIN: &str = "bookie";

pub fn init() {
    unsafe {
        setlocale(LocaleCategory::LcAll, "");
    }
    let dir = locale_dir();
    if let Err(e) = bindtextdomain(DOMAIN, dir) {
        tracing::debug!(error = %e, "bindtextdomain failed; falling back to msgid");
    }
    if let Err(e) = bind_textdomain_codeset(DOMAIN, "UTF-8") {
        tracing::debug!(error = %e, "bind_textdomain_codeset failed");
    }
    if let Err(e) = textdomain(DOMAIN) {
        tracing::debug!(error = %e, "textdomain failed");
    }
}

fn locale_dir() -> String {
    if let Ok(d) = std::env::var("TABLEPRO_LOCALEDIR") {
        return d;
    }
    if std::path::Path::new("/app/share/locale").is_dir() {
        return "/app/share/locale".into();
    }
    "/usr/share/locale".into()
}

#[macro_export]
macro_rules! tr {
    ($s:expr $(,)?) => {
        ::gettextrs::gettext($s)
    };
}

#[macro_export]
macro_rules! trn {
    ($one:expr, $many:expr, $n:expr $(,)?) => {
        ::gettextrs::ngettext($one, $many, u32::try_from($n).unwrap_or(u32::MAX))
    };
}

#[cfg(test)]
mod tests {
    #[test]
    fn plural_messages_choose_the_form_for_the_count() {
        assert_eq!(
            crate::trn!("Delete {n} row?", "Delete {n} rows?", 1usize),
            "Delete {n} row?"
        );
        assert_eq!(
            crate::trn!("Delete {n} row?", "Delete {n} rows?", 2usize),
            "Delete {n} rows?"
        );
        assert_eq!(
            crate::trn!("Delete {n} row?", "Delete {n} rows?", usize::MAX),
            "Delete {n} rows?"
        );
    }
}
