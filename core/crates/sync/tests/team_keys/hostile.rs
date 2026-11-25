// What a hostile server serves a team member, straight to the key layer in order: S3-C1 and S5-M2 of gate G0, with
// the pins and certificates the real account flows keep. Each must fail closed.

use tablepro_keys::body::{KeyBody, KeyObject, VersionBody, WrapBody};
use tablepro_keys::encoding::{AccountId, KeyPurpose, TeamId, Version};
use tablepro_keys::keys::{AccountKeys, ScopeKey};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::scope_key::{KeyRef, Start, VersionRecord};
use tablepro_keys::wrap::{Wrap, Wrapper, scope_key_target};
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{AccountFlows, ArrivalOrder, KeyApplied, KeyArrival, TeamFlows};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::{KeyVersionState, StoppedCause};

use super::flows::{Team, created, team_pass, v};
use super::harness::{Device, new_account, record_of, refused_codes, typed_back};

struct Signer {
    account: AccountId,
    av: Version,
    keys: AccountKeys,
    key_device: tablepro_keys::encoding::KeyDeviceId,
}

async fn signer(device: &Device) -> Signer {
    let mut txn = device.txn().await;
    let own = device.service.own_account(txn.as_mut()).await.unwrap().unwrap();
    Signer {
        account: device.account,
        av: own.av,
        keys: own.keys,
        key_device: own.device.key_device,
    }
}

fn team_key(team: TeamId, version: u32) -> KeyRef {
    KeyRef {
        owner: team.0,
        purpose: KeyPurpose::Team,
        version: v(version),
    }
}

fn version_object(team: TeamId, number: u32, key: &ScopeKey, by: &Signer) -> KeyObject {
    let record = VersionRecord::sign(
        &super::harness::origin(),
        team_key(team, number),
        Start::Next,
        key,
        by.account,
        by.av,
        &by.keys.ask,
    )
    .unwrap();
    KeyObject {
        id: KeyRecordId::Version(record.key),
        body: KeyBody::Version(VersionBody::of(&record)),
    }
}

fn wrap_object(team: TeamId, number: u32, key: &ScopeKey, by: &Signer, to: &Signer) -> KeyObject {
    let target = scope_key_target(team_key(team, number), to.account, to.av);
    let wrap = Wrap::seal_scope_key(
        &super::harness::origin(),
        target,
        &to.keys.public().unwrap().aek,
        key,
        Wrapper {
            account: by.account,
            av: by.av,
            key_device: by.key_device,
        },
        &by.keys.ask,
    )
    .unwrap();
    KeyObject {
        id: KeyRecordId::Wrap(target),
        body: KeyBody::Wrap(WrapBody::of(&wrap)),
    }
}

async fn served(device: &Device, team: TeamId, objects: &[KeyObject]) -> KeyApplied {
    device
        .service
        .apply_team_objects(KeyArrival {
            scope: ScopeName::Team(team),
            records: objects.iter().map(record_of).collect(),
            order: ArrivalOrder::InOrder,
        })
        .await
        .unwrap()
}

// A, an admin, held version 1 and then replaced its recovery key, which its teammate P followed. A removed device
// still holds A's account keys from `av` 1. M is an account the server added, with keys but no confirmation.
struct Stage {
    t: Team,
    p: Device,
    m: Signer,
    a_before: Signer,
}

async fn staged() -> Stage {
    let (a_id, p_id, m_id) = (new_account(), new_account(), new_account());
    let t = created(&[(a_id, Role::Admin), (p_id, Role::Editor), (m_id, Role::Member)]).await;
    let (a, recovery) = t.joined_with_recovery(a_id, "a-row").await;
    let p = t.confirmed(p_id, "p-row").await;
    let m = t.joined(m_id, "m-row").await;
    team_pass(&t.owner, t.team).await;
    t.owner.service.confirm_member(t.team, a_id).await.unwrap();
    let a_before = signer(&a).await;
    a.pull().await;
    let draft = a.service.begin_replace(recovery).await.unwrap();
    a.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap();
    a.service.publish_member_certificate(t.team).await.unwrap();
    team_pass(&p, t.team).await;
    assert_eq!(p.pin(a_id).await.unwrap().av, v(2));
    let m = signer(&m).await;
    Stage { t, p, m, a_before }
}

#[tokio::test]
async fn s3_c1_a_version_under_a_removed_devices_old_key_then_its_recipients_version_stop_the_member_at_one() {
    let s = staged().await;
    let (attacker_two, attacker_three) = (ScopeKey::generate().unwrap(), ScopeKey::generate().unwrap());
    let p_signer = signer(&s.p).await;
    let objects = [
        version_object(s.t.team, 2, &attacker_two, &s.a_before),
        wrap_object(s.t.team, 2, &attacker_two, &s.a_before, &s.m),
        version_object(s.t.team, 3, &attacker_three, &s.m),
        wrap_object(s.t.team, 3, &attacker_three, &s.m, &p_signer),
    ];

    let applied = served(&s.p, s.t.team, &objects).await;

    // A replace stands in for the device removal K7-2 builds; the old key's `av` is below A's newest either way.
    assert_eq!(refused_codes(&applied).first(), Some(&"keys.stale"));
    let keys = s.p.service.team_keys(s.t.team).await.unwrap();
    assert_eq!((keys.version, keys.state), (Some(v(1)), KeyVersionState::Stopped));
    assert_eq!(keys.stopped_cause, Some(StoppedCause::CatchUp));
    assert!(!keys.holder);
}

#[tokio::test]
async fn s5_m2_a_stopped_member_counts_no_wrap_it_first_sees_and_refuses_the_rotation_of_an_account_it_never_counted() {
    let s = staged().await;
    let p_signer = signer(&s.p).await;
    let stale = ScopeKey::generate().unwrap();
    served(&s.p, s.t.team, &[version_object(s.t.team, 2, &stale, &s.a_before)]).await;
    let one = ScopeKey::generate().unwrap();
    let rotation = ScopeKey::generate().unwrap();
    s.t.server.set_role(s.t.team, s.m.account, Some(Role::Admin));
    team_pass(&s.p, s.t.team).await;

    let applied = served(
        &s.p,
        s.t.team,
        &[
            wrap_object(s.t.team, 1, &one, &s.a_before, &s.m),
            version_object(s.t.team, 3, &rotation, &s.m),
            wrap_object(s.t.team, 3, &rotation, &s.m, &p_signer),
        ],
    )
    .await;

    assert!(refused_codes(&applied).contains(&"keys.not_holder"), "{applied:?}");
    let keys = s.p.service.team_keys(s.t.team).await.unwrap();
    assert_eq!((keys.version, keys.state), (Some(v(1)), KeyVersionState::Stopped));
}

// The version in force is the replay position: a stopped member still counts the versions the server served, so an
// envelope a removed device writes under the old key after them is refused, as the honest server would refuse it.
#[tokio::test]
async fn the_version_in_force_follows_what_the_server_served_and_an_envelope_under_an_older_one_is_stale() {
    let s = staged().await;
    let p_signer = signer(&s.p).await;
    let (attacker_two, attacker_three) = (ScopeKey::generate().unwrap(), ScopeKey::generate().unwrap());

    let applied = served(
        &s.p,
        s.t.team,
        &[
            version_object(s.t.team, 2, &attacker_two, &s.a_before),
            version_object(s.t.team, 3, &attacker_three, &s.m),
            wrap_object(s.t.team, 3, &attacker_three, &s.m, &p_signer),
        ],
    )
    .await;

    assert_eq!(applied.in_force, Some(v(3)));
    let keys = s.p.service.team_keys(s.t.team).await.unwrap();
    assert_eq!((keys.version, keys.state), (Some(v(1)), KeyVersionState::Stopped));
    let sealed =
        s.t.owner
            .service
            .seal_team_envelope(
                s.t.team,
                tablepro_keys::envelope::EnvelopeId::new(
                    tablepro_keys::envelope::ParentKind::LibraryConnection,
                    "warehouse",
                    tablepro_keys::envelope::SecretKind::Password,
                )
                .unwrap(),
                secrecy::SecretString::from("old"),
                serde_json::json!({}),
            )
            .await
            .unwrap();
    let opened =
        s.p.service
            .open_team_envelope(
                s.t.team,
                tablepro_keys::envelope::EnvelopeId::new(
                    tablepro_keys::envelope::ParentKind::LibraryConnection,
                    "warehouse",
                    tablepro_keys::envelope::SecretKind::Password,
                )
                .unwrap(),
                sealed,
                applied.in_force,
            )
            .await;
    assert_eq!(opened.unwrap_err().code(), "keys.stale");
}
