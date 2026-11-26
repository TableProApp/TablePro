// The version in force at each place of a pull, as the engine and the team flow keep it together (0056, Rollback, In
// order).

use tablepro_keys::encoding::{TeamId, Version};
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::TeamFlows;
use tablepro_sync::api::scopes::Role;
use tablepro_sync_testing::FakeServer;

use super::device::Device;
use super::harness::new_account;
use super::push_back::{push_envelope, waits};

// The owner rotates twice and writes an envelope under each new version. The member pulls both rotations in one page,
// each run of key objects followed by its envelope: the second run moves the version in force on from the first's,
// so the envelope under the newest version counts at its place.
#[tokio::test]
async fn two_rotations_in_one_page_each_move_the_version_in_force_for_the_envelope_after_it() {
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
    owner.keys.rotate_team(team, Vec::new()).await.unwrap();
    let under_two = push_envelope(&owner, team, "two").await;
    owner.keys.rotate_team(team, Vec::new()).await.unwrap();
    let under_three = push_envelope(&owner, team, "three").await;

    member.pass().await;

    let row = member.scope(ScopeName::Team(team)).await;
    assert_eq!(row.key_version, Version::new(3).ok());
    assert!(!waits(&member, &under_two).await);
    assert!(!waits(&member, &under_three).await);
}
