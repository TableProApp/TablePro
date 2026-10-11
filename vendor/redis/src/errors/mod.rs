mod parsing_error;
mod redis_error;
mod server_error;

pub use parsing_error::*;
pub use redis_error::*;
pub use server_error::*;

macro_rules! invalid_type_error_inner {
    ($v:expr, $det:expr) => {
        ParsingError::from(format!("{:?} (value was {:?})", $det, $v))
    };
}

macro_rules! invalid_type_error {
    ($det:expr) => {{ fail!(crate::errors::ParsingError::from(format!("{:?}", $det))) }};
    ($v:expr, $det:expr) => {{ fail!(crate::errors::invalid_type_error_inner!($v, $det)) }};
}

pub(crate) use {invalid_type_error, invalid_type_error_inner};

// A consistent error value for connections closed without a reason.
#[cfg(any(feature = "aio", test))]
pub(crate) fn closed_connection_error() -> RedisError {
    use std::io;

    RedisError::from(io::Error::from(io::ErrorKind::BrokenPipe))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_closed_connection_error() {
        let err = closed_connection_error();
        assert!(err.is_connection_dropped());
        assert!(err.is_unrecoverable_error());
        assert!(err.is_io_error());
    }
}
