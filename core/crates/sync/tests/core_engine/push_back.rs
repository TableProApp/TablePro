// After a restore the engine pushes back what the device's own account signed before anything else goes up, judged by
// the bases its pulls and pushes kept (0051, After a restore; 0054, A pass).

use tablepro_keys::encoding::{KeyPurpose, TeamId, Version};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{KeyState, TeamFlows};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::{KeyVersionRow, KeyVersionState, Row, RowKey, StoppedCause};
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::service::ScopeOwner;

use super::device::Device;
use super::harness::new_account;

fn v(value: u32) -> Version {
    Version::new(value).unwrap()
}

#[tokio::test]
async fn a_rotation_the_restore_lost_goes_back_on_the_next_pass_and_the_device_takes_the_new_epoch() {
    let server = FakeServer::new();
    let account = new_account();
    let mac = Device::new(&server, account, "dev_mac").await;
    let recovery = mac.genesis().await;
    mac.pass().await;
    let backup = server.backup();
    mac.replace(recovery).await;
    mac.pass().await;
    let certificate = KeyRecordId::Account { account, av: v(2) }.to_wire();
    let lost = server.stored(ScopeOwner::Personal(account), "key.account", &certificate);

    let epoch = server.restore(&backup);
    let gone = server.stored(ScopeOwner::Personal(account), "key.account", &certificate);
    mac.pass().await;

    assert!(lost.is_some());
    assert!(gone.is_none());
    let back = server.stored(ScopeOwner::Personal(account), "key.account", &certificate);
    assert!(back.is_some_and(|record| record.deleted.is_none()));
    let row = mac.scope(ScopeName::Personal).await;
    assert_eq!((row.epoch, row.refill), (Some(epoch), false));
    assert!(matches!(mac.key_state().await, KeyState::Approved { av, .. } if av == v(2)));
    let Some(Row::KeyVersion(personal)) = mac
        .state
        .begin()
        .await
        .unwrap()
        .get(&RowKey::KeyVersion(ScopeName::Personal, KeyPurpose::Personal))
        .await
        .unwrap()
    else {
        panic!("no personal key row");
    };
    assert_eq!(personal.state, KeyVersionState::Ok);
}

async fn team_row(device: &Device, team: TeamId) -> KeyVersionRow {
    let row = device
        .state
        .begin()
        .await
        .unwrap()
        .get(&RowKey::KeyVersion(ScopeName::Team(team), KeyPurpose::Team))
        .await
        .unwrap();
    row.and_then(|row| match row {
        Row::KeyVersion(row) => Some(row),
        _ => None,
    })
    .unwrap()
}

// The member waits for the owner's version as `restore_wait` and resumes on its own pass once the owner's device put it
// back, with no person involved (0062).
#[tokio::test]
async fn a_member_waits_for_the_owner_s_lost_version_and_resumes_once_the_owner_pushed_it_back() {
    let server = FakeServer::new();
    let (owner_id, member_id) = (new_account(), new_account());
    let team = TeamId(tablepro_keys::encoding::random_uuid().unwrap());
    server.add_team(team, &[(owner_id, Role::Owner), (member_id, Role::Member)]);
    let owner = Device::new(&server, owner_id, "dev_owner").await;
    owner.genesis().await;
    owner.pass().await;
    owner.keys.create_team_keys(team).await.unwrap();
    let member = Device::new(&server, member_id, "dev_member").await;
    member.genesis().await;
    member.pass().await;
    owner.pass().await;
    owner.keys.confirm_member(team, member_id).await.unwrap();
    member.pass().await;
    let backup = server.backup();
    owner.keys.rotate_team(team, Vec::new()).await.unwrap();
    member.pass().await;
    let before = team_row(&member, team).await;

    server.restore(&backup);
    member.pass().await;
    let waiting = team_row(&member, team).await;
    owner.pass().await;
    member.pass().await;

    assert_eq!((before.version, before.state), (v(2), KeyVersionState::Ok));
    assert_eq!(
        (waiting.state, waiting.stopped_cause),
        (KeyVersionState::Stopped, Some(StoppedCause::RestoreWait))
    );
    let resumed = team_row(&member, team).await;
    assert_eq!(
        (resumed.version, resumed.state, resumed.stopped_cause),
        (v(2), KeyVersionState::Ok, None)
    );
    let version = KeyRecordId::Version(tablepro_keys::scope_key::KeyRef {
        owner: team.0,
        purpose: KeyPurpose::Team,
        version: v(2),
    })
    .to_wire();
    assert!(server.stored(ScopeOwner::Team(team), "key.version", &version).is_some());
}
