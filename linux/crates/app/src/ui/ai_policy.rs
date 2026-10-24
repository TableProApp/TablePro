use tablepro_core::AiPolicy;

pub(crate) fn label(policy: AiPolicy) -> String {
    match policy {
        AiPolicy::Ask => crate::i18n::gettext("Ask Each Time"),
        AiPolicy::Allow => crate::i18n::gettext("Allow"),
        AiPolicy::Never => crate::i18n::gettext("Never"),
    }
}

pub(crate) fn subtitle(policy: AiPolicy) -> String {
    match policy {
        AiPolicy::Ask => crate::i18n::gettext(
            "The assistant asks before it first sends this connection’s structure, and your answer lasts until the window disconnects.",
        ),
        AiPolicy::Allow => crate::i18n::gettext(
            "The assistant sends this connection’s table structure and your SQL to the provider without asking. It reads no rows.",
        ),
        AiPolicy::Never => crate::i18n::gettext(
            "Nothing from this connection is sent to the AI provider, and the assistant is off here.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn each_policy_has_its_own_label_and_subtitle() {
        let labels: HashSet<String> = AiPolicy::ALL.into_iter().map(label).collect();
        let subtitles: HashSet<String> = AiPolicy::ALL.into_iter().map(subtitle).collect();

        assert_eq!(labels.len(), AiPolicy::ALL.len());
        assert_eq!(subtitles.len(), AiPolicy::ALL.len());
    }
}
