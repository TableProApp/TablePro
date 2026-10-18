use super::RequestStamp;

/// A reply and the request it answers.
#[derive(Debug, Clone)]
pub struct Stamped<T> {
    pub stamp: RequestStamp,
    pub value: T,
}
