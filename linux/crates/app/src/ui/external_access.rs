use tablepro_core::ExternalAccess;

pub(crate) fn label(access: ExternalAccess) -> String {
    match access {
        ExternalAccess::Blocked => crate::i18n::gettext("Blocked"),
        ExternalAccess::ReadOnly => crate::i18n::gettext("Read Only"),
        ExternalAccess::ReadWrite => crate::i18n::gettext("Read & Write"),
    }
}

pub(crate) fn subtitle(access: ExternalAccess) -> String {
    match access {
        ExternalAccess::Blocked => crate::i18n::gettext("MCP clients do not see this connection."),
        ExternalAccess::ReadOnly => {
            crate::i18n::gettext("MCP clients can read the schema and the data. Every write is refused.")
        }
        ExternalAccess::ReadWrite => crate::i18n::gettext(
            "MCP clients can also write. Each statement waits for your approval in TablePro, and Safe Mode Read-Only still refuses it.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn each_level_has_its_own_label_and_subtitle() {
        let labels: HashSet<String> = ExternalAccess::ALL.into_iter().map(label).collect();
        let subtitles: HashSet<String> = ExternalAccess::ALL.into_iter().map(subtitle).collect();

        assert_eq!(labels.len(), ExternalAccess::ALL.len());
        assert_eq!(subtitles.len(), ExternalAccess::ALL.len());
    }
}
