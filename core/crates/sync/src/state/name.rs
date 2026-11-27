use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::api::ids::StateName;
use crate::api::state::StateIdentity;

const SERVICE_LABEL: &str = "tablepro/v1/state-file/service";
const ICLOUD_LABEL: &str = "tablepro/v1/state-file/icloud";

fn framed(hasher: &mut Sha256, part: &str) {
    let length = u32::try_from(part.len()).unwrap_or(u32::MAX);
    hasher.update(length.to_be_bytes());
    hasher.update(part.as_bytes());
}

// 0054, One per provider and account: a hex SHA-256 over a fixed label, the sign-in key and the account id, or another
// label and the iCloud user record name. Only hex digits reach a path, so a name a server chose cannot name another file.
pub fn state_name(identity: &StateIdentity) -> StateName {
    let mut hasher = Sha256::new();
    match identity {
        StateIdentity::Service { sign_in, account, .. } => {
            framed(&mut hasher, SERVICE_LABEL);
            framed(&mut hasher, sign_in);
            framed(&mut hasher, &account.to_wire());
        }
        StateIdentity::ICloud { user_record_name } => {
            framed(&mut hasher, ICLOUD_LABEL);
            framed(&mut hasher, user_record_name);
        }
    }
    StateName(hex::encode(hasher.finalize()))
}

// `<root>/service/<name>.db` or `<root>/icloud/<name>.db`, `<root>` being `<state>/sync`.
pub fn state_path(root: &Path, identity: &StateIdentity) -> PathBuf {
    let folder = match identity {
        StateIdentity::Service { .. } => "service",
        StateIdentity::ICloud { .. } => "icloud",
    };
    root.join(folder).join(format!("{}.db", state_name(identity).0))
}
