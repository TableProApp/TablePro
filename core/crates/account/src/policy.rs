use std::collections::BTreeSet;

use crate::server::{PRODUCTION_ORIGIN, loopback_http_allowed, parse_origin};

// A provider for personal data, as `PersonalSyncProvider` spells it (core ADR 0055).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SyncProvider {
    Off,
    ICloud,
    TableProSync,
}

impl SyncProvider {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "off" => Some(Self::Off),
            "icloud" => Some(Self::ICloud),
            "tablepro-sync" => Some(Self::TableProSync),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::ICloud => "icloud",
            Self::TableProSync => "tablepro-sync",
        }
    }
}

// The values the OS marks as managed, as the host read them. A value of another type reaches here as absent, and a
// list entry that is not a string is the host's to skip.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PolicyValues {
    pub account_server_url: Option<String>,
    pub allow_other_account_servers: Option<bool>,
    pub personal_sync_provider: Option<Vec<String>>,
    pub usage_data_allowed: Option<bool>,
    pub plugin_catalog_allowed: Option<bool>,
    pub update_checks_allowed: Option<bool>,
    pub icloud_sync_allowed: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManagedPolicy {
    Values(PolicyValues),
    // The host refused its policy source, such as a file a person could write. Dropping the source must not drop the
    // organization's policy, so everything a key can withhold is withheld.
    Refused,
}

impl Default for ManagedPolicy {
    fn default() -> Self {
        Self::Values(PolicyValues::default())
    }
}

impl ManagedPolicy {
    pub fn values(&self) -> Option<&PolicyValues> {
        match self {
            Self::Values(values) => Some(values),
            Self::Refused => None,
        }
    }

    // The account may call this API origin. While the values hold the account to a company server, no other.
    pub fn allows_server(&self, origin: &str) -> bool {
        match self {
            Self::Refused => false,
            Self::Values(_) => self.held_to().is_none_or(|held| held == origin),
        }
    }

    // False in the case 0047 refuses `choose_server` in, when the server is not tablepro.app's: share-link reads and
    // the AI model catalog refresh then make no request.
    pub fn allows_tablepro_requests(&self) -> bool {
        match self {
            Self::Refused => false,
            Self::Values(_) => self.held_to().is_none_or(|held| held == PRODUCTION_ORIGIN),
        }
    }

    pub fn usage_data_allowed(&self) -> bool {
        self.allowed(|values| values.usage_data_allowed)
    }

    pub fn plugin_catalog_allowed(&self) -> bool {
        self.allowed(|values| values.plugin_catalog_allowed)
    }

    pub fn update_checks_allowed(&self) -> bool {
        self.allowed(|values| values.update_checks_allowed)
    }

    pub fn icloud_sync_allowed(&self) -> bool {
        self.allowed(|values| values.icloud_sync_allowed)
    }

    // Out of the providers this build and platform offer, the ones a device may use. The list is a set.
    pub fn sync_choices(&self, offered: &[SyncProvider]) -> SyncChoices {
        let Self::Values(values) = self else {
            return SyncChoices::default();
        };
        let mut providers: BTreeSet<SyncProvider> = offered.iter().copied().collect();
        if let Some(listed) = &values.personal_sync_provider {
            let named: BTreeSet<SyncProvider> = listed
                .iter()
                .filter_map(|entry| {
                    let provider = SyncProvider::from_name(entry);
                    if provider.is_none() {
                        tracing::warn!(
                            code = crate::account_error::POLICY_IGNORED,
                            %entry,
                            "PersonalSyncProvider names no provider, so the entry is skipped"
                        );
                    }
                    provider
                })
                .collect();
            providers.retain(|provider| named.contains(provider));
        }
        if values.icloud_sync_allowed == Some(false) {
            providers.remove(&SyncProvider::ICloud);
        }
        SyncChoices {
            providers: providers.into_iter().collect(),
        }
    }

    // A boolean that is true or absent leaves the person's own setting.
    fn allowed(&self, key: impl Fn(&PolicyValues) -> Option<bool>) -> bool {
        match self {
            Self::Refused => false,
            Self::Values(values) => key(values) != Some(false),
        }
    }

    // AccountServerURL as an origin, while AllowOtherAccountServers is false. A value that is not a server holds the
    // account to nothing, as `server::resolve` ignores it.
    fn held_to(&self) -> Option<String> {
        let values = self.values()?;
        if values.allow_other_account_servers != Some(false) {
            return None;
        }
        let text = values
            .account_server_url
            .as_deref()
            .filter(|text| !text.trim().is_empty())?;
        parse_origin(text, loopback_http_allowed()).ok()
    }
}

// The personal sync providers a device may use, in a fixed order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncChoices {
    providers: Vec<SyncProvider>,
}

impl SyncChoices {
    pub fn providers(&self) -> &[SyncProvider] {
        &self.providers
    }

    pub fn contains(&self, provider: SyncProvider) -> bool {
        self.providers.contains(&provider)
    }

    // One choice left is the device's provider.
    pub fn forced(&self) -> Option<SyncProvider> {
        match self.providers.as_slice() {
            [only] => Some(*only),
            _ => None,
        }
    }

    // With one choice or none, the person picks nothing.
    pub fn locked(&self) -> bool {
        self.providers.len() <= 1
    }

    // The provider a device on `current` uses now. `tablepro_sync_available` is false while the device is signed in to
    // no server that takes its personal data, such as one whose `personalSync` switch is off. That takes only TablePro
    // Sync away: a device on it goes off and never moves to another provider on the server's word. A forced TablePro
    // Sync still asks before its first upload, which is the engine's to do.
    pub fn settle(&self, current: SyncProvider, tablepro_sync_available: bool) -> SyncProvider {
        let next = match self.forced() {
            Some(forced) => forced,
            None if self.contains(current) => current,
            None => SyncProvider::Off,
        };
        match next {
            SyncProvider::TableProSync if !tablepro_sync_available => SyncProvider::Off,
            next => next,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use SyncProvider::{ICloud, Off, TableProSync};

    const MAC: [SyncProvider; 3] = [Off, ICloud, TableProSync];

    fn listing(entries: &[&str]) -> ManagedPolicy {
        ManagedPolicy::Values(PolicyValues {
            personal_sync_provider: Some(entries.iter().map(|entry| (*entry).to_owned()).collect()),
            ..PolicyValues::default()
        })
    }

    fn held(url: &str, allow_others: Option<bool>) -> ManagedPolicy {
        ManagedPolicy::Values(PolicyValues {
            account_server_url: Some(url.to_owned()),
            allow_other_account_servers: allow_others,
            ..PolicyValues::default()
        })
    }

    #[test]
    fn an_absent_key_leaves_every_offered_provider() {
        let choices = ManagedPolicy::default().sync_choices(&MAC);

        assert_eq!(choices.providers(), MAC);
        assert!(!choices.locked());
        assert_eq!(choices.forced(), None);
    }

    #[test]
    fn one_entry_forces_its_provider_and_locks_the_picker() {
        let choices = listing(&["icloud"]).sync_choices(&MAC);

        assert_eq!(choices.forced(), Some(ICloud));
        assert!(choices.locked());
        assert_eq!(choices.settle(Off, false), ICloud);
        assert_eq!(choices.settle(TableProSync, true), ICloud);
    }

    #[test]
    fn several_entries_allow_those_and_a_device_on_one_keeps_it() {
        let choices = listing(&["tablepro-sync", "off", "off"]).sync_choices(&MAC);

        assert_eq!(choices.providers(), [Off, TableProSync]);
        assert!(!choices.locked());
        assert_eq!(choices.settle(TableProSync, true), TableProSync);
        assert_eq!(choices.settle(Off, true), Off);
    }

    #[test]
    fn a_provider_no_longer_allowed_leaves_the_device_off_until_the_person_picks() {
        let choices = listing(&["icloud", "tablepro-sync"]).sync_choices(&MAC);

        assert_eq!(choices.settle(Off, true), Off);
        assert!(!choices.contains(Off));
    }

    #[test]
    fn unknown_entries_are_skipped_and_spelling_is_exact() {
        let choices = listing(&["iCloud", "dropbox", "off"]).sync_choices(&MAC);

        assert_eq!(choices.providers(), [Off]);
        assert_eq!(choices.forced(), Some(Off));
    }

    #[test]
    fn an_empty_list_or_one_with_nothing_this_build_offers_leaves_sync_off_and_locked() {
        let empty = listing(&[]).sync_choices(&MAC);
        let elsewhere = listing(&["tablepro-sync"]).sync_choices(&[Off, ICloud]);

        for choices in [empty, elsewhere] {
            assert!(choices.providers().is_empty());
            assert!(choices.locked());
            assert_eq!(choices.settle(ICloud, true), Off);
        }
    }

    #[test]
    fn icloud_sync_allowed_false_takes_icloud_out_of_any_list() {
        let mut values = PolicyValues {
            icloud_sync_allowed: Some(false),
            ..PolicyValues::default()
        };
        let absent = ManagedPolicy::Values(values.clone()).sync_choices(&MAC);
        values.personal_sync_provider = Some(vec!["icloud".to_owned()]);
        let forced = ManagedPolicy::Values(values).sync_choices(&MAC);

        assert_eq!(absent.providers(), [Off, TableProSync]);
        assert!(forced.providers().is_empty());
        assert_eq!(forced.settle(ICloud, false), Off);
    }

    // A company server's personalSync switch takes only its own provider away: it never starts iCloud.
    #[test]
    fn a_server_without_personal_sync_never_moves_a_device_to_icloud() {
        let both = listing(&["icloud", "tablepro-sync"]).sync_choices(&MAC);
        let forced = listing(&["tablepro-sync"]).sync_choices(&MAC);
        let open = ManagedPolicy::default().sync_choices(&MAC);

        assert_eq!(both.settle(TableProSync, false), Off);
        assert_eq!(forced.settle(TableProSync, false), Off);
        assert_eq!(forced.settle(Off, false), Off);
        assert_eq!(open.settle(TableProSync, false), Off);
        assert_eq!(both.providers(), [ICloud, TableProSync]);
    }

    #[test]
    fn a_refused_source_withholds_everything_a_key_can() {
        let refused = ManagedPolicy::Refused;

        assert!(refused.sync_choices(&MAC).providers().is_empty());
        assert!(!refused.allows_server(PRODUCTION_ORIGIN));
        assert!(!refused.allows_tablepro_requests());
        assert!(!refused.usage_data_allowed());
        assert!(!refused.plugin_catalog_allowed());
        assert!(!refused.update_checks_allowed());
        assert!(!refused.icloud_sync_allowed());
    }

    #[test]
    fn a_boolean_that_is_true_or_absent_leaves_the_person_s_setting() {
        let off = ManagedPolicy::Values(PolicyValues {
            usage_data_allowed: Some(false),
            plugin_catalog_allowed: Some(true),
            ..PolicyValues::default()
        });

        assert!(!off.usage_data_allowed());
        assert!(off.plugin_catalog_allowed());
        assert!(off.update_checks_allowed());
        assert!(off.icloud_sync_allowed());
    }

    #[test]
    fn a_company_server_others_may_not_leave_stops_tablepro_requests() {
        let held = held("https://tablepro.corp.example/", Some(false));

        assert!(!held.allows_tablepro_requests());
        assert!(held.allows_server("https://tablepro.corp.example"));
        assert!(!held.allows_server(PRODUCTION_ORIGIN));
    }

    #[test]
    fn tablepro_requests_stop_only_with_the_pair_naming_another_server() {
        let alone = ManagedPolicy::Values(PolicyValues {
            allow_other_account_servers: Some(false),
            ..PolicyValues::default()
        });
        let default_only = held("https://tablepro.corp.example", None);
        let production = held("https://api.tablepro.app", Some(false));
        let not_a_server = held("ftp://tablepro.corp.example", Some(false));

        for policy in [alone, default_only, production, not_a_server] {
            assert!(policy.allows_tablepro_requests(), "{policy:?}");
            assert!(policy.allows_server(PRODUCTION_ORIGIN), "{policy:?}");
        }
    }
}
