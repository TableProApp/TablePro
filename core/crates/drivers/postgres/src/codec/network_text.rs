//! Network addresses read from their binary forms and printed the way
//! the server prints them.

use std::net::IpAddr;

use postgres_protocol::types::{inet_from_sql, macaddr_from_sql};

use super::WireError;

/// INET and CIDR. An INET prints its mask only when it is narrower than
/// the address, a CIDR always does.
pub(crate) fn inet_text(bytes: &[u8], cidr: bool) -> Result<String, WireError> {
    let inet = inet_from_sql(bytes).map_err(|_| WireError::Malformed)?;
    let full = match inet.addr() {
        IpAddr::V4(_) => 32,
        IpAddr::V6(_) => 128,
    };
    if !cidr && inet.netmask() == full {
        return Ok(inet.addr().to_string());
    }
    Ok(format!("{}/{}", inet.addr(), inet.netmask()))
}

pub(crate) fn macaddr_text(bytes: &[u8]) -> Result<String, WireError> {
    let octets = macaddr_from_sql(bytes).map_err(|_| WireError::Malformed)?;
    Ok(colon_hex(&octets))
}

/// MACADDR8 has no decoder in postgres-protocol; its binary form is the
/// eight octets as they are.
pub(crate) fn macaddr8_text(bytes: &[u8]) -> Result<String, WireError> {
    if bytes.len() != 8 {
        return Err(WireError::Malformed);
    }
    Ok(colon_hex(bytes))
}

fn colon_hex(octets: &[u8]) -> String {
    octets
        .iter()
        .map(|octet| format!("{octet:02x}"))
        .collect::<Vec<_>>()
        .join(":")
}

#[cfg(test)]
mod tests {
    use bytes::BytesMut;
    use postgres_protocol::types::{inet_to_sql, macaddr_to_sql};

    use super::*;

    fn inet(addr: &str, mask: u8) -> BytesMut {
        let mut out = BytesMut::new();
        inet_to_sql(addr.parse().expect("an address"), mask, &mut out);
        out
    }

    #[test]
    fn an_inet_prints_its_mask_only_when_it_narrows_the_address() {
        assert_eq!(inet_text(&inet("10.0.0.1", 32), false).as_deref(), Ok("10.0.0.1"));
        assert_eq!(inet_text(&inet("10.0.0.1", 8), false).as_deref(), Ok("10.0.0.1/8"));
        assert_eq!(inet_text(&inet("10.0.0.0", 32), true).as_deref(), Ok("10.0.0.0/32"));
        assert_eq!(inet_text(&inet("::1", 128), false).as_deref(), Ok("::1"));
    }

    #[test]
    fn mac_addresses_print_as_lowercase_colon_pairs() {
        let mut out = BytesMut::new();
        macaddr_to_sql([0x08, 0x00, 0x2b, 0x01, 0x02, 0xAB], &mut out);

        assert_eq!(macaddr_text(&out).as_deref(), Ok("08:00:2b:01:02:ab"));
        assert_eq!(
            macaddr8_text(&[1, 2, 3, 4, 5, 6, 7, 8]).as_deref(),
            Ok("01:02:03:04:05:06:07:08")
        );
        assert_eq!(macaddr8_text(&[1]), Err(WireError::Malformed));
    }
}
