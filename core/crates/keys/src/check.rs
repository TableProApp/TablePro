// Value checks ADR 0056 names with a code from its Errors table. What a client holds, and when it
// applies each check, belongs to the flows built on this crate.

use crate::KeysError;
use crate::encoding::Version;

// Versions count from 1 and step by exactly one: an `av` or version that goes back is
// keys.stale, one that skips keys.step.
pub fn check_step(held: Option<Version>, offered: Version) -> Result<(), KeysError> {
    let held_value = held.map_or(0, Version::get);
    match offered.get().cmp(&(held_value + 1)) {
        std::cmp::Ordering::Equal => Ok(()),
        std::cmp::Ordering::Less => Err(KeysError::Stale {
            held: held_value,
            offered: offered.get(),
        }),
        std::cmp::Ordering::Greater => Err(KeysError::Step {
            held: held_value,
            offered: offered.get(),
        }),
    }
}

// An object that would advance counts only when signed under its signer's newest `av` the client
// knows (ADR 0056, Rollback, Advancing).
pub fn check_signed_under_newest(signed_under: Version, newest_known: Version) -> Result<(), KeysError> {
    if signed_under < newest_known {
        Err(KeysError::Stale {
            held: newest_known.get(),
            offered: signed_under.get(),
        })
    } else {
        Ok(())
    }
}

// Below what the client holds, as an envelope `kv` below the copy held.
pub fn check_not_below(held: Version, offered: Version) -> Result<(), KeysError> {
    if offered < held {
        Err(KeysError::Stale {
            held: held.get(),
            offered: offered.get(),
        })
    } else {
        Ok(())
    }
}

// At an anchored or imported version, only the record with that digest counts.
pub fn check_record_digest(anchored: &[u8; 32], offered: &[u8; 32]) -> Result<(), KeysError> {
    if anchored == offered {
        Ok(())
    } else {
        Err(KeysError::Conflict)
    }
}

#[cfg(test)]
mod tests {
    use super::{check_not_below, check_record_digest, check_signed_under_newest, check_step};
    use crate::KeysError;
    use crate::encoding::Version;

    fn v(value: u32) -> Version {
        Version::new(value).unwrap()
    }

    #[test]
    fn steps() {
        assert_eq!(check_step(None, v(1)), Ok(()));
        assert_eq!(check_step(None, v(2)), Err(KeysError::Step { held: 0, offered: 2 }));
        assert_eq!(check_step(Some(v(3)), v(4)), Ok(()));
        assert_eq!(
            check_step(Some(v(3)), v(3)),
            Err(KeysError::Stale { held: 3, offered: 3 })
        );
        assert_eq!(
            check_step(Some(v(3)), v(2)),
            Err(KeysError::Stale { held: 3, offered: 2 })
        );
        assert_eq!(
            check_step(Some(v(3)), v(5)),
            Err(KeysError::Step { held: 3, offered: 5 })
        );
        assert_eq!(
            check_step(Some(v(Version::MAX)), v(Version::MAX)).unwrap_err().code(),
            "keys.stale"
        );
    }

    #[test]
    fn stale_signers_envelopes_and_records() {
        assert_eq!(check_signed_under_newest(v(2), v(2)), Ok(()));
        assert_eq!(check_signed_under_newest(v(1), v(2)).unwrap_err().code(), "keys.stale");
        assert_eq!(check_not_below(v(4), v(3)).unwrap_err().code(), "keys.stale");
        assert_eq!(check_not_below(v(4), v(4)), Ok(()));
        assert_eq!(check_record_digest(&[1; 32], &[2; 32]), Err(KeysError::Conflict));
    }
}
