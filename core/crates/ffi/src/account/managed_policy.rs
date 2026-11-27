use tablepro_account::{ManagedPolicy, PolicyValues, SyncChoices, SyncProvider};

// The values the OS marks as managed, read from the host's channel (core ADR 0055, Keys). A value of another type is
// passed as absent, and a list entry that is not a string is left out; the host logs both.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct ManagedPolicyValues {
    pub account_server_url: Option<String>,
    pub allow_other_account_servers: Option<bool>,
    pub personal_sync_provider: Option<Vec<String>>,
    pub usage_data_allowed: Option<bool>,
    pub plugin_catalog_allowed: Option<bool>,
    pub update_checks_allowed: Option<bool>,
    pub icloud_sync_allowed: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ManagedPolicyArg {
    Read { values: ManagedPolicyValues },
    // The host refused its policy source, such as a file a person could write: the core withholds everything a key
    // can.
    Refused,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SyncProviderTag {
    Off,
    Icloud,
    TableproSync,
}

// The providers a device may use for personal data, the one it must use, and whether the person picks at all.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PersonalSyncChoices {
    pub providers: Vec<SyncProviderTag>,
    pub forced: Option<SyncProviderTag>,
    pub locked: bool,
}

// Out of the providers this build and platform offer, the ones the managed values leave a device, by one rule for every
// app.
#[uniffi::export]
pub fn personal_sync_choices(policy: ManagedPolicyArg, offered: Vec<SyncProviderTag>) -> PersonalSyncChoices {
    let offered: Vec<SyncProvider> = offered.into_iter().map(SyncProvider::from).collect();
    PersonalSyncChoices::from(&ManagedPolicy::from(policy).sync_choices(&offered))
}

// The provider a device on `current` uses under the values. `tablepro_sync_available` is false while it is signed in
// to no server that takes its personal data; that never moves it to another provider.
#[uniffi::export]
pub fn settled_sync_provider(
    policy: ManagedPolicyArg,
    offered: Vec<SyncProviderTag>,
    current: SyncProviderTag,
    tablepro_sync_available: bool,
) -> SyncProviderTag {
    let offered: Vec<SyncProvider> = offered.into_iter().map(SyncProvider::from).collect();
    ManagedPolicy::from(policy)
        .sync_choices(&offered)
        .settle(current.into(), tablepro_sync_available)
        .into()
}

impl From<ManagedPolicyArg> for ManagedPolicy {
    fn from(policy: ManagedPolicyArg) -> Self {
        match policy {
            ManagedPolicyArg::Read { values } => Self::Values(PolicyValues {
                account_server_url: values.account_server_url,
                allow_other_account_servers: values.allow_other_account_servers,
                personal_sync_provider: values.personal_sync_provider,
                usage_data_allowed: values.usage_data_allowed,
                plugin_catalog_allowed: values.plugin_catalog_allowed,
                update_checks_allowed: values.update_checks_allowed,
                icloud_sync_allowed: values.icloud_sync_allowed,
            }),
            ManagedPolicyArg::Refused => Self::Refused,
        }
    }
}

impl From<SyncProviderTag> for SyncProvider {
    fn from(provider: SyncProviderTag) -> Self {
        match provider {
            SyncProviderTag::Off => Self::Off,
            SyncProviderTag::Icloud => Self::ICloud,
            SyncProviderTag::TableproSync => Self::TableProSync,
        }
    }
}

impl From<SyncProvider> for SyncProviderTag {
    fn from(provider: SyncProvider) -> Self {
        match provider {
            SyncProvider::Off => Self::Off,
            SyncProvider::ICloud => Self::Icloud,
            SyncProvider::TableProSync => Self::TableproSync,
        }
    }
}

impl From<&SyncChoices> for PersonalSyncChoices {
    fn from(choices: &SyncChoices) -> Self {
        Self {
            providers: choices.providers().iter().copied().map(SyncProviderTag::from).collect(),
            forced: choices.forced().map(SyncProviderTag::from),
            locked: choices.locked(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_profile_that_names_only_icloud_forces_it_on_a_mac_without_tablepro_sync() {
        let policy = ManagedPolicyArg::Read {
            values: ManagedPolicyValues {
                personal_sync_provider: Some(vec!["icloud".to_owned(), "tablepro-sync".to_owned()]),
                ..ManagedPolicyValues::default()
            },
        };

        let choices = personal_sync_choices(policy, vec![SyncProviderTag::Off, SyncProviderTag::Icloud]);

        assert_eq!(choices.providers, [SyncProviderTag::Icloud]);
        assert_eq!(choices.forced, Some(SyncProviderTag::Icloud));
        assert!(choices.locked);
    }

    #[test]
    fn a_mac_on_icloud_leaves_it_when_the_values_take_it_away_and_joins_it_when_they_force_it() {
        let only = |entry: &str| ManagedPolicyArg::Read {
            values: ManagedPolicyValues {
                personal_sync_provider: Some(vec![entry.to_owned()]),
                ..ManagedPolicyValues::default()
            },
        };
        let mac = || vec![SyncProviderTag::Off, SyncProviderTag::Icloud];

        let left = settled_sync_provider(only("off"), mac(), SyncProviderTag::Icloud, false);
        let joined = settled_sync_provider(only("icloud"), mac(), SyncProviderTag::Off, false);

        assert_eq!(left, SyncProviderTag::Off);
        assert_eq!(joined, SyncProviderTag::Icloud);
    }

    #[test]
    fn a_refused_source_leaves_no_provider() {
        let choices = personal_sync_choices(ManagedPolicyArg::Refused, vec![SyncProviderTag::Icloud]);

        assert!(choices.providers.is_empty());
        assert_eq!(choices.forced, None);
        assert!(choices.locked);
    }
}
