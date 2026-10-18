#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Temporal<T> {
    Finite(T),
    Infinity,
    NegInfinity,
}

impl<T> Temporal<T> {
    pub fn finite(&self) -> Option<&T> {
        match self {
            Self::Finite(value) => Some(value),
            Self::Infinity | Self::NegInfinity => None,
        }
    }
}
