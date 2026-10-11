#![macro_use]

macro_rules! fail {
    ($expr:expr) => {
        return Err(::std::convert::From::from($expr))
    };
}
