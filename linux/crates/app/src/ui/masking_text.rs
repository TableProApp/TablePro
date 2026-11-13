use tablepro_core::masking::detect::SensitiveKind;
use tablepro_core::masking::{MaskingStyle, MaskingTarget};

use crate::i18n::gettext;

// A masking style as the connect dialog and the share sheet name it.
pub(crate) fn style_label(style: MaskingStyle) -> String {
    match style {
        MaskingStyle::Full => gettext("Full"),
        MaskingStyle::LastFour => gettext("Last 4 Characters"),
        MaskingStyle::Email => gettext("Email"),
        MaskingStyle::Hash => gettext("Stable Hash"),
        MaskingStyle::Null => gettext("NULL"),
    }
}

pub(crate) fn target_label(target: MaskingTarget) -> String {
    match target {
        MaskingTarget::Column => gettext("Column"),
        MaskingTarget::Type => gettext("Type"),
    }
}

// What a column's values look like, for the share sheet's reason.
pub(crate) fn values_reason(kind: SensitiveKind) -> String {
    match kind {
        SensitiveKind::Card => gettext("Values look like card numbers"),
        SensitiveKind::Iban => gettext("Values look like IBANs"),
        SensitiveKind::Jwt => gettext("Values look like access tokens"),
        SensitiveKind::ApiKey => gettext("Values look like API keys"),
        SensitiveKind::Email => gettext("Values look like email addresses"),
        SensitiveKind::Phone => gettext("Values look like phone numbers"),
        SensitiveKind::Ip => gettext("Values look like IP addresses"),
    }
}

// One piece of personal data a query's text holds, for the Hide SQL notice.
pub(crate) fn personal_data_kind(kind: SensitiveKind) -> String {
    match kind {
        SensitiveKind::Card => gettext("a card number"),
        SensitiveKind::Iban => gettext("an IBAN"),
        SensitiveKind::Jwt => gettext("an access token"),
        SensitiveKind::ApiKey => gettext("an API key"),
        SensitiveKind::Email => gettext("an email address"),
        SensitiveKind::Phone => gettext("a phone number"),
        SensitiveKind::Ip => gettext("an IP address"),
    }
}
