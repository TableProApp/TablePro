// The categories this device syncs (0054, Rules for both providers): a kind turned off sends nothing and takes nothing,
// and the password switch does the same for envelopes. What a pull passed over while a kind was off is read again
// once it is on, so a deletion pulled meanwhile lands then.

use std::collections::BTreeSet;

use tablepro_records::Kind;

use crate::api::control::SyncCategories;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceCategories {
    off: BTreeSet<Kind>,
    passwords: bool,
}

// Everything syncs until the app says otherwise.
impl Default for DeviceCategories {
    fn default() -> Self {
        Self {
            off: BTreeSet::new(),
            passwords: true,
        }
    }
}

impl From<&SyncCategories> for DeviceCategories {
    fn from(categories: &SyncCategories) -> Self {
        Self {
            // A kind this build does not know has no store to turn off.
            off: categories.off.iter().filter_map(|kind| kind.known()).collect(),
            passwords: categories.passwords,
        }
    }
}

impl DeviceCategories {
    // Key objects sync whatever the person turned off: the account's keys and the teams' rest on them.
    pub fn syncs(&self, kind: Kind) -> bool {
        if kind.is_key() {
            return true;
        }
        if kind == Kind::SecretEnvelope && !self.passwords {
            return false;
        }
        !self.off.contains(&kind)
    }

    // The kinds on, for a transport that takes them as a set.
    pub fn on(&self) -> impl Iterator<Item = Kind> + '_ {
        Kind::ALL.into_iter().filter(|kind| self.syncs(*kind))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ids::KindName;

    #[test]
    fn an_off_kind_and_the_password_switch_stop_their_kinds_but_never_key_objects() {
        let categories = DeviceCategories::from(&SyncCategories {
            off: vec![KindName::of(Kind::MacosSettings), KindName::of(Kind::KeyAccount)],
            passwords: false,
        });

        assert!(!categories.syncs(Kind::MacosSettings));
        assert!(!categories.syncs(Kind::SecretEnvelope));
        assert!(categories.syncs(Kind::KeyAccount));
        assert!(categories.syncs(Kind::Connection));
        assert!(DeviceCategories::default().syncs(Kind::SecretEnvelope));
    }
}
