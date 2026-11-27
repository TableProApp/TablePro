use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_keys::encoding::{KeyDeviceId, Version};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::ids::DeviceRowId;
use tablepro_sync::api::key_flows::{
    AccountDevice, DeviceFlows, DraftId, KeyNoticeKind, MemberKeyStatus, RemovalReview, ReviewedDevice, ReviewedMember,
};
use tablepro_sync::api::transport::{StepUpChallenge, TransportError};
use uuid::Uuid;

use super::{FakeKeyFlows, account::notice, keep_compared, require_approved, rotate, same_recovery_key};

#[async_trait]
impl DeviceFlows for FakeKeyFlows {
    async fn account_devices(&self) -> Result<Vec<AccountDevice>, SyncError> {
        Ok(self.lock().devices.clone())
    }

    async fn remove_device_row(&self, device: DeviceRowId) -> Result<(), SyncError> {
        let mut model = self.lock();
        require_approved(&model, "remove a device")?;
        if !model.step_up_fresh {
            return Err(SyncError::Transport(TransportError::StepUpRequired(StepUpChallenge {
                acr_values: vec!["urn:tablepro:acr:passkey".to_owned()],
                max_age_secs: 300,
            })));
        }
        for held in &mut model.devices {
            if held.device.as_ref() == Some(&device) {
                held.device = None;
            }
        }
        notice(&mut model, KeyNoticeKind::DeviceRemoved { device });
        Ok(())
    }

    async fn begin_removal(
        &self,
        recovery_key: SecretString,
        lost: Vec<KeyDeviceId>,
    ) -> Result<RemovalReview, SyncError> {
        let mut model = self.lock();
        require_approved(&model, "remove a device")?;
        same_recovery_key(model.recovery.as_ref(), &recovery_key)?;
        let devices = model
            .devices
            .iter()
            .map(|device| ReviewedDevice {
                keep_by_default: device.compared && !lost.contains(&device.key_device),
                device: device.clone(),
            })
            .collect();
        let review = DraftId(Uuid::new_v4());
        model.reviews.insert(review, lost);
        Ok(RemovalReview {
            review,
            devices,
            members: model.confirmed_under.clone(),
        })
    }

    async fn finish_removal(
        &self,
        review: DraftId,
        keep: Vec<KeyDeviceId>,
        remove: Vec<ReviewedMember>,
    ) -> Result<(), SyncError> {
        let mut model = self.lock();
        model
            .reviews
            .remove(&review)
            .ok_or(SyncError::Unknown { what: "review" })?;
        keep_compared(&mut model, &keep)?;
        rotate(&mut model);
        for member in remove {
            if let Some(team) = model.teams.get_mut(&member.team)
                && let Some((_, status)) = team.members.get_mut(&member.account)
            {
                *status = MemberKeyStatus::AwaitingConfirmation;
            }
        }
        for team in model.teams.values_mut().filter(|team| team.holder) {
            team.version = Version::new(team.version.map_or(1, |version| version.get() + 1)).ok();
            team.rotation_due = false;
        }
        model.confirmed_under.clear();
        self.approve(&mut model)
    }

    async fn recover(&self, recovery_key: SecretString) -> Result<(), SyncError> {
        let mut model = self.lock();
        same_recovery_key(model.recovery.as_ref(), &recovery_key)?;
        rotate(&mut model);
        model.devices.retain(|device| device.this_device);
        self.approve(&mut model)
    }

    async fn resume_rotation(&self, av: Version) -> Result<(), SyncError> {
        let _ = av;
        Ok(())
    }
}
