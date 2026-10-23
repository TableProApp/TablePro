use crate::config_error::ConfigError;

/// The numbered database a key-value connection opens. Empty is
/// database 0, as it is for redis-cli; a server says itself how many it
/// has, so the number is checked there.
pub fn database_number(database: Option<&str>) -> Result<u32, ConfigError> {
    match database.map(str::trim).filter(|text| !text.is_empty()) {
        None => Ok(0),
        Some(text) => text.parse().map_err(|_| ConfigError::DatabaseNumber),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_database_is_a_number_and_defaults_to_zero() {
        assert_eq!(database_number(None), Ok(0));
        assert_eq!(database_number(Some("  ")), Ok(0));
        assert_eq!(database_number(Some(" 3 ")), Ok(3));
        for text in ["-1", "two", "1.5"] {
            assert_eq!(database_number(Some(text)), Err(ConfigError::DatabaseNumber), "{text}");
        }
    }
}
