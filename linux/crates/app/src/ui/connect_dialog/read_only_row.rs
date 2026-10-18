use tablepro_core::ReadOnlyEnforcement;

/// What read-only mode really guarantees on this engine. The three
/// differ in whether a statement can still turn it off, so the switch
/// says which one the user is getting.
pub fn read_only_subtitle(enforcement: ReadOnlyEnforcement) -> String {
    match enforcement {
        ReadOnlyEnforcement::EngineEnforced => crate::i18n::gettext("The database refuses changes on this connection."),
        ReadOnlyEnforcement::SessionDefault => crate::i18n::gettext(
            "Changes are refused unless a statement turns read-only off. Use a read-only login for a guarantee.",
        ),
        ReadOnlyEnforcement::LoginPrivileges => {
            crate::i18n::gettext("SQL Server cannot enforce this. Use a login granted only SELECT.")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_enforcement_says_something_different() {
        let all = [
            ReadOnlyEnforcement::EngineEnforced,
            ReadOnlyEnforcement::SessionDefault,
            ReadOnlyEnforcement::LoginPrivileges,
        ];
        let texts: std::collections::HashSet<String> = all.into_iter().map(read_only_subtitle).collect();
        assert_eq!(texts.len(), all.len());
    }
}
