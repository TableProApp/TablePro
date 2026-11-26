// Key object bodies exactly as 0051 lists them. A value the record id carries is never repeated here (0052). The
// lengths are 0056's; `tablepro-keys` parses and verifies the bytes.

use super::Class::Inert;
use super::Role::Content;
use super::{Field, Type};

const fn field(key: &'static str, ty: Type) -> Field {
    Field {
        key,
        ty,
        class: Inert,
        role: Content,
    }
}

const SUITE: Field = field("suite", Type::Text);
const KEY: Type = Type::Bytes(Some(32));
const SIGNATURE: Type = Type::Bytes(Some(64));
const NONCE: Type = Type::Bytes(Some(12));
const SAS_CANCEL_REASONS: &[&str] = &["user", "mismatch", "commitment"];

pub const ACCOUNT: &[Field] = &[
    SUITE,
    field("kind", Type::Integer),
    field("ik", KEY),
    field("ask", KEY),
    field("aek", KEY),
    field("sig", SIGNATURE),
    field("replace_sig", SIGNATURE),
];

pub const DEVICE: &[Field] = &[SUITE, field("dek", KEY), field("dsk", KEY), field("sig", SIGNATURE)];

pub const RECOVERY: &[Field] = &[SUITE, field("nonce", NONCE), field("ct", Type::Bytes(Some(80)))];

pub const RESET: &[Field] = &[
    SUITE,
    field("av", Type::Integer),
    field("key_device", Type::Text),
    field("account", Type::Object(ACCOUNT)),
    field("device", Type::Object(DEVICE)),
    field("recovery", Type::Object(RECOVERY)),
];

pub const CANCEL: &[Field] = &[SUITE, field("sig", SIGNATURE)];

pub const REQUEST: &[Field] = &[
    SUITE,
    field("key_device", Type::Text),
    field("dek", KEY),
    field("dsk", KEY),
    field("commit", KEY),
];

// The three steps share one kind: `nonce` holds the approver's keys and `r`, `reveal` holds `r`, `cancel` a reason.
pub const SAS: &[Field] = &[
    SUITE,
    field("key_device", Type::Text),
    field("dek", KEY),
    field("dsk", KEY),
    field("r", KEY),
    field("reason", Type::Enum(SAS_CANCEL_REASONS)),
];

pub const VERSION: &[Field] = &[
    SUITE,
    field("start", Type::Integer),
    field("kid", KEY),
    field("signer", Type::Text),
    field("signer_av", Type::Integer),
    field("sig", SIGNATURE),
];

pub const WRAP: &[Field] = &[
    SUITE,
    field("enc", KEY),
    field("ct", Type::Bytes(None)),
    field("wrapper", Type::Text),
    field("wrapper_av", Type::Integer),
    field("wrapper_device", Type::Text),
    field("sig", SIGNATURE),
];

pub const RING: &[Field] = &[SUITE, field("nonce", NONCE), field("ct", Type::Bytes(Some(52)))];
