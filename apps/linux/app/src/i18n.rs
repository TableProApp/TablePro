use gettextrs::{LocaleCategory, bind_textdomain_codeset, bindtextdomain, setlocale, textdomain};

pub const DOMAIN: &str = "tablepro";

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
