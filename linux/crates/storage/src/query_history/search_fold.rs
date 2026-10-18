/// The form a stored query and a search term are compared in. The
/// trigram index is case sensitive and only ever sees this form, so `É`
/// finds `é` while the index stays usable for every term.
pub(crate) fn fold(text: &str) -> String {
    text.to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::fold;

    #[test]
    fn folds_beyond_ascii() {
        assert_eq!(fold("SELECT * FROM ÉLÈVES"), "select * from élèves");
    }
}
