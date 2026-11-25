// `TeamFacts` over the key tables: the team's `key.member` records, judged by the pin helpers, and the pins. Each
// lookup is kept for the call, and an account's entries go when a newer certificate of it is offered.

use std::collections::{BTreeMap, HashMap};

use async_trait::async_trait;
use tablepro_keys::KeysError;
use tablepro_keys::body::KeyBody;
use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::encoding::{AccountId, Version};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};

use super::facts::{Certificate, PinFacts, TeamFacts};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::state::StateTxn;
use crate::keys::{IkStanding, KeyService, PinChange};

#[derive(Debug, Default)]
pub(crate) struct FactsCache {
    certificates: HashMap<(AccountId, Version), Option<Certificate>>,
    pins: HashMap<AccountId, Option<PinFacts>>,
    chains: Option<BTreeMap<AccountId, Vec<AccountCertificate>>>,
}

impl FactsCache {
    // A certificate the device just took for an account: its judgments and pin are read again, and the chain gains
    // it without reading every other account's again.
    pub(crate) fn learn(&mut self, certificate: &AccountCertificate) {
        let account = certificate.account;
        self.certificates.retain(|(held, _), _| *held != account);
        self.pins.remove(&account);
        if let Some(chains) = &mut self.chains {
            let chain = chains.entry(account).or_default();
            chain.retain(|held| held.av != certificate.av);
            chain.push(certificate.clone());
            chain.sort_by_key(|held| held.av);
        }
    }
}

pub(crate) struct ServiceFacts<'a> {
    pub(crate) service: &'a KeyService,
    pub(crate) txn: &'a mut dyn StateTxn,
    pub(crate) scope: ScopeName,
    pub(crate) cache: &'a mut FactsCache,
}

impl ServiceFacts<'_> {
    // The newest certificate of the account to pin on first use or offer as its newest: one the pins refuse, such as
    // one under an IK seen replaced, is passed over so it cannot block a confirmation for good.
    pub(crate) async fn chain_newest(&mut self, account: AccountId) -> Result<Option<AccountCertificate>, SyncError> {
        let chain = self.chain(account).await?;
        if TeamFacts::pin(self, account).await?.is_none() {
            return Ok(chain.last().cloned());
        }
        for certificate in chain.into_iter().rev() {
            if matches!(
                self.certificate(account, certificate.av).await?,
                Some(Certificate::Usable(_) | Certificate::Alerted(_))
            ) {
                return Ok(Some(certificate));
            }
        }
        Ok(None)
    }

    // Offers a certificate as its account's newest, which pins it on first use or moves the pin (0056, Pins).
    pub(crate) async fn offer(&mut self, certificate: &AccountCertificate) -> Result<PinChange, SyncError> {
        let change = self
            .service
            .offer_certificate(&mut *self.txn, self.scope, certificate)
            .await?;
        self.cache.learn(certificate);
        Ok(change)
    }

    async fn member(&mut self, account: AccountId, av: Version) -> Result<Option<AccountCertificate>, SyncError> {
        let id = KeyRecordId::Member { account, av }.to_wire();
        let held = self
            .service
            .held_object(&mut *self.txn, self.scope, KeyKind::Member, &id)
            .await?;
        Ok(held.and_then(|held| match held.object.body {
            KeyBody::Member(body) => Some(body.certificate(account, av)),
            _ => None,
        }))
    }

    async fn judge(&mut self, certificate: AccountCertificate) -> Result<Certificate, SyncError> {
        match self
            .service
            .verify_certificate(&mut *self.txn, self.scope, &certificate)
            .await
        {
            Ok(IkStanding::Replaced) => Ok(Certificate::Retired(certificate)),
            Ok(IkStanding::Pinned | IkStanding::Endorsed) => Ok(Certificate::Usable(certificate)),
            Err(SyncError::Keys(KeysError::Unendorsed)) => Ok(Certificate::Alerted(certificate)),
            Err(SyncError::Keys(error)) => Ok(Certificate::Invalid(error)),
            Err(other) => Err(other),
        }
    }
}

#[async_trait]
impl TeamFacts for ServiceFacts<'_> {
    async fn certificate(&mut self, account: AccountId, av: Version) -> Result<Option<Certificate>, SyncError> {
        if let Some(known) = self.cache.certificates.get(&(account, av)) {
            return Ok(known.clone());
        }
        // A certificate is judged against its account's pin, which the first certificate of the account offered here
        // makes; one of an account the device never pinned waits like a missing one.
        let judged = match self.member(account, av).await? {
            Some(certificate) if TeamFacts::pin(self, account).await?.is_some() => Some(self.judge(certificate).await?),
            _ => None,
        };
        self.cache.certificates.insert((account, av), judged.clone());
        Ok(judged)
    }

    async fn pin(&mut self, account: AccountId) -> Result<Option<PinFacts>, SyncError> {
        if let Some(known) = self.cache.pins.get(&account) {
            return Ok(*known);
        }
        let pin = self.service.pin(&mut *self.txn, account).await?.map(|row| PinFacts {
            ik: row.ik,
            av: row.av,
            alert: row.alert,
        });
        self.cache.pins.insert(account, pin);
        Ok(pin)
    }

    async fn chain(&mut self, account: AccountId) -> Result<Vec<AccountCertificate>, SyncError> {
        if self.cache.chains.is_none() {
            let held = self
                .service
                .held_objects(&mut *self.txn, self.scope, KeyKind::Member)
                .await?;
            let mut chains: BTreeMap<AccountId, Vec<AccountCertificate>> = BTreeMap::new();
            for held in held {
                if let (KeyRecordId::Member { account, av }, KeyBody::Member(body)) = (held.object.id, held.object.body)
                {
                    let certificate = body.certificate(account, av);
                    if certificate.verify(self.service.origin()).is_ok() {
                        chains.entry(account).or_default().push(certificate);
                    }
                }
            }
            for certificates in chains.values_mut() {
                certificates.sort_by_key(|certificate| certificate.av);
            }
            self.cache.chains = Some(chains);
        }
        Ok(self
            .cache
            .chains
            .as_ref()
            .and_then(|chains| chains.get(&account).cloned())
            .unwrap_or_default())
    }
}
