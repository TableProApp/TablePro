mod header;
pub(crate) mod message;
mod util;

pub(crate) use self::{
    message::{Message, MessageFlags},
    util::next_request_id,
};
