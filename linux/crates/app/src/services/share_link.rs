use gio::prelude::FileExt;

pub const SHARE_LINK_SCHEME: &str = "tablepro";

// Read from the text, as a connection link is: a GFile a VFS rewrote can report no scheme at all.
pub fn is_share_link(uri: &str) -> bool {
    glib::Uri::peek_scheme(uri).is_some_and(|scheme| scheme == SHARE_LINK_SCHEME)
}

pub fn share_link_text(file: &gio::File) -> Option<String> {
    let uri = file.uri();
    is_share_link(&uri).then(|| uri.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK";

    #[test]
    fn only_the_tablepro_scheme_is_a_share_link() {
        assert!(is_share_link(&format!("tablepro://share?token={TOKEN}")));
        assert!(is_share_link("TablePro://share"));
        assert!(!is_share_link(&format!("https://s.tablepro.app/{TOKEN}")));
        assert!(!is_share_link("postgresql://localhost/shop"));
        assert!(!is_share_link("/home/ada/tablepro://share"));
    }
}
