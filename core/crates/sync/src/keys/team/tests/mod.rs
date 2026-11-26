// The team rules against signed objects: the flows vectors `tablepro-keys` ships, and objects these tests sign for the
// cases the vectors leave to the flows. Certificates and pins come from `TestFacts`, standing in for the pin helpers.

mod rules;
mod vectors;

use std::collections::{BTreeMap, HashMap};

use async_trait::async_trait;
use tablepro_keys::body::KeyObject;
use tablepro_keys::cert::{AccountCertificate, CertKind};
use tablepro_keys::encoding::{AccountId, KeyDeviceId, Origin, TeamId, Version};
use tablepro_keys::keys::{AccountKeys, Ed25519Seed, ScopeKey, X25519Secret};
use tablepro_keys::scope_key::Start;
use uuid::Uuid;

use super::book::TeamBook;
use super::build::{self, NewVersion, Signer};
use super::facts::{Certificate, PinFacts, TeamFacts};
use super::secrets::Keyring;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::state::{Holder, KeyVersionRow, KeyVersionState, StoppedCause};

pub(super) fn origin() -> Origin {
    Origin::parse("https://sync.example.com").unwrap()
}

pub(super) fn v(value: u32) -> Version {
    Version::new(value).unwrap()
}

// One account: its IK and its account keys at each `av`, every certificate a rotation under that IK, unless a test
// swaps one for a replace or a reset.
#[derive(Clone)]
pub(super) struct Account {
    pub(super) id: AccountId,
    pub(super) ik: Ed25519Seed,
    pub(super) keys: BTreeMap<u32, AccountKeys>,
    pub(super) certificates: BTreeMap<u32, AccountCertificate>,
}

impl Account {
    pub(super) fn generated(id: u128, avs: u32) -> Self {
        let mut account = Self {
            id: AccountId(Uuid::from_u128(id)),
            ik: Ed25519Seed::generate().unwrap(),
            keys: BTreeMap::new(),
            certificates: BTreeMap::new(),
        };
        for av in 1..=avs {
            account.keys.insert(av, AccountKeys::generate().unwrap());
            account.sign_rotation(av);
        }
        account
    }

    pub(super) fn sign_rotation(&mut self, av: u32) {
        let certificate = AccountCertificate::sign(
            &origin(),
            self.id,
            v(av),
            CertKind::GenesisOrRotation,
            &self.ik,
            self.keys[&av].public().unwrap(),
            None,
        )
        .unwrap();
        self.certificates.insert(av, certificate);
    }

    // A new `av` under a new IK: endorsed by the current IK for a replace, unendorsed for a reset.
    pub(super) fn change_ik(&mut self, av: u32, endorsed: bool) -> Ed25519Seed {
        let old = self.ik.clone();
        self.ik = Ed25519Seed::generate().unwrap();
        self.keys.insert(av, AccountKeys::generate().unwrap());
        let (kind, previous) = if endorsed {
            (CertKind::Replace, Some(&old))
        } else {
            (CertKind::ResetKeepingKeys, None)
        };
        let certificate = AccountCertificate::sign(
            &origin(),
            self.id,
            v(av),
            kind,
            &self.ik,
            self.keys[&av].public().unwrap(),
            previous,
        )
        .unwrap();
        self.certificates.insert(av, certificate);
        old
    }

    pub(super) fn holder(&self, av: u32) -> Holder {
        let certificate = &self.certificates[&av];
        Holder {
            account: self.id,
            ik: certificate.ik,
        }
    }

    pub(super) fn signer(&self, av: u32) -> Signer<'_> {
        Signer {
            account: self.id,
            av: v(av),
            keys: &self.keys[&av],
            key_device: KeyDeviceId(Uuid::from_u128(u128::from(av))),
        }
    }
}

// The certificates the team holds and the pins, as the pin helpers would judge them.
#[derive(Default)]
pub(super) struct TestFacts {
    pub(super) certificates: HashMap<(AccountId, Version), Certificate>,
    pub(super) pins: HashMap<AccountId, PinFacts>,
}

impl TestFacts {
    // The account's certificates up to `av` held and usable, and its pin at `av`.
    pub(super) fn know(&mut self, account: &Account, av: u32) {
        for (held, certificate) in account.certificates.range(..=av) {
            self.certificates
                .insert((account.id, v(*held)), Certificate::Usable(certificate.clone()));
        }
        self.pins.insert(
            account.id,
            PinFacts {
                ik: account.certificates[&av].ik,
                av: v(av),
                alert: false,
            },
        );
    }

    pub(super) fn alert(&mut self, account: &Account, av: u32) {
        self.certificates.insert(
            (account.id, v(av)),
            Certificate::Alerted(account.certificates[&av].clone()),
        );
        if let Some(pin) = self.pins.get_mut(&account.id) {
            pin.alert = true;
        }
    }
}

#[async_trait]
impl TeamFacts for TestFacts {
    async fn certificate(&mut self, account: AccountId, av: Version) -> Result<Option<Certificate>, SyncError> {
        Ok(self.certificates.get(&(account, av)).cloned())
    }

    async fn pin(&mut self, account: AccountId) -> Result<Option<PinFacts>, SyncError> {
        Ok(self.pins.get(&account).copied())
    }

    async fn chain(&mut self, account: AccountId) -> Result<Vec<AccountCertificate>, SyncError> {
        let mut chain: Vec<AccountCertificate> = self
            .certificates
            .iter()
            .filter(|((held, _), _)| *held == account)
            .filter_map(|(_, certificate)| match certificate {
                Certificate::Usable(certificate)
                | Certificate::Retired(certificate)
                | Certificate::Alerted(certificate) => Some(certificate.clone()),
                Certificate::Invalid(_) => None,
            })
            .collect();
        chain.sort_by_key(|certificate| certificate.av);
        Ok(chain)
    }
}

pub(super) struct TestKeyring {
    pub(super) account: Account,
}

#[async_trait]
impl Keyring for TestKeyring {
    fn origin(&self) -> &Origin {
        static ORIGIN: std::sync::OnceLock<Origin> = std::sync::OnceLock::new();
        ORIGIN.get_or_init(origin)
    }

    fn account(&self) -> AccountId {
        self.account.id
    }

    async fn account_keys(&self, av: Version) -> Result<Option<AccountKeys>, SyncError> {
        Ok(self.account.keys.get(&av.get()).cloned())
    }
}

pub(super) fn team() -> TeamId {
    TeamId(Uuid::from_u128(0x019a_6b30_1d27_7e9a_8c44_2f5b_7a1e_0c63))
}

pub(super) fn row(version: u32, holders: &[Holder], state: KeyVersionState) -> KeyVersionRow {
    let mut holders = holders.to_vec();
    holders.sort();
    holders.dedup();
    KeyVersionRow {
        scope: ScopeName::Team(team()),
        purpose: tablepro_keys::encoding::KeyPurpose::Team,
        version: v(version),
        record: [0; 32],
        holders,
        state,
        stopped_cause: (state == KeyVersionState::Stopped).then_some(StoppedCause::CatchUp),
        epoch: None,
    }
}

pub(super) fn book(me: &Account, row: Option<KeyVersionRow>) -> TeamBook {
    TeamBook::new(origin(), team(), me.id, row)
}

pub(super) fn insert_all(book: &mut TeamBook, objects: &[KeyObject]) {
    for object in objects {
        book.insert(object, true).unwrap();
    }
}

// A version signed by `signer` at `av`, its ring when `below` is given, and wraps to each recipient at its `av`.
pub(super) fn version(
    number: u32,
    start: Start,
    key: &ScopeKey,
    below: Option<&ScopeKey>,
    signer: (&Account, u32),
    recipients: &[(&Account, u32)],
) -> Vec<KeyObject> {
    let certificates: Vec<AccountCertificate> = recipients
        .iter()
        .map(|(account, av)| account.certificates[av].clone())
        .collect();
    let plan = NewVersion {
        team: team(),
        version: v(number),
        start,
        scope_key: key,
        previous: below,
        recipients: &certificates,
    };
    build::version_objects(&origin(), &plan, &signer.0.signer(signer.1))
        .unwrap()
        .1
}

pub(super) fn wrap(number: u32, key: &ScopeKey, signer: (&Account, u32), recipient: (&Account, u32)) -> KeyObject {
    build::wrap_to(
        &origin(),
        build::team_key(team(), v(number)),
        key,
        &recipient.0.certificates[&recipient.1],
        &signer.0.signer(signer.1),
    )
    .unwrap()
}

pub(super) fn x25519(hex: &str) -> X25519Secret {
    X25519Secret::from_slice(&hex_bytes(hex)).unwrap()
}

pub(super) fn hex_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&hex[at..at + 2], 16).unwrap())
        .collect()
}
